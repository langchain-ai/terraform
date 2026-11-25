#------------------------------------------------------------------------------
# What the Cloudflare Tunnel connector exposes to the root module:
# the connector's namespace.
#------------------------------------------------------------------------------

output "namespace" {
  description = "Namespace of the connector Deployment."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}
