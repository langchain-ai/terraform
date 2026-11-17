#------------------------------------------------------------------------------
# Inputs for metrics-server.
# Covers chart version, namespace, kubelet TLS mode and resources.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "chart_version" {
  type        = string
  description = "metrics-server Helm chart version (exact pin)."
}

variable "namespace" {
  type        = string
  default     = "kube-system"
  description = "Namespace for metrics-server. kube-system is the upstream default."
}

variable "kubelet_insecure_tls" {
  type        = bool
  description = <<-EOT
    Skip verifying kubelet serving certificates. kubeadm kubelets serve a
    self-signed certificate by default, so metrics-server can't verify them.
    The connection stays encrypted but unauthenticated. The secure alternative
    is serverTLSBootstrap = true in the kubelet config plus CSR approval; then
    set this to false.
  EOT
}

variable "resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Container requests and limits (from the root budget)."
}
