variable "storage_account_name" {
  type        = string
  description = "Name of the storage account"
}

variable "container_name" {
  type        = string
  description = "Name of the container"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name of the storage account"
}

variable "location" {
  type        = string
  description = "Location of the storage account"
}

variable "ttl_enabled" {
  type        = bool
  description = "Whether to enable time to live for blobs by adding a lifecycle policy"
  default     = true
}

variable "ttl_short_days" {
  type        = number
  description = "Time to live for short-lived blobs in days"
  default     = 14
}

variable "ttl_long_days" {
  type        = number
  description = "Time to live for long-lived blobs in days"
  default     = 400
}

variable "workload_identity_principal_id" {
  type        = string
  description = "Principal ID of the User-Assigned Managed Identity created by the k8s-cluster module. Granted Storage Blob Data Contributor on this account."
}

variable "workload_identity_client_id" {
  type        = string
  description = "Client ID of the User-Assigned Managed Identity. Passed through as an output for k8s-bootstrap annotation."
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}
