variable "cluster_name" {
  type        = string
  description = "Name of the dedicated sandbox EKS cluster"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the dedicated sandbox EKS cluster"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID shared with the LangSmith EKS cluster"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the dedicated sandbox EKS cluster"
}

variable "managed_node_group_defaults" {
  type        = any
  description = "Default settings for the sandbox EKS managed node group"
  default     = {}
}

variable "managed_node_group" {
  type        = any
  description = "Sandbox-host EKS managed node group configuration"
}

variable "cluster_addons" {
  type        = any
  description = "Additional EKS managed addon configuration"
  default     = {}
}

variable "public_cluster_enabled" {
  type        = bool
  description = "Whether the sandbox EKS API endpoint is publicly reachable"
  default     = false
}

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public sandbox EKS API endpoint"
  default     = ["0.0.0.0/0"]
}

variable "cluster_enabled_log_types" {
  type        = list(string)
  description = "EKS control-plane log types enabled for the sandbox cluster"
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to sandbox EKS resources"
  default     = {}
}
