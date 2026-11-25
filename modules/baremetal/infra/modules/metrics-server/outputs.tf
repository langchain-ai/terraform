#------------------------------------------------------------------------------
# What metrics-server exposes to the root module:
# the Helm release (name, namespace, version).
#------------------------------------------------------------------------------

output "release" {
  description = "Helm release name, namespace, and chart version."
  value = {
    name      = helm_release.metrics_server.name
    namespace = helm_release.metrics_server.namespace
    version   = helm_release.metrics_server.version
  }
}
