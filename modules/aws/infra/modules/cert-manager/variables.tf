variable "cluster_name" {
  type        = string
  description = "EKS cluster name — used to scope the IAM role name"
}

variable "oidc_provider" {
  type        = string
  description = "OIDC provider URL (without https://) for IRSA trust policy"
}

variable "oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN for IRSA trust policy"
}

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID that cert-manager will write TXT records to for DNS-01 challenge"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all IAM resources created by this module"
  default     = {}
}

variable "iam_permissions_boundary_arn" {
  type        = string
  description = "Permissions boundary policy ARN for the IAM roles this module creates. Null sets no boundary."
  default     = null
}

variable "iam_role_path" {
  type        = string
  description = "IAM path for the IAM roles and instance profiles this module creates."
  default     = "/"
}
