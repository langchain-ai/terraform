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

# Allows ingress from the ingress-nginx namespace (external traffic via LB)
# and from within the langsmith namespace itself (inter-service calls).
# Both rules are required: without the intra-namespace rule, backend pods
# cannot call each other (e.g. queue workers calling the internal API).
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

# LangSmith license key secret — required for the application to start.
# The Helm chart references this via config.licenseKeySecretName.
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

  # DNS-01 via Azure Workload Identity: annotate the cert-manager service account
  # with the Managed Identity client ID so it can call the Azure DNS API.
  # The federated credential (created in k8s-cluster module) allows the OIDC
  # token exchange that binds the pod to the identity.
  dynamic "set" {
    for_each = var.tls_certificate_source == "dns01" ? [1] : []
    content {
      name  = "podLabels.azure\\.workload\\.identity/use"
      value = "true"
    }
  }
  dynamic "set" {
    for_each = var.tls_certificate_source == "dns01" ? [1] : []
    content {
      name  = "serviceAccount.annotations.azure\\.workload\\.identity/client-id"
      value = var.cert_manager_identity_client_id
    }
  }
}

# DNS-01 ClusterIssuer — created by Terraform when tls_certificate_source = "dns01".
# Uses Azure DNS + Workload Identity: no static service principal needed.
# cert-manager controller calls the Azure DNS API to create/delete TXT records
# for ACME challenge verification.
#
# When tls_certificate_source = "letsencrypt" (HTTP-01), the ClusterIssuer is
# created separately via: bash helm/scripts/apply-cluster-issuers.sh
resource "kubernetes_manifest" "cluster_issuer_dns01" {
  count = var.tls_certificate_source == "dns01" ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          dns01 = {
            azureDNS = {
              subscriptionID    = var.subscription_id
              resourceGroupName = var.dns_resource_group_name
              hostedZoneName    = var.dns_zone_name
              environment       = "AzurePublicCloud"
              managedIdentity = {
                clientID = var.cert_manager_identity_client_id
              }
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
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
