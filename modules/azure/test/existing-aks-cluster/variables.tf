// MIT License - Copyright (c) 2026 LangChain, Inc.
// NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
// See LICENSE at the root of this repository for full license text.

variable "subscription_id" {
  description = "Azure subscription to build the prerequisite infrastructure in."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID. Get it with: az account show --query id -o tsv"
  }
}

variable "name_prefix" {
  description = "Prefix for the resource group, VNet, and cluster names."
  type        = string
  default     = "existing-cluster-test"
}

variable "location" {
  description = <<-EOT
    Azure region. Needs Azure Managed Redis (Microsoft.Cache/redisEnterprise),
    Postgres Flexible Server, and enough Dsv5 vCPU quota for the node pool.
    Check quota with: az vm list-usage --location <region> \
      --query "[?contains(name.value,'standardDSv5Family')]" -o table
  EOT
  type        = string
  default     = "eastus2"
}

variable "owner" {
  description = "Value for the owner tag, so the resource group is attributable."
  type        = string
}

variable "vnet_address_space" {
  description = "Address space for the customer VNet."
  type        = string
  default     = "10.42.0.0/16"
}

variable "aks_subnet_prefix" {
  description = <<-EOT
    Node and pod subnet. Azure CNI is flat, so this must hold
    (max_count + 1) * (max_pods + 1) addresses for every pool the LangSmith module
    is configured with. A /22 covers that module's bare defaults, which ask for 764.
  EOT
  type        = string
  default     = "10.42.0.0/22"
}

variable "postgres_subnet_prefix" {
  description = "Delegated Postgres subnet. Azure's floor for a delegated subnet is /28."
  type        = string
  default     = "10.42.8.0/24"
}

variable "redis_subnet_prefix" {
  description = "Holds the Azure Managed Redis private endpoint. Must not be delegated."
  type        = string
  default     = "10.42.9.0/24"
}

variable "aks_service_cidr" {
  description = <<-EOT
    Kubernetes ClusterIP range. Not carved from the VNet and must not overlap it.
    The langsmith_tfvars output passes the same value to the LangSmith module.
  EOT
  type        = string
  default     = "172.16.0.0/20"
}

variable "kubernetes_version" {
  description = "AKS version, matching the LangSmith module's aks_kubernetes_version default. Check availability with: az aks get-versions --location <region> -o table"
  type        = string
  default     = "1.35"
}

variable "node_vm_size" {
  description = "Node size. Standard_D8s_v5 matches the LangSmith module's default_node_pool_vm_size, and LangSmith runs on this pool when the module attaches without managing node pools."
  type        = string
  default     = "Standard_D8s_v5"
}

variable "node_min_count" {
  description = "Autoscaler floor for the default pool."
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Autoscaler ceiling for the default pool."
  type        = number
  default     = 4
}

variable "availability_zones" {
  description = "Zones for the default node pool."
  type        = list(string)
  default     = ["1"]
}
