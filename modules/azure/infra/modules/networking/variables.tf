variable "network_name" {
  type        = string
  description = "Name of the virtual network"
}

variable "create_vnet" {
  type        = bool
  description = "Create the VNet. When false, subnets are created inside the VNet identified by existing_vnet_id."
  default     = true
}

variable "existing_vnet_id" {
  type        = string
  description = "Resource ID of an existing VNet to create subnets in. Required when create_vnet = false."
  default     = ""
}

variable "create_main_subnet" {
  type        = bool
  description = "Create the main (AKS) subnet. False when an existing AKS subnet is supplied."
  default     = true
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

variable "create_postgres_subnet" {
  type        = bool
  description = "Create the delegated Postgres subnet. False when Postgres is in-cluster, or when an existing Postgres subnet is supplied."
  default     = true
}

variable "create_redis_subnet" {
  type        = bool
  description = "Create the Redis subnet. False when Redis is in-cluster, or when an existing Redis subnet is supplied."
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
