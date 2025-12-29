variable "cluster_name" {
  type        = string
  description = "The name of the cluster"
}

variable "cluster_version" {
  type        = string
  description = "The EKS version of the cluster"
  default     = "1.31"
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

variable "eks_managed_node_group_defaults" {
  type        = any
  description = "Default configuration for EKS managed node groups"
  default = {
    ami_type = "AL2023_x86_64_STANDARD"
  }
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

variable "create_gp3_storage_class" {
  type        = bool
  description = "Whether to create the gp3 storage class. The gp3 storage class will be patched to make it default and allow volume expansion."
  default     = true
}

# IRSA (IAM Roles for Service Accounts) settings
variable "create_langsmith_irsa_role" {
  type        = bool
  description = "Whether to create an IRSA role for LangSmith pods"
  default     = false
}

# EKS Blueprints Addons
variable "eks_addons" {
  type        = any
  description = "Map of EKS managed add-on configurations to enable for the cluster (coredns, kube-proxy, vpc-cni, etc.)"
  default     = {}
}
