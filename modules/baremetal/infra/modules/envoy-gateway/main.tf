#------------------------------------------------------------------------------
# Envoy Gateway: the Gateway API implementation in front of LangSmith.
#
#   controller (envoy-gateway)  watches GatewayClass/Gateway/HTTPRoute objects
#                               and runs Envoy proxies to match them
#   EnvoyProxy                  how the proxies run: replicas, resources, and
#                               the annotation that pins the MetalLB IP
#   GatewayClass                "Envoy Gateway implements this class"
#   Gateway                     a listener (HTTP :80) in the langsmith namespace;
#                               the LangSmith chart attaches HTTPRoutes to it
#
# Names match modules/azure (langsmith-proxy, langsmith-eg, langsmith-gateway).
# The listener is HTTP only for now: the IP is LAN-only, and TLS arrives with
# the Cloudflare / cert-manager step.
#------------------------------------------------------------------------------

resource "helm_release" "envoy_gateway" {
  name             = "envoy-gateway"
  chart            = "oci://docker.io/envoyproxy/gateway-helm"
  version          = var.chart_version
  namespace        = "envoy-gateway-system"
  create_namespace = true

  # Wait for the controller (and its CRDs) before creating Gateway objects.
  wait    = true
  timeout = 300

  values = [
    yamlencode({
      deployment = {
        envoyGateway = { resources = var.controller_resources }
      }
    })
  ]
}

locals {
  proxy_service_name = "envoy-${var.gateway_namespace}-${var.gateway_name}-${substr(sha256("${var.gateway_namespace}/${var.gateway_name}"), 0, 8)}"
}

# Gateway API objects are custom resources, so like MetalLB's pool they ship
# as a small local chart: kubernetes_manifest would need the CRDs at plan time.
resource "helm_release" "gateway_config" {
  name      = "gateway-config"
  chart     = "${path.module}/charts/gateway-config"
  namespace = helm_release.envoy_gateway.namespace

  values = [
    yamlencode({
      envoyProxyName   = var.envoy_proxy_name
      gatewayClassName = var.gateway_class_name
      gatewayName      = var.gateway_name
      gatewayNamespace = var.gateway_namespace
      loadBalancerIP   = var.load_balancer_ip
      proxyReplicas    = var.proxy_replicas
      proxyResources   = var.proxy_resources
      routeTimeout     = var.route_timeout
      lanRoute = {
        enabled        = var.lan_route.enabled
        backendService = var.lan_route.backend_service
        backendPort    = var.lan_route.backend_port
      }
    })
  ]

  depends_on = [helm_release.envoy_gateway]
}
