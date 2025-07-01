variable "location" {
  type        = string
  description = "The location of the LangSmith deployment"
  default     = "eastus"
}

variable "subscription_id" {
  type        = string
  description = "The subscription id of the LangSmith deployment"
}

variable "create_vnet" {
  type        = bool
  description = "Whether to create a new VNet. If false, you will need to provide a vnet id and subnet ids."
  default     = true
}

variable "vnet_id" {
  type        = string
  description = "The id of the existing VNet to use. If create_vnet is false, this is required."
  default     = ""
}

variable "aks_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the AKS cluster. If create_vnet is false, this is required."
  default     = ""
}

variable "postgres_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Postgres server. If create_vnet is false, this is required."
  default     = ""
}

variable "redis_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Redis server. If create_vnet is false, this is required."
  default     = ""
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

variable "aks_service_cidr" {
  type        = string
  description = "The service CIDR of the AKS cluster"
  default     = "10.0.64.0/20"
}

variable "aks_dns_service_ip" {
  type        = string
  description = "The DNS service IP of the AKS cluster"
  default     = "10.0.64.10"
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Additional node pools to be created"
  default = {
    large = {
      vm_size   = "Standard_D8_v5"
      min_count = 0
      max_count = 2
    }
  }
}

variable "postgres_admin_username" {
  type        = string
  description = "The username of the Postgres administrator"
}

variable "postgres_admin_password" {
  type        = string
  description = "The password of the Postgres administrator"
}
