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

variable "public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the public EKS API endpoint"
  default     = ["0.0.0.0/0"]
}

variable "cluster_enabled_log_types" {
  type        = list(string)
  description = "EKS control plane log types to enable. Valid: api, audit, authenticator, controllerManager, scheduler."
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "eks_managed_node_group_defaults" {
  type        = any
  description = "Default configuration for EKS managed node groups"
  default = {
    ami_type = "AL2023_x86_64_STANDARD"
  }
}

variable "eks_managed_node_groups" {
  type = map(object({
    name           = string
    instance_types = list(string)
    min_size       = optional(number, 1)
    desired_size   = optional(number, null)
    max_size       = optional(number, 10)
  }))
  description = "EKS managed node groups. desired_size defaults to min_size when omitted."
  default = {
    default = {
      name           = "node-group-default"
      instance_types = ["m5.4xlarge"]
    }
  }
}

variable "enable_karpenter" {
  type        = bool
  description = "Install the Karpenter controller (via eks-blueprints-addons): controller IRSA, node IAM role, and the SQS interruption queue. Required for the SmithDB instance-store/compute pools. Coexists with cluster-autoscaler (disjoint nodes)."
  default     = false
}

variable "karpenter_chart_version" {
  type        = string
  description = "Karpenter Helm chart version. MUST be compatible with cluster_version - see https://karpenter.sh/docs/upgrading/compatibility/. K8s 1.33 needs >= 1.5 (1.34 -> 1.6, 1.35 -> 1.9, 1.36 -> 1.13). Uses the karpenter.sh/v1 + karpenter.k8s.aws/v1 APIs (Karpenter >= 1.0). Default targets the module's default EKS 1.33."
  default     = "1.5.0"
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

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace LangSmith runs in; scopes the IRSA trust policy"
  default     = "langsmith"
}

# Istio support
variable "enable_istio_gateway" {
  type        = bool
  description = "Open port 15017 on the node SG so the EKS API server can reach the istiod sidecar-injector webhook"
  default     = false
}

# EKS Blueprints Addons
variable "eks_addons" {
  type        = any
  description = "Map of EKS managed add-on configurations to enable for the cluster (coredns, kube-proxy, vpc-cni, etc.)"
  default     = {}
}
