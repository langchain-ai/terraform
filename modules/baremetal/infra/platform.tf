#------------------------------------------------------------------------------
# The cluster add-ons this module installs, each skippable for a cluster that
# already has its own: an OpenShift, kubeadm or private-cloud cluster ships a
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
  description = "With install_local_path = false: the cluster's StorageClass for the datastores, ClickHouse, TaskDB and the SmithDB cache. Its reclaimPolicy must be Retain: the datastores' volumes outlive a deleted claim only then."
}

# The given class holds Postgres, Redis and the object store. With reclaimPolicy Delete, as k3s's own
# local-path and most CSI defaults ship, a deleted claim, a replaced release or a deleted namespace
# deleted the data with it, while TEARDOWN.md promised the volumes were kept.
data "kubernetes_storage_class_v1" "given" {
  count = !var.install_local_path && var.storage_class != "" ? 1 : 0
  metadata {
    name = var.storage_class
  }
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
  description = "With our Envoy Gateway: a kubernetes.io/tls Secret in the langsmith namespace whose certificate covers langsmith_domain. Adds an HTTPS listener for the domain (the LAN IP stays HTTP). The module makes no certificate: cert-manager, or an internal CA, writes the Secret. Needs langsmith_domain and langsmith_url_scheme = https."
}

locals {
  # The output's Gateway: ours with its class and LAN IP, or the one given.
  gateway = var.install_envoy_gateway ? module.envoy_gateway[0].gateway : var.existing_gateway
  # An existing gateway gets no hostless route from this module: on a shared one it would take these
  # paths from every other host.
  lan_route = var.install_envoy_gateway && var.langsmith_domain != ""
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
      condition     = length(module.values.problems.platform) == 0
      error_message = "Platform: ${join("; ", module.values.problems.platform)}."
    }
    precondition {
      condition     = length(data.kubernetes_storage_class_v1.given) == 0 || data.kubernetes_storage_class_v1.given[0].reclaim_policy == "Retain"
      error_message = "StorageClass ${var.storage_class} has reclaimPolicy ${join("", data.kubernetes_storage_class_v1.given[*].reclaim_policy)}: a deleted claim would delete the datastore's data. Give storage_class a class with reclaimPolicy Retain (a copy of it with that one field changed), or keep install_local_path = true."
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

#------------------------------------------------------------------------------
# Is envoy_gateway_lb_ip inside the MetalLB pool? IPs become numbers so ranges
# (a.b.c.d-a.b.c.e) and CIDRs can be compared.
#------------------------------------------------------------------------------
locals {
  # Empty when the module installs no MetalLB or Envoy: nothing to compare against the pool then.
  lb_ip_octets = var.envoy_gateway_lb_ip == "" ? [0, 0, 0, 0] : [for o in split(".", var.envoy_gateway_lb_ip) : tonumber(o)]
  lb_ip_num    = local.lb_ip_octets[0] * 16777216 + local.lb_ip_octets[1] * 65536 + local.lb_ip_octets[2] * 256 + local.lb_ip_octets[3]

  metallb_bounds = [
    for a in var.metallb_addresses : [
      for ip in(can(cidrhost(a, 0)) ? [cidrhost(a, 0), cidrhost(a, -1)] : split("-", a)) :
      sum([for i, o in split(".", ip) : tonumber(o) * pow(256, 3 - i)])
    ]
  ]
  lb_ip_in_pool = anytrue([for b in local.metallb_bounds : local.lb_ip_num >= b[0] && local.lb_ip_num <= b[1]])
}
