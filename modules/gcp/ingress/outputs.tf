# Outputs for Ingress Module

output "external_ip" {
  description = "External IP address of the ingress/gateway"
  value       = var.ingress_type == "envoy" ? try(data.kubernetes_service.envoy_gateway[0].status[0].load_balancer[0].ingress[0].ip, "pending") : "not implemented"
}

output "ingress_type" {
  description = "Type of ingress/gateway installed"
  value       = var.ingress_type
}

output "gateway_name" {
  description = "Name of the Gateway resource (for Envoy Gateway)"
  value       = var.ingress_type == "envoy" ? var.gateway_name : null
}

