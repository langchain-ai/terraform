# k8s-bootstrap: Provisions supporting Kubernetes resources for LangSmith.
# Creates the namespace, database/cache secrets, KEDA, and cert-manager.
# The LangSmith Helm chart itself is deployed separately via aws/helm/scripts/deploy.sh.
#
# Providers (kubernetes, helm, aws) are inherited from the root module — do not
# define provider blocks here. See:
# https://developer.hashicorp.com/terraform/language/modules/develop/providers

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

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.19.0"

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
  version          = "v1.20.0"

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
  version          = "2.1.0"

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.eso_irsa_role_arn
  }
}


# ClusterIssuer for Let's Encrypt — applied via kubectl to avoid the
# kubernetes_manifest plan-time CRD validation issue. On a fresh cluster,
# cert-manager CRDs don't exist until apply, so kubernetes_manifest fails
# at plan time. terraform_data + local-exec defers the apply to after
# cert-manager is installed.
resource "terraform_data" "letsencrypt_cluster_issuer" {
  count = var.tls_certificate_source == "letsencrypt" ? 1 : 0

  triggers_replace = [
    var.letsencrypt_email,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${var.letsencrypt_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          ingressClassName: alb
MANIFEST
    EOT
  }

  depends_on = [helm_release.cert_manager]
}

# ── Envoy Gateway (Kubernetes Gateway API controller) ──────────────────────
# Installs the Envoy Gateway controller and Gateway API CRDs. When enabled,
# the LangSmith Helm chart creates HTTPRoute resources instead of Ingress.
# The Gateway resource is created in the langsmith namespace so HTTPRoutes
# can reference it without cross-namespace ReferenceGrants.

resource "helm_release" "envoy_gateway" {
  count = var.enable_envoy_gateway ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  version          = "v1.3.0"

  set {
    name  = "deployment.envoyGateway.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "deployment.envoyGateway.resources.requests.memory"
    value = "256Mi"
  }
}

# GatewayClass + Gateway resource — applied via kubectl to avoid CRD plan-time
# validation issues (same pattern as the letsencrypt ClusterIssuer above). The
# Gateway API CRDs are installed by the Envoy Gateway Helm chart.
#
# The GatewayClass is created explicitly because the Envoy Gateway certgen job
# (which normally creates it) runs with a short TTL and may not re-run on
# subsequent applies. Without a GatewayClass, the Gateway stays in "Waiting
# for controller" state indefinitely.
resource "terraform_data" "envoy_gateway_resource" {
  count = var.enable_envoy_gateway ? 1 : 0

  triggers_replace = [
    var.namespace,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      cat <<'MANIFEST' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: ${var.namespace}
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 8080
MANIFEST
    EOT
  }

  depends_on = [helm_release.envoy_gateway]
}

