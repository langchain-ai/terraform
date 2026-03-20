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
  default     = "1.32" # 1.30 is LTS-only; use 1.31 or 1.32 for standard tier
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_DS3_v2" # 4 vCPU, 14GB RAM — DSv2 family (60 free vCPUs in eastus)
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max count of the default node pool"
  default     = 10
}

variable "service_cidr" {
  type        = string
  description = "Service CIDR of the cluster"
  default     = "10.0.64.0/20"
}

variable "dns_service_ip" {
  type        = string
  description = "DNS service IP of the cluster"
  default     = "10.0.64.10"
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Node pools to be created"
  default = {
    large = {
      vm_size   = "Standard_DS4_v2" # 8 vCPU, 28GB RAM — DSv2 family
      min_count = 0
      max_count = 2
    }
  }
}

variable "nginx_ingress_enabled" {
  type        = bool
  description = "Install the nginx ingress helm chart on the AKS cluster."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace where LangSmith is deployed. Used for Workload Identity federation."
  default     = "langsmith"
}

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith. Used to generate federated identity credential subjects."
  default     = "langsmith"
}

variable "workload_identity_name" {
  type        = string
  description = "Override the managed identity name. Set to the existing identity name when migrating from the storage module to avoid recreating it."
  default     = ""
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the default node pool. Use [\"1\",\"2\",\"3\"] for zone-redundant HA."
  default     = ["1"]
}
