# Outputs for Ingress Module

output "external_ip" {
  description = "External IP address of the ingress/gateway"
  value       = var.ingress_type == "envoy" ? try(trimspace(data.local_file.external_ip[0].content), "pending") : "not implemented"
}

output "ingress_type" {
  description = "Type of ingress/gateway installed"
  value       = var.ingress_type
}

output "gateway_name" {
  description = "Name of the Gateway resource (for Envoy Gateway)"
  value       = var.ingress_type == "envoy" ? var.gateway_name : null
}

