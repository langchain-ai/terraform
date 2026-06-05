variable "name" {
  type        = string
  description = "Name of the Azure Managed Redis cluster"
}

variable "location" {
  type        = string
  description = "Location of the Redis instance"
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
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest. See `az redisenterprise create -h` for the list."
  default     = "Balanced_B0"
}

variable "clustering_policy" {
  type        = string
  description = "AMR clustering policy. OSSCluster is what LangSmith expects."
  default     = "OSSCluster"
}

variable "high_availability" {
  type        = bool
  description = "Zone-redundant HA. NOT supported on the smallest (B0) SKU — keep false there."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}
