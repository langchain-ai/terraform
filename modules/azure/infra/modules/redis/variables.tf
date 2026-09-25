variable "name" {
  type        = string
  description = "Name of the Azure Managed Redis cluster"
}

variable "location" {
  type        = string
  description = "Location of the Redis instance"
}

variable "cluster_location" {
  type        = string
  description = "Region for the AMR cluster itself. Defaults to var.location. Set this only when AMR has no capacity in the deployment's region — the private endpoint stays in var.location either way, because it must be co-regional with its subnet."
  default     = null
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name (for the private endpoint + DNS zone)"
}

variable "resource_group_id" {
  type        = string
  description = "Resource group ID — azapi parent_id for the AMR cluster"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the AMR private endpoint (the dedicated redis subnet)"
}

variable "vnet_id" {
  type        = string
  description = "VNet ID — linked to the private DNS zone so the hostname resolves to the PE"
}

variable "amr_sku" {
  type        = string
  description = "Azure Managed Redis SKU. See `az redisenterprise create -h` for the list. No default — the caller owns the size so it can't drift from the root default."
}

variable "clustering_policy" {
  type        = string
  description = "AMR clustering policy. OSSCluster selects the LangSmith cluster client; EnterpriseCluster the standalone client with clusterSafeMode."
  default     = "OSSCluster"

  # The outputs branch on this string, so a typo silently picks the wrong client.
  validation {
    condition     = contains(["OSSCluster", "EnterpriseCluster"], var.clustering_policy)
    error_message = "clustering_policy must be 'OSSCluster' or 'EnterpriseCluster'."
  }
}

variable "high_availability" {
  type        = bool
  description = "Zone-redundant HA (primary + replica across nodes). Required for the AMR SLA. NOT supported on the smallest (B0) SKU — keep false there."
  default     = false

  # Cross-variable validation (Terraform >= 1.9). On the child variable rather than
  # the root one so it is only evaluated when this module is instantiated, which is
  # when redis_source = "external" and these two values actually matter.
  validation {
    condition     = !(var.high_availability && var.amr_sku == "Balanced_B0")
    error_message = "Balanced_B0 cannot run high availability. Use Balanced_B1 or larger, or set redis_high_availability = false."
  }
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}
