variable "kubeconfig_path" {
  description = "Path to the kubeconfig file for the OpenShift cluster"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Kubeconfig context name for the OpenShift cluster"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "project" {
  description = "Project name used for resource naming"
  type        = string
}

variable "hostname" {
  description = "Hostname for the LangSmith Route (e.g. langsmith.apps.cluster.example.com). Used by the dns module."
  type        = string
  default     = ""
}
