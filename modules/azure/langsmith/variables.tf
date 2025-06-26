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

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_D4_v5" # 4 vCPU, 16GB RAM
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max count of the default node pool"
  default     = 10
}

variable "large_node_pool_enabled" {
  type        = bool
  description = "Whether to enable the large node pool"
  default     = true
}

variable "large_node_pool_vm_size" {
  type        = string
  description = "VM size of the large node pool"
  default     = "Standard_D8_v5" # 8 vCPU, 32GB RAM
}

variable "large_node_pool_max_count" {
  type        = number
  description = "Max count of the large node pool"
  default     = 2
}


variable "postgres_admin_username" {
  type        = string
  description = "The username of the Postgres administrator"
}

variable "postgres_admin_password" {
  type        = string
  description = "The password of the Postgres administrator"
}
