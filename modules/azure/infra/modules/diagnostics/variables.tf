variable "name" {
  type        = string
  description = "Name of the Log Analytics workspace"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the Log Analytics workspace"
}

variable "location" {
  type        = string
  description = "Azure region"
}

variable "retention_days" {
  type        = number
  description = "Log retention period in days (min 30, max 730)"
  default     = 90
}

variable "aks_id" {
  type        = string
  description = "Resource ID of the AKS cluster to enable diagnostic settings on. Leave empty to skip."
  default     = ""
}

variable "keyvault_id" {
  type        = string
  description = "Resource ID of the Key Vault to enable diagnostic settings on. Leave empty to skip."
  default     = ""
}

variable "postgres_id" {
  type        = string
  description = "Resource ID of the PostgreSQL Flexible Server to enable diagnostic settings on. Leave empty to skip."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags"
  default     = {}
}
