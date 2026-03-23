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
    apiVersion = "external-secrets.io/v1"
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

# ── SSM parameter existence checks ──────────────────────────────────────────
# Validate that optional encryption keys exist in SSM when their feature toggle
# is enabled. Without these, ESO fails to sync the entire langsmith-config secret
# (all-or-nothing), causing a total application outage — not just a feature-specific failure.

data "aws_ssm_parameter" "agent_builder_key" {
  count = var.enable_agent_builder ? 1 : 0
  name  = "${local.ssm_prefix}/agent-builder-encryption-key"
}

data "aws_ssm_parameter" "insights_key" {
  count = var.enable_insights ? 1 : 0
  name  = "${local.ssm_prefix}/insights-encryption-key"
}

data "aws_ssm_parameter" "deployments_key" {
  count = var.enable_agent_deploys ? 1 : 0
  name  = "${local.ssm_prefix}/deployments-encryption-key"
}

data "aws_ssm_parameter" "polly_key" {
  count = var.enable_polly ? 1 : 0
  name  = "${local.ssm_prefix}/polly-encryption-key"
}

# ── ESO: ExternalSecret ──────────────────────────────────────────────────────
# Syncs secrets from SSM → K8s Secret (langsmith-config).
# deploy.sh does this with kubectl apply; here we manage it in Terraform.

resource "kubernetes_manifest" "external_secret" {
  depends_on = [kubernetes_manifest.cluster_secret_store]

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "langsmith-config"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = var.eso_refresh_interval
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
        # Deployments encryption key — only if addon enabled
        var.enable_agent_deploys ? [
          {
            secretKey = "deployments_encryption_key"
            remoteRef = { key = "${local.ssm_prefix}/deployments-encryption-key" }
          },
        ] : [],
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
        # Polly encryption key — only if addon enabled
        var.enable_polly ? [
          {
            secretKey = "polly_encryption_key"
            remoteRef = { key = "${local.ssm_prefix}/polly-encryption-key" }
          },
        ] : [],
      )
    }
  }
}

# ── ClickHouse Secret (only when Insights is enabled) ────────────────────────
# Stores ClickHouse credentials in a K8s Secret so the password never appears
# in Helm values or Helm release metadata.

resource "kubernetes_secret" "clickhouse" {
  count = var.enable_insights ? 1 : 0

  metadata {
    name      = "langsmith-clickhouse"
    namespace = local.namespace
  }
  data = {
    clickhouse_host     = var.clickhouse_host
    clickhouse_port     = tostring(var.clickhouse_port)
    clickhouse_user     = var.clickhouse_username
    clickhouse_password = var.clickhouse_password
    clickhouse_db       = var.clickhouse_database
    clickhouse_tls      = tostring(var.clickhouse_tls)
  }
  type = "Opaque"
}

# ── Helm Release ──────────────────────────────────────────────────────────────

