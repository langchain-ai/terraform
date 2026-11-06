variable "cluster_name" {
  type        = string
  description = "Name of the sandbox cluster. Also its DNS prefix."
}

variable "location" {
  type        = string
  description = "Region of the sandbox cluster."
}

variable "resource_group_name" {
  type        = string
  description = "Resource group the sandbox cluster is created in."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version of the sandbox cluster. The root passes the LangSmith cluster's, so both clusters upgrade together."
}

variable "sku_tier" {
  type        = string
  description = "AKS pricing tier: Free, Standard or Premium."
}

variable "support_plan" {
  type        = string
  description = "KubernetesOfficial or AKSLongTermSupport."
}

variable "subnet_id" {
  type        = string
  description = "Subnet both node pools run in. Only nodes take addresses from it: pods use pod_cidr (Azure CNI overlay)."
}

variable "pod_cidr" {
  type        = string
  description = "Overlay pod range. Private to the cluster, so it may repeat the LangSmith cluster's range."
}

variable "service_cidr" {
  type        = string
  description = "ClusterIP range. Private to the cluster, so it may repeat the LangSmith cluster's range."
}

variable "dns_service_ip" {
  type        = string
  description = "CoreDNS ClusterIP, inside service_cidr."
}

variable "availability_zones" {
  type        = list(string)
  description = "Zones for both node pools. Empty lets Azure place them."
  default     = []
}

variable "os_sku" {
  type        = string
  description = "Node OS image for both pools."
  default     = "Ubuntu"
}

variable "system_node_vm_size" {
  type        = string
  description = "VM size of the system pool, which runs only the add-ons AKS marks critical (CoreDNS, konnectivity, the Workload Identity webhook)."
}

variable "system_node_count" {
  type        = number
  description = "Fixed node count of the system pool."
}

variable "sandbox_host_pool" {
  type = object({
    vm_size         = string
    min_count       = number
    max_count       = number
    node_labels     = map(string)
    node_taints     = list(string)
    os_disk_size_gb = number
  })
  description = "The sandbox-host pool: a VM size with nested virtualization, its autoscaler bounds, and the label and taint the runtime chart selects and tolerates."
}

variable "private_cluster_enabled" {
  type        = bool
  description = "Private API server, following the LangSmith cluster."
  default     = false
}

variable "private_dns_zone_id" {
  type        = string
  description = "\"System\" or \"None\" for a private API server. A zone resource ID is not supported here: it needs a user-assigned control-plane identity with grants on the zone."
  default     = "System"

  validation {
    condition     = contains(["System", "None"], var.private_dns_zone_id)
    error_message = "private_dns_zone_id must be \"System\" or \"None\"."
  }
}

variable "entra_only" {
  type        = bool
  description = "Entra ID integration with Azure RBAC and no local accounts, following the LangSmith cluster."
  default     = false
}

variable "entra_admin_group_object_ids" {
  type        = list(string)
  description = "Entra groups that get cluster-admin when entra_only is true."
  default     = []
}

variable "authorized_ip_ranges" {
  type        = list(string)
  description = "CIDRs allowed to reach the API server. Empty leaves it reachable from anywhere."
  default     = []
}

variable "kube_auth" {
  type        = string
  description = "How the root's sandbox Kubernetes provider signs in: 'auto' follows entra_only, 'entra' and 'certificate' force one."
  default     = "auto"

  validation {
    condition     = contains(["auto", "entra", "certificate"], var.kube_auth)
    error_message = "kube_auth must be 'auto', 'entra', or 'certificate'."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags for the cluster and its node pools."
  default     = {}
}

variable "outbound_type" {
  type        = string
  description = "How the sandbox nodes reach the internet; the root passes aks_outbound_type, so sandbox egress takes the same path as the LangSmith cluster's. userDefinedRouting and userAssignedNATGateway need the route table or NAT gateway on the sandbox subnet."
  default     = "loadBalancer"

  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting", "userAssignedNATGateway"], var.outbound_type)
    error_message = "outbound_type must be \"loadBalancer\", \"userDefinedRouting\" or \"userAssignedNATGateway\"."
  }
}
