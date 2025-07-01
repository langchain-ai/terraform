variable "network_name" {
  type        = string
  description = "Name of the virtual network"
}

variable "location" {
  type        = string
  description = "Location of the virtual network"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "address_space" {
  type        = list(string)
  description = "Address space of the virtual network"
  default     = ["10.0.0.0/17"] # 32k IP addresses
}

variable "main_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the main subnet. Can be disjoint IP ranges."
  default     = ["10.0.0.0/19"] # 8k IP addresses
}

variable "enable_external_postgres" {
  type        = bool
  description = "Enable external Postgres"
  default     = true
}

variable "enable_external_redis" {
  type        = bool
  description = "Enable external Redis"
  default     = true
}

variable "redis_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Redis subnet. Can be disjoint IP ranges."
  default     = ["10.0.48.0/20"] # 4k IP addresses
}

variable "postgres_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Postgres subnet. Can be disjoint IP ranges."
  default     = ["10.0.32.0/20"] # 4k IP addresses
}
