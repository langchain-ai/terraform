variable "regions" {
  description = "AWS regions in this account in which the shared roles may operate LangSmith data planes."
  type        = set(string)

  validation {
    condition     = length(var.regions) > 0 && alltrue([for region in var.regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", region))])
    error_message = "Provide at least one explicit AWS region; wildcards are not allowed."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional customer IAM permissions boundary applied to all 16 application/infrastructure roles (not AWS service-linked roles)."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/[a-zA-Z0-9/+=,.@_-]+$", var.permissions_boundary_arn))
    error_message = "Supply an IAM policy ARN without wildcards."
  }
}

variable "service_linked_roles_to_create" {
  description = "AWS service names whose account-level service-linked roles Terraform should create. Leave existing roles out or import them first; see README."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([for service in var.service_linked_roles_to_create : contains([
      "eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "elasticloadbalancing.amazonaws.com",
      "rds.amazonaws.com", "elasticache.amazonaws.com", "autoscaling.amazonaws.com", "spot.amazonaws.com"
    ], service)])
    error_message = "Select only the documented EKS, ELB, RDS, ElastiCache, Auto Scaling, or Spot service-linked roles."
  }
}

variable "tags" {
  description = "Customer tags for IAM resources. Required IAM ownership tags cannot be overridden."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "managed_by")
    error_message = "Do not label customer-owned IAM resources managed_by=langsmith; that tag authorizes provisioning-role mutations."
  }
}
