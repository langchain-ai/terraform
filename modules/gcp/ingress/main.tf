# Ingress Module - NGINX Ingress Controller or Envoy Gateway

#------------------------------------------------------------------------------
# NGINX Ingress Controller
#------------------------------------------------------------------------------
resource "helm_release" "nginx_ingress" {
  count = var.ingress_type == "nginx" ? 1 : 0

  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.9.0"
  namespace        = "ingress-nginx"
  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type = "LoadBalancer"
          annotations = {
            "cloud.google.com/load-balancer-type" = "External"
          }
        }
        config = {
          "proxy-body-size"    = "100m"
          "proxy-read-timeout" = "300"
          "proxy-send-timeout" = "300"
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
        autoscaling = {
          enabled     = true
          minReplicas = 2
          maxReplicas = 10
        }
        metrics = {
          enabled = true
        }
      }
    })
  ]

  wait    = true
  timeout = 600
}

#------------------------------------------------------------------------------
# Gateway API CRDs (for Envoy Gateway)
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
    }
    spec = {
      gatewayClassName = "envoy-gateway-class"
      listeners = [
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
          hostname = var.langsmith_domain
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
# Reference Grant for cross-namespace access
#------------------------------------------------------------------------------
resource "kubernetes_manifest" "reference_grant" {
  count = var.ingress_type == "envoy" ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-to-langsmith"
      namespace = var.langsmith_namespace
    }
    spec = {
      from = [
        {
          group     = "gateway.networking.k8s.io"
          kind      = "HTTPRoute"
          namespace = var.langsmith_namespace
        },
        {
          group     = "gateway.networking.k8s.io"
          kind      = "Gateway"
          namespace = "envoy-gateway-system"
        }
      ]
      to = [
        {
          group = ""
          kind  = "Service"
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.gateway]
}

#------------------------------------------------------------------------------
# Data sources for external IP
#------------------------------------------------------------------------------
data "kubernetes_service" "nginx_ingress" {
  count = var.ingress_type == "nginx" ? 1 : 0

  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }

  depends_on = [helm_release.nginx_ingress]
}

data "kubernetes_service" "envoy_gateway" {
  count = var.ingress_type == "envoy" ? 1 : 0

  metadata {
    name      = "envoy-envoy-gateway-system"
    namespace = "envoy-gateway-system"
  }

  depends_on = [kubernetes_manifest.gateway]
}
