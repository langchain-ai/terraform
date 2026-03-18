#------------------------------------------------------------------------------
# LangSmith App Module (Pass 2 — Terraform)
#
# Deploys LangSmith via Helm, assuming infra (Pass 1) is complete.
# Equivalent to helm/scripts/deploy.sh but managed by Terraform.
#
# Prerequisites:
#   - EKS cluster running, ESO installed, secrets in SSM
#   - Run: make init-app   (or provide variables manually)
#   - Run: make apply-app
#------------------------------------------------------------------------------

# ── Providers ─────────────────────────────────────────────────────────────────

provider "aws" {
  region = local.region
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.region]
    }
  }
}

# ── ESO: ClusterSecretStore ───────────────────────────────────────────────────
# Tells ESO how to reach AWS SSM Parameter Store.
# Auth: uses the ESO controller pod's IRSA role (provisioned in infra/).
# The ESO CRDs must exist before plan — run infra apply (k8s-bootstrap) first.

resource "kubernetes_manifest" "cluster_secret_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "langsmith-ssm"
    }
    spec = {
      provider = {
        aws = {
          service = "ParameterStore"
          region  = local.region
        }
      }
    }
  }
}

# ── ESO: ExternalSecret ──────────────────────────────────────────────────────
# Syncs secrets from SSM → K8s Secret (langsmith-config).
# deploy.sh does this with kubectl apply; here we manage it in Terraform.

resource "kubernetes_manifest" "external_secret" {
  depends_on = [kubernetes_manifest.cluster_secret_store]

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "langsmith-config"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "langsmith-ssm"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "langsmith-config"
        creationPolicy = "Owner"
      }
      data = concat(
        # Core secrets — always required
        [
          {
            secretKey = "langsmith_license_key"
            remoteRef = { key = "${local.ssm_prefix}/langsmith-license-key" }
          },
          {
            secretKey = "api_key_salt"
            remoteRef = { key = "${local.ssm_prefix}/langsmith-api-key-salt" }
          },
          {
            secretKey = "jwt_secret"
            remoteRef = { key = "${local.ssm_prefix}/langsmith-jwt-secret" }
          },
          {
            secretKey = "initial_org_admin_password"
            remoteRef = { key = "${local.ssm_prefix}/langsmith-admin-password" }
          },
        ],
        # Agent Builder encryption key — only if addon enabled
        var.enable_agent_builder ? [
          {
            secretKey = "agent_builder_encryption_key"
            remoteRef = { key = "${local.ssm_prefix}/agent-builder-encryption-key" }
          },
        ] : [],
        # Insights encryption key — only if addon enabled
        var.enable_insights ? [
          {
            secretKey = "insights_encryption_key"
            remoteRef = { key = "${local.ssm_prefix}/insights-encryption-key" }
          },
        ] : [],
      )
    }
  }
}

# ── Helm Release ──────────────────────────────────────────────────────────────

resource "helm_release" "langsmith" {
  depends_on = [kubernetes_manifest.external_secret]

  name             = var.release_name
  namespace        = local.namespace
  create_namespace = true
  repository       = "https://langchain-ai.github.io/helm"
  chart            = "langsmith"
  version          = var.chart_version != "" ? var.chart_version : null
  timeout          = var.helm_timeout
  wait             = true

  force_update = var.helm_force_update

  # Base AWS values
  values = concat(
    [yamlencode(local.base_values)],
    [yamlencode(local.overrides_values)],
    var.sizing == "ha" ? [yamlencode(local.ha_values)] : [],
    var.sizing == "dev" ? [yamlencode(local.dev_values)] : [],
    var.enable_agent_deploys ? [yamlencode(local.agent_deploys_values)] : [],
    var.enable_agent_builder ? [yamlencode(local.agent_builder_values)] : [],
    var.enable_insights ? [yamlencode(local.insights_values)] : [],
  )
}

# ── langsmith-ksa IRSA annotation ─────────────────────────────────────────────
# The operator creates this SA for agent deployment pods. It needs the IRSA
# annotation for S3 access. Applied after Helm so the SA exists.

resource "kubernetes_annotations" "langsmith_ksa" {
  count = var.enable_agent_deploys ? 1 : 0

  depends_on = [helm_release.langsmith]

  api_version = "v1"
  kind        = "ServiceAccount"
  metadata {
    name      = "langsmith-ksa"
    namespace = local.namespace
  }
  annotations = local.irsa_annotations
  force       = true
}

#------------------------------------------------------------------------------
# Helm Values — built from variables
#
# These locals replicate the layered values files from helm/values/.
# Each block maps 1:1 with an equivalent YAML file.
#------------------------------------------------------------------------------

