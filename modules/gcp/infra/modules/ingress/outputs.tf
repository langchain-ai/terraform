# Outputs for Ingress Module

output "external_ip" {
  description = "External IP address of the ingress/gateway"
  value = (
    var.ingress_type == "envoy" ? try(trimspace(data.local_file.external_ip[0].content), "pending") :
    var.ingress_type == "gke" ? (
      local.gke_gateway_global_ip ? google_compute_global_address.gke_gateway[0].address : "assigned by GKE, see the Gateway status"
    ) :
    "not implemented"
  )
}

output "ingress_type" {
  description = "Type of ingress/gateway installed"
  value       = var.ingress_type
}

output "gateway_name" {
  description = "Name of the Gateway resource (Envoy Gateway or GKE Gateway)"
  value       = contains(["envoy", "gke"], var.ingress_type) ? var.gateway_name : null
}

output "gateway_namespace" {
  description = "Namespace of the Gateway resource"
  value = (
    var.ingress_type == "envoy" ? "envoy-gateway-system" :
    var.ingress_type == "gke" ? var.langsmith_namespace :
    null
  )
}

