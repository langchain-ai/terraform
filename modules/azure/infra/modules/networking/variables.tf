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

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "postgres_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Postgres subnet. Can be disjoint IP ranges."
  default     = ["10.0.32.0/20"] # 4k IP addresses
}

variable "enable_bastion" {
  type        = bool
  description = "Create a dedicated subnet for the bastion/jump host"
  default     = false
}

variable "bastion_subnet_address_prefix" {
  type        = list(string)
  description = "CIDR prefix for the bastion subnet"
  default     = ["10.0.80.0/27"] # 32 IPs — sufficient for a single jump VM
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to spread resources across. Use [\"1\",\"2\",\"3\"] for zone-redundant HA. Default [\"1\"] for single-zone (lower cost)."
  default     = ["1"]
}

variable "enable_agic" {
  type        = bool
  description = "Create a dedicated subnet for AGIC (Application Gateway Ingress Controller). Required when ingress_controller = 'agic'."
  default     = false
}

variable "agic_subnet_address_prefix" {
  type        = list(string)
  description = "CIDR prefix for the Application Gateway subnet. Must be /24 or larger (Azure AGW requirement). Must not overlap with other subnets."
  default     = ["10.0.96.0/24"] # 256 IPs — min size for App Gateway v2
}
