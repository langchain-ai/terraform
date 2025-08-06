variable "identifier" {
  type        = string
  description = "Identifier for the database and related resources"
}

variable "db_name" {
  type        = string
  description = "Name of the database"
  default     = "postgres"
}

variable "instance_type" {
  type        = string
  description = "Instance type"
  default     = "db.t3.large" # 2 vCPU and 8 GB of memory
}

variable "storage_gb" {
  type        = number
  description = "Storage size in GB"
  default     = 10
}

variable "max_storage_gb" {
  type        = number
  description = "Maximum storage size in GB"
  default     = 100
}

variable "engine_version" {
  type        = string
  description = "Engine version"
  default     = "14"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs"
}

variable "ingress_cidrs" {
  type        = list(string)
  description = "Ingress CIDR blocks"
}

variable "username" {
  type        = string
  description = "Username for the database"
}

variable "password" {
  type        = string
  description = "Password for the database"
}
