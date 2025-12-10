# Outputs for Ingress Module

output "external_ip" {
  description = "External IP address of the ingress"
  value       = var.ingress_type == "nginx" ? try(data.kubernetes_service.nginx_ingress[0].status[0].load_balancer[0].ingress[0].ip, "pending") : try(data.kubernetes_service.envoy_gateway[0].status[0].load_balancer[0].ingress[0].ip, "pending")
}

output "ingress_type" {
  description = "Type of ingress installed"
  value       = var.ingress_type
}

