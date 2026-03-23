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
  description = "Resource ID of the AKS cluster to enable diagnostic settings on."
  default     = ""
}

variable "keyvault_id" {
  type        = string
  description = "Resource ID of the Key Vault to enable diagnostic settings on."
  default     = ""
}

variable "postgres_id" {
  type        = string
  description = "Resource ID of the PostgreSQL Flexible Server to enable diagnostic settings on."
  default     = ""
}

# Boolean flags for count — must be known at plan time (cannot use computed IDs for count).
variable "enable_aks_diag" {
  type        = bool
  description = "Whether to create the AKS diagnostic setting. Set to true when AKS is being created."
  default     = true
}

variable "enable_keyvault_diag" {
  type        = bool
  description = "Whether to create the Key Vault diagnostic setting. Set to true when Key Vault is being created."
  default     = true
}

variable "enable_postgres_diag" {
  type        = bool
  description = "Whether to create the PostgreSQL diagnostic setting. Set to true when postgres_source = external."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags"
  default     = {}
}
