# ── Providers ─────────────────────────────────────────────────────────────────
# Credentials are passed in from the root module via variables (not from a local
# kubeconfig) so this module works in CI/CD pipelines without file system access.

provider "kubernetes" {
  host                   = var.host
  client_certificate     = base64decode(var.client_certificate)
  client_key             = base64decode(var.client_key)
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = var.host
    client_certificate     = base64decode(var.client_certificate)
    client_key             = base64decode(var.client_key)
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────
# Dedicated namespace isolates LangSmith workloads from other cluster tenants.
# The workload.identity label is required by the Azure Workload Identity webhook
# to inject OIDC tokens into pods so they can authenticate to Azure Blob Storage.

resource "kubernetes_namespace_v1" "langsmith" {
  metadata {
    name = var.langsmith_namespace
    labels = {
      "app"                         = "langsmith"
      "azure.workload.identity/use" = "true"
    }
  }
}

# Note: LangSmith pods do NOT use a bootstrap-created service account. The Helm
# chart creates its own per-component service accounts (langsmith-backend,
# langsmith-queue, …) and they get the Workload Identity client-id via Helm
# values; those exact names are the ones federated in infra/modules/k8s-cluster.

# ── Resource Quota ────────────────────────────────────────────────────────────
# Caps total CPU/memory/pod count for the namespace. Prevents a runaway LangSmith
# deployment (e.g. KEDA over-scaling) from starving kube-system or other tenants.
# Defaults: 40 CPU req / 80 CPU lim, 80 GiB req / 160 GiB lim, 200 pods.

resource "kubernetes_resource_quota_v1" "langsmith" {
  metadata {
    name      = "langsmith-quota"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "40"
      "requests.memory" = "80Gi"
      "limits.cpu"      = "80"
      "limits.memory"   = "160Gi"
      pods              = "200"
    }
  }
}

# ── Limit Range ───────────────────────────────────────────────────────────────
# Required companion to the ResourceQuota above: because the quota's `hard` includes
# requests/limits, Kubernetes forces EVERY pod to declare them. Some chart components
# (e.g. the bundled Postgres/Redis StatefulSets for the standalone insights/polly/fleet
# agent features) ship without resource stanzas, so without defaults they're rejected
# with "failed quota: must specify limits.cpu/... for: <container>" and never schedule.
# This LimitRange supplies defaults so those pods inherit sane values and satisfy the quota.
resource "kubernetes_limit_range_v1" "langsmith" {
  metadata {
    name      = "langsmith-defaults"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "1"
        memory = "1Gi"
      }
      default_request = {
        cpu    = "100m"
        memory = "256Mi"
      }
    }
  }
}

# ── Network Policy ────────────────────────────────────────────────────────────
# Default-deny blocks all ingress to LangSmith pods unless explicitly allowed.
# This is defense-in-depth: even if a pod is compromised, it cannot receive
# lateral traffic from other namespaces. Egress is unrestricted (external DBs).

resource "kubernetes_network_policy_v1" "langsmith_default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# This module installs the internal NGINX ingress controller in the
# `ingress-nginx` namespace. The NetworkPolicy below must allow ingress from
# that namespace, or the controller's proxy cannot reach LangSmith pods
# (default-deny drops it → 503 with ~10s connection timeout).
locals {
  ingress_namespace = "ingress-nginx"
}

# Allows ingress from the NGINX ingress controller namespace (external traffic
# via the internal LB) and from within the langsmith namespace itself
# (inter-service calls). The intra-namespace rule is required on its own:
# without it, backend pods cannot call each other (e.g. queue workers calling
# the internal API).
resource "kubernetes_network_policy_v1" "langsmith_allow_internal" {
  metadata {
    name      = "allow-from-ingress"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.ingress_namespace
          }
        }
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.langsmith_namespace
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

# ── Kubernetes Secrets (infrastructure dependencies) ──────────────────────────
# These are created here because they depend on Terraform outputs (connection URLs).
# The app-config secret (api_key_salt, jwt_secret, license, admin_password) is
# created separately by infra/scripts/create-k8s-secrets.sh (DEPLOYMENT.md Phase 3.5).

