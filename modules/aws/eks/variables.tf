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

variable "eks_managed_node_groups" {
  type        = map(any)
  description = "EKS managed node groups"
  default = {
    default = {
      name           = "node-group-default"
      instance_types = ["m5.4xlarge"]
      min_size       = 1
      max_size       = 10
    }
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the resources"
  default     = {}
}

variable "patch_storage_class" {
  type        = bool
  description = "Whether to patch the gp2 storage class to make it default and allow volume expansion."
  default     = true
}
