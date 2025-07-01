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

variable "aks_oidc_issuer_url" {
  type        = string
  description = "OIDC issuer URL of the AKS cluster. Used to set up workload identity for blob storage."
}

variable "langsmith_namespace" {
  type        = string
  description = "Namespace of the LangSmith deployment"
  default     = "default"
}

variable "langsmith_release_name" {
  type        = string
  description = "Release name of the LangSmith Helm deployment. Used to set up workload identity for blob storage."
  default     = "langsmith"
}