# PostgreSQL connection URL injected into the namespace so the Helm chart can
# reference it via existingSecretName. Created here (not by Helm) because the
# URL is a Terraform output — it's only known after the postgres module runs.
resource "kubernetes_secret_v1" "postgres" {
  count = var.use_external_postgres ? 1 : 0

  metadata {
    name      = "langsmith-postgres-secret"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    connection_url = var.postgres_connection_url
    # POSTGRES_URI and POSTGRES_PASSWORD are required by the listener's deploy_image
    # task (host.platforms.k8s_operator.database_k8s.add_postgres_uri_secret) to
    # provision per-deployment databases for LangSmith Deployments (Pass 3+).
    POSTGRES_URI      = var.postgres_connection_url
    POSTGRES_PASSWORD = var.postgres_admin_password
  }

  type = "Opaque"
}

# Redis connection URL (rediss://...) injected the same way as the Postgres secret.
# KEDA ScaledObjects also reference this secret to authenticate queue-depth queries.
resource "kubernetes_secret_v1" "redis" {
  count = var.use_external_redis ? 1 : 0

  metadata {
    name      = "langsmith-redis-secret"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    connection_url = var.redis_connection_url
  }

  type = "Opaque"
}

# Application config secret (license key, API key salt, JWT secret, admin
# password, feature encryption keys) is NOT created here. It is created as
# `langsmith-config-secret` by `infra/scripts/create-k8s-secrets.sh`, which
# reads all keys from Key Vault and matches the key names the LangSmith chart
# expects via `config.existingSecretName`. See DEPLOYMENT.md Phase 3.5.

# ── NGINX Ingress Controller ───────────────────────────────────────────────────
# Internal Azure Load Balancer: traffic stays within the hub-spoke network.
# Created here (not in the infra root) so the bootstrap layer owns the full
# Kubernetes/Helm surface.

resource "helm_release" "nginx_ingress" {
  name       = "ingress-nginx"
  namespace  = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  # Pin for reproducibility; null (default) resolves the latest chart. Pinning is
  # recommended, especially as OSS ingress-nginx approaches EOL (March 2026).
  version = var.nginx_ingress_version != "" ? var.nginx_ingress_version : null

  create_namespace = true

  values = [
    yamlencode({
      controller = {
        replicaCount = 2

        # Dedicated health-check endpoint that always returns 200.
        # Azure LB HTTP probes hit /nginx-health on the NodePort — this returns 200
        # so backends are never marked unhealthy. More reliable than TCP probes because
        # the AKS cloud controller manager respects the request-path annotation on every
        # reconcile cycle (e.g. after autoscaler node add/remove), whereas the protocol
        # annotation is only applied at service creation time.
        config = {
          server-snippet = <<-EOT
            location /nginx-health {
              access_log off;
              return 200 "healthy\n";
              add_header Content-Type text/plain;
            }
          EOT
        }

        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }

        service = {
          type = "LoadBalancer"
          annotations = {
            # Internal Azure LB: AKS provisions a private IP instead of a public one.
            # Required for private/hub-spoke clusters where ingress must not be internet-facing.
            "service.beta.kubernetes.io/azure-load-balancer-internal" = "true"
            # Keep HTTP probes (default) but point them at /nginx-health which always 200s.
            # This survives every CCM reconcile: protocol stays Http, path stays /nginx-health.
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/nginx-health"
          }
        }
      }
    })
  ]
}

# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling. Scales LangSmith queue workers
# based on Redis queue depth.

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_version
  wait             = true
  wait_for_jobs    = true

  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.operator.limits.cpu"
    value = "500m"
  }
  set {
    name  = "resources.operator.limits.memory"
    value = "512Mi"
  }
  set {
    name  = "resources.metricServer.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.metricServer.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "resources.metricServer.limits.cpu"
    value = "500m"
  }
  set {
    name  = "resources.metricServer.limits.memory"
    value = "512Mi"
  }
}
