variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "cluster_name" {
  type        = string
  description = "Name of the cluster"
}

variable "location" {
  type        = string
  description = "Location of the cluster"
}

variable "subnet_id" {
  description = "The ID of the subnet where the AKS cluster will be deployed"
  type        = string
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version of the cluster"
  default     = "1.33" # 1.32 and below are LTS-only in eastus as of April 2026; use 1.33+ for standard tier
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_DS3_v2" # 4 vCPU, 14GB RAM — DSv2 family (60 free vCPUs in eastus)
}

variable "default_node_pool_min_count" {
  type        = number
  description = "Min count of the default node pool. Autoscaler never scales below this. Set to 3 for production — Pass 2 needs ~14.4 vCPU and 3× Standard_D8s_v3 provides 18,870m allocatable."
  default     = 1
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max count of the default node pool"
  default     = 10
}

variable "default_node_pool_max_pods" {
  type        = number
  description = "Max pods per node in the default node pool. AKS default is 30 (Azure CNI). LangSmith Pass 2 deploys ~17 pods; Pass 3 adds ~20 more. Set to 60 to fit a full multi-pass deployment on a single node without triggering autoscaler quota limits."
  default     = 60
}

variable "service_cidr" {
  type        = string
  description = "Service CIDR of the cluster"
  default     = "10.0.64.0/20"
}

variable "dns_service_ip" {
  type        = string
  description = "DNS service IP of the cluster"
  default     = "10.0.64.10"
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Node pools to be created"
  default = {
    large = {
      vm_size   = "Standard_DS4_v2" # 8 vCPU, 28GB RAM — DSv2 family
      min_count = 0
      max_count = 2
    }
  }
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace where LangSmith is deployed. Used for Workload Identity federation."
  default     = "langsmith"
}

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith. Used to generate federated identity credential subjects."
  default     = "langsmith"
}

variable "workload_identity_name" {
  type        = string
  description = "Override the managed identity name. Set to the existing identity name when migrating from the storage module to avoid recreating it."
  default     = ""
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the default node pool. Use [\"1\",\"2\",\"3\"] for zone-redundant HA."
  default     = ["1"]
}

# ── Network (Azure CNI Overlay + Cilium + UDR — hardcoded in main.tf) ─────────
# pod_cidr is the only tunable: pods get IPs from this range (not from the VNet
# subnet). Must not overlap the VNet, service_cidr, or any peered network.

variable "pod_cidr" {
  type        = string
  description = "Pod CIDR for Azure CNI Overlay (network_plugin_mode = overlay). Must not overlap the VNet, service_cidr, or peered/on-prem ranges. Ignored in classic mode."
  default     = "10.244.0.0/16"
}

# ── Private API server ────────────────────────────────────────────────────────
# private_cluster_enabled is hardcoded true in main.tf (always private).

variable "private_cluster_public_fqdn_enabled" {
  type        = bool
  description = "When private_cluster_enabled, also expose a public FQDN resolving to the private IP. Default false (public FQDN disabled). Ignored when the cluster is public."
  default     = false
}

variable "private_dns_zone_id" {
  type        = string
  description = "Private DNS zone for the private API server. \"\" => \"System\" (AKS-managed zone). \"None\" => bring-your-own DNS. Or a private DNS zone resource ID (requires Private DNS Zone Contributor for the cluster identity + VNet link). Only used when private_cluster_enabled."
  default     = ""
}

# ── Control-plane (cluster) managed identity ───────────────────────────────────

variable "create_cluster_identity" {
  type        = bool
  description = "Create a user-assigned managed identity for the AKS control plane and grant it Network Contributor on the VNet (the parent of subnet_id) — VNet scope so it can both join the subnet and link the System private DNS zone for a private cluster. Default true (user-assigned by default). Set false ONLY when bringing your own via cluster_identity_id (mutually exclusive)."
  default     = true
}

variable "cluster_identity_id" {
  type        = string
  description = "Resource ID of an existing user-assigned managed identity to use as the AKS control-plane identity. You manage its role assignments (Network Contributor on the VNet/subnet, Private DNS Zone Contributor on a custom private DNS zone). Mutually exclusive with create_cluster_identity. Empty => system-assigned."
  default     = ""
}
