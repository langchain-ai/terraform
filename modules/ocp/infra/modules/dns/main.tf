# OCP DNS module
# OpenShift uses Routes for HTTP/HTTPS ingress by default. DNS records for Route
# hostnames are typically managed outside of Terraform (via the cluster's IngressController
# wildcard DNS entry or external-dns).
#
# This module creates an OpenShift Route for the LangSmith UI. For clusters where
# cert-manager is available, annotate the Route to trigger automatic TLS provisioning.

resource "kubernetes_manifest" "langsmith_route" {
  manifest = {
    apiVersion = "route.openshift.io/v1"
    kind       = "Route"
    metadata = {
      name      = "langsmith"
      namespace = var.namespace
      annotations = var.tls_enabled ? {
        "cert-manager.io/issuer"      = var.cert_manager_issuer
        "cert-manager.io/issuer-kind" = var.cert_manager_issuer_kind
      } : {}
    }
    spec = {
      host = var.hostname
      to = {
        kind   = "Service"
        name   = "langsmith-frontend"
        weight = 100
      }
      port = {
        targetPort = "http"
      }
      tls = var.tls_enabled ? {
        termination                = "edge"
        insecureEdgeTerminationPolicy = "Redirect"
      } : null
    }
  }
}
