#------------------------------------------------------------------------------
# What MetalLB in L2 mode exposes to the root module:
# the IP pool and namespace.
#------------------------------------------------------------------------------

output "addresses" {
  description = "LoadBalancer IP pool."
  value       = var.addresses
}

output "namespace" {
  description = "MetalLB namespace."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}
