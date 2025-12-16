# Ingress Module - Envoy Gateway (Gateway API)
# Note: Currently only Envoy Gateway is implemented. Other ingress types (Istio, etc.) are reserved for future implementation.
# The Gateway uses HTTPS only (port 443) - TLS must be configured.

#------------------------------------------------------------------------------
# Gateway API CRDs (required for Envoy Gateway)
#------------------------------------------------------------------------------
resource "helm_release" "gateway_api_crds" {
  count = var.ingress_type == "envoy" ? 1 : 0

  name             = "gateway-api"
  repository       = "https://kubernetes-sigs.github.io/gateway-api"
  chart            = "gateway-api"
  version          = "1.2.0"
  namespace        = "gateway-system"
  create_namespace = true

  wait = true
}

#------------------------------------------------------------------------------
# Envoy Gateway
#------------------------------------------------------------------------------
resource "helm_release" "envoy_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.2.0"
  namespace        = "envoy-gateway-system"
  create_namespace = true

  wait    = true
  timeout = 600

  depends_on = [helm_release.gateway_api_crds]
}

#------------------------------------------------------------------------------
# Envoy Gateway Class
#------------------------------------------------------------------------------
resource "kubernetes_manifest" "gateway_class" {
  count = var.ingress_type == "envoy" ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "envoy-gateway-class"
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
    }
  }

  depends_on = [helm_release.envoy_gateway]
}

#------------------------------------------------------------------------------
# Envoy Gateway Resource
#------------------------------------------------------------------------------
resource "kubernetes_manifest" "gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = "envoy-gateway-system"
      annotations = var.tls_certificate_source == "letsencrypt" ? {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      } : {}
    }
    spec = {
      gatewayClassName = "envoy-gateway-class"
      listeners = [
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          hostname = var.langsmith_domain
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              name = var.tls_secret_name
              kind = "Secret"
            }]
          }
          allowedRoutes = {
            namespaces = {
              from = "All"
            }
          }
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.gateway_class]
}

#------------------------------------------------------------------------------
# Data source for external IP
#------------------------------------------------------------------------------
data "kubernetes_service" "envoy_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  metadata {
    name      = "envoy-envoy-gateway-system"
    namespace = "envoy-gateway-system"
  }

  depends_on = [kubernetes_manifest.gateway]
}
