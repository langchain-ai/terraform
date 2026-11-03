#------------------------------------------------------------------------------
# The cluster add-ons this module installs, each skippable for a cluster that
# already has its own: a customer's OpenShift, kubeadm or private cloud ships a
# metrics API, a StorageClass, a load balancer and often a Gateway. Installing
# ours beside theirs clashes (two local-path provisioners, two MetalLBs on one
# LAN). Every default installs the add-on; the moved blocks keep each add-on's
# state where count puts it.
#------------------------------------------------------------------------------

variable "install_metrics_server" {
  type        = bool
  default     = true
  description = "Install metrics-server. false when the cluster already serves metrics.k8s.io (the HPAs need it)."
}

variable "install_local_path" {
  type        = bool
  default     = true
  description = "Install the local-path provisioner and its two StorageClasses. false needs storage_class: the cluster's own class for every volume."
}

variable "storage_class" {
  type        = string
  default     = ""
  description = "With install_local_path = false: the cluster's StorageClass for the datastores, ClickHouse, TaskDB and the SmithDB cache."
}

variable "install_metallb" {
  type        = bool
  default     = true
  description = "Install MetalLB for LoadBalancer Services. false when the cluster has a load balancer (F5, a cloud LB, its own MetalLB)."
}

variable "install_envoy_gateway" {
  type        = bool
  default     = true
  description = "Install Envoy Gateway and the Gateway the chart attaches its HTTPRoutes to. false needs existing_gateway."
}

variable "existing_gateway" {
  type = object({
    name      = string
    namespace = string
  })
  default     = null
  description = "With install_envoy_gateway = false: the Gateway API Gateway, already in the cluster, that LangSmith's HTTPRoutes attach to."
}

variable "gateway_tls_secret" {
  type        = string
  default     = ""
  description = "With our Envoy Gateway: a kubernetes.io/tls Secret in the langsmith namespace whose certificate covers langsmith_domain. Adds an HTTPS listener for the domain (the LAN IP stays HTTP). The module makes no certificate: cert-manager, or the customer's CA, writes the Secret. Needs langsmith_domain and langsmith_url_scheme = https."
}

locals {
  storage_class_retain = var.install_local_path ? module.local_path[0].storage_class_retain : var.storage_class
  storage_class_delete = var.install_local_path ? module.local_path[0].storage_class_delete : var.storage_class
  gateway              = var.install_envoy_gateway ? module.envoy_gateway[0].gateway : var.existing_gateway

  platform_problems = compact([
    !var.install_local_path && var.storage_class == "" ? "install_local_path = false needs storage_class" : "",
    !var.install_envoy_gateway && var.existing_gateway == null ? "install_envoy_gateway = false needs existing_gateway" : "",
    # The URL falls back to the gateway IP, which only our MetalLB serves; an empty hostname renders an HTTPRoute the API server refuses.
    !(var.install_metallb && var.install_envoy_gateway) && var.langsmith_domain == "" ? "without this module's MetalLB and Envoy Gateway, set langsmith_domain: the gateway's address is not ours to name" : "",
    var.install_metallb && length(var.metallb_addresses) == 0 ? "install_metallb needs metallb_addresses" : "",
    var.install_envoy_gateway && var.install_metallb && var.envoy_gateway_lb_ip == "" ? "envoy_gateway_lb_ip is required when this module installs both MetalLB and Envoy Gateway" : "",
    var.gateway_tls_secret != "" && !var.install_envoy_gateway ? "gateway_tls_secret is for this module's Envoy Gateway: on existing_gateway, TLS is that Gateway's" : "",
    var.gateway_tls_secret != "" && (var.langsmith_domain == "" || var.langsmith_url_scheme != "https") ? "gateway_tls_secret needs langsmith_domain and langsmith_url_scheme = https" : "",
  ])
}

resource "terraform_data" "platform" {
  input = {
    metrics_server = var.install_metrics_server
    local_path     = var.install_local_path
    metallb        = var.install_metallb
    envoy_gateway  = var.install_envoy_gateway
  }

  lifecycle {
    precondition {
      condition     = length(local.platform_problems) == 0
      error_message = "Platform: ${join("; ", local.platform_problems)}."
    }
  }
}

moved {
  from = module.metrics_server
  to   = module.metrics_server[0]
}

moved {
  from = module.local_path
  to   = module.local_path[0]
}

moved {
  from = module.metallb
  to   = module.metallb[0]
}

moved {
  from = module.envoy_gateway
  to   = module.envoy_gateway[0]
}