resource "helm_release" "langsmith" {
  depends_on = [kubernetes_manifest.external_secret, kubernetes_secret.clickhouse]

  name             = var.release_name
  namespace        = local.namespace
  create_namespace = true
  repository       = "https://langchain-ai.github.io/helm"
  chart            = "langsmith"
  version          = var.chart_version != "" ? var.chart_version : null
  timeout          = var.helm_timeout

  # Do NOT use wait = true. The chart's post-install bootstrap job deploys
  # operator-managed agents (clio, polly, agent-builder) which can take 10+
  # minutes on a cold cluster with autoscaling. Terraform marks the release as
  # failed if the job exceeds the timeout — even though all workloads are healthy.
  wait = false

  force_update = var.helm_force_update

  # Values layering — YAML files are the single source of truth (shared with helm/scripts path).
  # Only overrides_values is HCL — it contains dynamic, env-specific config (hostname, IRSA, S3).
  values = concat(
    # 1. Base AWS config (ingress, storage, auth, blob, external postgres/redis)
    [file("${local.values_path}/langsmith-values.yaml")],
    # 2. Dynamic overrides (hostname, IRSA annotations, S3 bucket, region)
    [yamlencode(local.overrides_values)],
    # 3. Sizing
    var.sizing == "production"       ? [file("${local.values_path}/langsmith-values-sizing-production.yaml")] : [],
    var.sizing == "production-large" ? [file("${local.values_path}/langsmith-values-sizing-production-large.yaml")] : [],
    var.sizing == "dev"              ? [file("${local.values_path}/langsmith-values-sizing-dev.yaml")] : [],
    # 4. Product addons
    var.enable_agent_deploys ? [file("${local.values_path}/langsmith-values-agent-deploys.yaml"), yamlencode(local.agent_deploys_overrides)] : [],
    var.enable_agent_builder ? [file("${local.values_path}/langsmith-values-agent-builder.yaml")] : [],
    var.enable_insights      ? [file("${local.values_path}/langsmith-values-insights.yaml"), yamlencode(local.insights_overrides)] : [],
    var.enable_polly         ? [file("${local.values_path}/langsmith-values-polly.yaml")] : [],
  )
}

# ── langsmith-ksa for agent deployment pods ──────────────────────────────────
# Creates the SA up front with the IRSA annotation so the operator's spawned
# agent pods have S3 access from the start. The SA must exist before the
# operator tries to use it — kubernetes_annotations alone would fail on first
# apply because the SA doesn't exist yet.

resource "kubernetes_service_account_v1" "langsmith_ksa" {
  count = var.enable_agent_deploys ? 1 : 0

  metadata {
    name      = "langsmith-ksa"
    namespace = local.namespace
    annotations = local.irsa_annotations
  }

  lifecycle {
    ignore_changes = [metadata[0].labels]
  }
}

#------------------------------------------------------------------------------
# Helm Values — dynamic overrides only
#
# Static values (sizing, resource limits, addon config) come from the YAML files
# in helm/values/ via file(). These are the same files the scripts path uses,
# so both deployment paths share a single source of truth.
# Requires: make init-values (copies examples/ → values/ and generates overrides).
#
# Only env-specific config that requires variable interpolation lives here as HCL.
#------------------------------------------------------------------------------

locals {
  # Overrides — env-specific config generated from Terraform variables.
  # Equivalent to what init-values.sh writes into langsmith-values-overrides.yaml.
  overrides_values = merge(
    {
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations      = local.ingress_annotations
      }
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
      commonEnv = concat(
        [
          { name = "AWS_REGION", value = local.region },
          { name = "AWS_DEFAULT_REGION", value = local.region },
        ],
        var.enable_usage_telemetry ? [{ name = "PHONE_HOME_USAGE_REPORTING_ENABLED", value = "true" }] : [],
      )
    },
    # Postgres/Redis: disable external if using in-cluster
    var.postgres_source != "external" ? { postgres = { external = { enabled = false } } } : {},
    var.redis_source != "external" ? { redis = { external = { enabled = false } } } : {},
    # IRSA annotations for each component
    { for component in local.irsa_components : component => {
      serviceAccount = {
        annotations = local.irsa_annotations
      }
    } },
  )

  # Agent deploys override — only the dynamic tlsEnabled field.
  # Resource sizing and operator template come from the YAML file.
  agent_deploys_overrides = {
    config = {
      deployment = {
        tlsEnabled = local.tls_enabled_for_deploys
      }
    }
  }

  # Insights override — ClickHouse connection details from variables.
  # The YAML file enables the feature; this layers on the actual connection config.
  # Credentials are stored in the langsmith-clickhouse K8s Secret (created above).
  insights_overrides = {
    clickhouse = {
      external = {
        host               = var.clickhouse_host
        port               = tostring(var.clickhouse_port)
        database           = var.clickhouse_database
        user               = var.clickhouse_username
        tls                = var.clickhouse_tls
        existingSecretName = "langsmith-clickhouse"
      }
    }
  }
}
