variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "cluster_name" {
  type        = string
  description = "Name of the cluster"
}

variable "location" {
  type        = string
  description = "Location of the cluster"
}

variable "subnet_id" {
  description = "The ID of the subnet where the AKS cluster will be deployed"
  type        = string
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version of the cluster"
  default     = "1.30"
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_D4_v5" # 4 vCPU, 16GB RAM
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
