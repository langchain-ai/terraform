#------------------------------------------------------------------------------
# What Envoy Gateway and the LangSmith Gateway exposes to the root module:
# the Gateway the LangSmith chart attaches its HTTPRoute to, and the proxy
# Service (used by the tunnel).
#------------------------------------------------------------------------------

output "gateway" {
  description = "What the LangSmith chart's gateway block points at, and the LAN IP serving it."
  value = {
    name             = var.gateway_name
    namespace        = var.gateway_namespace
    class            = var.gateway_class_name
    load_balancer_ip = var.load_balancer_ip
  }
}

output "proxy_node_selector" {
  description = "The nodes the proxy pods may run on; {} for anywhere."
  value       = var.proxy_node_selector
}

# Envoy Gateway names the proxy Service envoy-<ns>-<gateway>-<hash>, where hash
# is the first 8 hex digits of sha256("<ns>/<gateway>"). In-cluster clients
# (the Cloudflare Tunnel connector) use it instead of the MetalLB IP.
output "proxy_service" {
  description = "In-cluster Service of the Envoy proxy for this Gateway (HTTP :80)."
  value = {
    name      = local.proxy_service_name
    namespace = helm_release.envoy_gateway.namespace
    url       = "http://${local.proxy_service_name}.${helm_release.envoy_gateway.namespace}.svc.cluster.local:80"
  }
}
