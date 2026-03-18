# k8s-bootstrap: Provisions supporting Kubernetes resources for LangSmith.
# Creates the namespace, database/cache secrets, KEDA, and cert-manager.
# The LangSmith Helm chart itself is deployed separately via aws/helm/scripts/deploy.sh.
#
# Key dependencies installed here:
#   KEDA              — https://keda.sh/docs/
#   cert-manager      — https://cert-manager.io/docs/
#   External Secrets  — https://external-secrets.io/latest/

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Providers ─────────────────────────────────────────────────────────────────
# Cluster credentials are passed in from the root module (module.eks outputs).
# Using exec-based auth so this module never needs a raw token in state.

provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

# ── Namespace ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "langsmith" {
  metadata {
    name = var.namespace
    labels = {
      app        = "langsmith"
      managed-by = "terraform"
    }
  }
}

# ── Kubernetes Secrets ───────────────────────────────────────────────────────

resource "kubernetes_secret" "postgres" {
  metadata {
    name      = "langsmith-postgres"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }
  data = {
    connection_url = var.postgres_connection_url
  }
  type = "Opaque"
}

resource "kubernetes_secret" "redis" {
  metadata {
    name      = "langsmith-redis"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }
  data = {
    connection_url = var.redis_connection_url
  }
  type = "Opaque"
}

# ── KEDA (Kubernetes Event-driven Autoscaling) ───────────────────────────────
# Required for LangSmith Deployments feature.
# https://keda.sh/docs/latest/concepts/

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.16.0"

  set {
    name  = "resources.operator.requests.cpu"
    value = "100m"
  }
  set {
    name  = "resources.operator.requests.memory"
    value = "100Mi"
  }
}

# ── cert-manager (only when tls_certificate_source = "letsencrypt") ──────────

resource "helm_release" "cert_manager" {
  count = var.tls_certificate_source == "letsencrypt" ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.17.0"

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# ── External Secrets Operator ─────────────────────────────────────────────────

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  version          = "0.10.7"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.eso_irsa_role_arn
  }
}


resource "kubernetes_manifest" "letsencrypt_cluster_issuer" {
  count = var.tls_certificate_source == "letsencrypt" ? 1 : 0

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
          name = "letsencrypt-prod"
        }
        solvers = [{
          http01 = {
            ingress = {
              ingressClassName = "alb"
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

