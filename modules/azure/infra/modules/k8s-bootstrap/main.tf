# ── Providers ─────────────────────────────────────────────────────────────────

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

resource "kubernetes_namespace_v1" "langsmith" {
  metadata {
    name = var.langsmith_namespace
    labels = {
      "app"                         = "langsmith"
      "azure.workload.identity/use" = "true"
    }
  }
}

# ── Service Account (Workload Identity) ───────────────────────────────────────
# langsmith-ksa is used by LangSmith pods and LGP operator deployments.
# The azure.workload.identity/client-id annotation binds it to the managed
# identity that has Storage Blob Data Contributor on the blob account.

resource "kubernetes_service_account_v1" "langsmith" {
  metadata {
    name      = "langsmith-ksa"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
    annotations = {
      "azure.workload.identity/client-id" = var.blob_managed_identity_client_id
    }
  }
}

# ── Resource Quota ────────────────────────────────────────────────────────────

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

# ── Network Policy ────────────────────────────────────────────────────────────

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

resource "kubernetes_network_policy_v1" "langsmith_allow_internal" {
  metadata {
    name      = "allow-from-ingress-nginx"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "ingress-nginx"
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
# Application-level secrets (api_key_salt, jwt_secret, admin_password) are
# written by helm/scripts/generate-secrets.sh from Azure Key Vault.

resource "kubernetes_secret_v1" "postgres" {
  count = var.use_external_postgres ? 1 : 0

  metadata {
    name      = "langsmith-postgres-secret"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    connection_url = var.postgres_connection_url
  }

  type = "Opaque"
}

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

resource "kubernetes_secret_v1" "license" {
  count = var.langsmith_license_key != "" ? 1 : 0

  metadata {
    name      = "langsmith-license"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }

  data = {
    license_key = var.langsmith_license_key
  }

  type = "Opaque"
}

# ── cert-manager ──────────────────────────────────────────────────────────────
# TLS automation infrastructure. Manages Let's Encrypt certificates.
# ClusterIssuers are applied separately via:
#   bash helm/scripts/apply-cluster-issuers.sh

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  wait             = true
  wait_for_jobs    = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "controller.resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "controller.resources.limits.memory"
    value = "256Mi"
  }
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
