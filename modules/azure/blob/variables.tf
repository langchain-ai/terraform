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
