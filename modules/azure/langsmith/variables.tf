variable "location" {
  type        = string
  description = "The location of the LangSmith deployment"
  default     = "eastus"
}

variable "enable_external_postgres" {
  type        = bool
  description = "Enable external Postgres for your LangSmith deployment. This will provision a Postgres server in the same VNet as your LangSmith deployment."
  default     = true
}

variable "enable_external_redis" {
  type        = bool
  description = "Enable external Redis for your LangSmith deployment. This will provision a Redis server in the same VNet as your LangSmith deployment."
  default     = true
}

variable "redis_capacity" {
  type        = number
  description = "The capacity of the Redis server"
  default     = 2
}

variable "enable_redis_cluster" {
  type        = bool
  description = "Enable Redis cluster for your LangSmith deployment. This will provision a Redis cluster in addition to the Redis server."
  default     = false
}

variable "redis_cluster_sku_name" {
  type        = string
  description = "The SKU name of the Redis cluster"
  default     = ""
}

variable "blob_ttl_enabled" {
  type        = bool
  description = "Enable TTL for the blob container"
  default     = true
}

variable "blob_ttl_short_days" {
  type        = number
  description = "The number of days to keep short-lived blobs"
  default     = 14
}

variable "blob_ttl_long_days" {
  type        = number
  description = "The number of days to keep long-lived blobs"
  default     = 400
}

variable "postgres_admin_username" {
  type        = string
  description = "The username of the Postgres administrator"
}

variable "postgres_admin_password" {
  type        = string
  description = "The password of the Postgres administrator"
}
