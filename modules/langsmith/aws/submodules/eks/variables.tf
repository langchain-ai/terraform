variable "cluster_name" {
  type        = string
  description = "The name of the cluster"
}

variable "cluster_version" {
  type        = string
  description = "The EKS version of the cluster"
  default     = "1.30"
}

variable "vpc_id" {
  type        = string
  description = "The ID of the VPC"
}

variable "subnet_ids" {
  type        = list(string)
  description = "The IDs of the subnets"
}

variable "public_cluster_enabled" {
  type        = bool
  description = "Whether to enable public cluster access"
  default     = true
}

variable "small_node_instance_type" {
  type        = string
  description = "The instance type of the small node group"
  default     = "t3.large"
}

variable "large_node_instance_type" {
  type        = string
  description = "The instance type of the large node group"
  default     = "m5.4xlarge"
}
