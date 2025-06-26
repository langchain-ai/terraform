variable "name" {
  type        = string
  description = "Name of the Redis instance"
}

variable "location" {
  type        = string
  description = "Location of the Redis instance"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name of the Redis instance"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID of the Redis instance"
}

variable "sku_name" {
  type        = string
  description = "SKU name of the Redis instance"
  default     = "Premium"
}

variable "family" {
  type        = string
  description = "Family of the Redis instance"
  default     = "P"
}

# You can see the capacity options here: https://azure.microsoft.com/en-us/pricing/details/cache/?cdn=disable
variable "capacity" {
  type        = number
  description = "Capacity of the Redis instance"
  default     = 2
}

variable "enable_redis_cluster" {
  type        = bool
  description = "Enable Redis cluster"
  default     = false
}

variable "redis_cluster_sku_name" {
  type        = string
  description = "SKU name of the Redis enterprise cluster"
  default     = "Enterprise_E200-2"
}