locals {
  # langsmith-values.yaml equivalent — base AWS config
  base_values = {
    ingress = {
      enabled           = true
      ingressClassName  = "alb"
      annotations       = local.ingress_annotations
    }
    storage = {
      storageClassName = "gp3"
    }
    config = {
      authType           = "mixed"
      existingSecretName = "langsmith-config"
      basicAuth = {
        enabled = true
      }
      blobStorage = {
        enabled = true
        engine  = "S3"
      }
    }
    postgres = {
      external = {
        enabled              = true
        existingSecretName   = "langsmith-postgres"
        connectionUrlSecretKey = "connection_url"
      }
    }
    redis = {
      external = {
        enabled              = true
        existingSecretName   = "langsmith-redis"
        connectionUrlSecretKey = "connection_url"
      }
    }
  }

  # langsmith-values-overrides.yaml equivalent — env-specific config
  overrides_values = merge(
    {
      config = {
        hostname             = local.hostname
        initialOrgAdminEmail = var.admin_email
        deployment = {
          url = "${local.protocol}://${local.hostname}"
        }
        blobStorage = {
          bucketName = local.bucket_name
          awsRegion  = local.region
          apiURL     = "https://s3.${local.region}.amazonaws.com"
        }
      }
      commonEnv = [
        { name = "AWS_REGION", value = local.region },
        { name = "AWS_DEFAULT_REGION", value = local.region },
      ]
    },
    # IRSA annotations for each component
    { for component in local.irsa_components : component => {
      serviceAccount = {
        annotations = local.irsa_annotations
      }
    }},
  )

  # langsmith-values-ha.yaml equivalent
  ha_values = {
    platformBackend = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "1", memory = "2Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 2, maxReplicas = 10, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    backend = {
      resources = {
        requests = { cpu = "1", memory = "2Gi" }
        limits   = { cpu = "2", memory = "4Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 3, maxReplicas = 10, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    ingestQueue = {
      resources = {
        requests = { cpu = "1", memory = "2Gi" }
        limits   = { cpu = "2", memory = "4Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 3, maxReplicas = 10, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    queue = {
      resources = {
        requests = { cpu = "1", memory = "2Gi" }
        limits   = { cpu = "2", memory = "4Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 3, maxReplicas = 10, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    frontend = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "1", memory = "2Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 2, maxReplicas = 10, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    playground = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { cpu = "1", memory = "8Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 1, maxReplicas = 5, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
    aceBackend = {
      resources = {
        requests = { cpu = "200m", memory = "1Gi" }
        limits   = { cpu = "1", memory = "2Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 1, maxReplicas = 5, targetCPUUtilizationPercentage = 50, targetMemoryUtilizationPercentage = 80 } }
    }
  }

  # langsmith-values-dev.yaml equivalent
  dev_values = {
    platformBackend = { resources = { requests = { cpu = "200m", memory = "512Mi" }, limits = { cpu = "500m", memory = "1Gi" } } }
    backend         = { resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "2Gi" } } }
    ingestQueue     = { resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "2Gi" } } }
    queue           = { resources = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "2Gi" } } }
    frontend        = { resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } } }
    playground      = { resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "1Gi" } } }
    aceBackend      = { resources = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } } }
  }

  # langsmith-values-agent-deploys.yaml equivalent
  agent_deploys_values = {
    config = {
      deployment = {
        enabled    = true
        tlsEnabled = local.tls_enabled_for_deploys
      }
    }
    hostBackend = {
      enabled = true
      resources = {
        requests = { cpu = "500m", memory = "512Mi" }
        limits   = { cpu = "2", memory = "2Gi" }
      }
      autoscaling = { hpa = { enabled = true, minReplicas = 1, maxReplicas = 5, targetCPUUtilizationPercentage = 70 } }
    }
    listener = {
      enabled = true
      resources = {
        requests = { cpu = "1000m", memory = "2Gi" }
        limits   = { cpu = "2", memory = "4Gi" }
      }
    }
    operator = {
      enabled = true
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
      templates = {
        deployment = <<-YAML
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: $${name}
            namespace: $${namespace}
          spec:
            replicas: $${replicas}
            revisionHistoryLimit: 10
            selector:
              matchLabels:
                app: $${name}
            template:
              metadata:
                labels:
                  app: $${name}
              spec:
                enableServiceLinks: false
                serviceAccountName: langsmith-ksa
                containers:
                - name: api-server
                  image: $${image}
                  ports:
                  - name: api-server
                    containerPort: 8000
                    protocol: TCP
                  livenessProbe:
                    httpGet:
                      path: /ok
                      port: 8000
                    periodSeconds: 15
                    timeoutSeconds: 5
                    failureThreshold: 6
                  readinessProbe:
                    httpGet:
                      path: /ok
                      port: 8000
                    periodSeconds: 15
                    timeoutSeconds: 5
                    failureThreshold: 6
                  resources:
                    requests:
                      cpu: 100m
                      memory: 256Mi
                    limits:
                      cpu: 1000m
                      memory: 1Gi
        YAML
      }
    }
  }

  # langsmith-values-agent-builder.yaml equivalent
  agent_builder_values = {
    config = {
      agentBuilder = {
        enabled = true
      }
    }
    backend = {
      agentBootstrap = {
        enabled = true
      }
    }
    agentBuilderToolServer = {
      enabled = true
    }
    agentBuilderTriggerServer = {
      enabled = true
    }
  }

  # langsmith-values-insights.yaml equivalent
  insights_values = {
    config = {
      insights = {
        enabled = true
      }
    }
    clickhouse = {
      external = {
        enabled  = true
        host     = var.clickhouse_host
        port     = var.clickhouse_port
        database = var.clickhouse_database
        username = var.clickhouse_username
        password = var.clickhouse_password
        tls      = var.clickhouse_tls
      }
    }
  }
}
