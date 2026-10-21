variable "role_name" {
  description = "Name of the IAM role to be created in the target account."
  type        = string
}

variable "control_plane_reconcile_role_arn" {
  description = "ARN of the LangChain control plane reconciliation role."
  type        = string
}

variable "external_id" {
  description = "External ID copied from Settings > Data Planes in the LangSmith UI, required to assume this role."
  type        = string
}

variable "break_glass_role_name" {
  description = "Name of the customer-side break-glass role. Tell LangChain if you change it."
  type        = string
  default     = "LangSmithBYOCBreakGlass"

  validation {
    condition     = can(regex("^[\\w+=,.@-]{1,64}$", var.break_glass_role_name))
    error_message = "The role name must be 1-64 characters of letters, digits, and +=,.@_-."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional customer IAM permissions boundary applied to the provisioning and break-glass roles when they are created."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/[a-zA-Z0-9/+=,.@_-]+$", var.permissions_boundary_arn))
    error_message = "Supply an IAM policy ARN without wildcards."
  }
}

variable "allow_break_glass_access" {
  description = "Allow trusted LangSmith Identity Center users to assume the customer-side break-glass role."
  type        = bool
  default     = false
}

variable "break_glass_identitystore_user_ids" {
  description = "IAM Identity Center user IDs allowed to assume the customer-side break-glass role."
  type        = list(string)
  default     = []
}

variable "break_glass_source_identities" {
  description = "SourceIdentity values allowed when assuming the customer-side break-glass role."
  type        = list(string)
  default     = []
}

variable "langsmith_control_plane_account_id" {
  description = "AWS account ID of the LangSmith control plane."
  type        = string
  default     = "808407022534"
}

variable "langsmith_byoc_break_glass_principal_arn_patterns" {
  description = "IAM principal ARN patterns for LangSmith Identity Center BYOC break-glass sessions."
  type        = list(string)
  default = [
    "arn:aws:iam::808407022534:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_BYOCBreakGlass_442d99d086ecd3c8",
    "arn:aws:iam::808407022534:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_BYOCBreakGlass_442d99d086ecd3c8",
  ]
}

variable "allow_public_ingress" {
  description = "Not required. Grant the role permissions needed to expose the LangSmith data plane on the public internet."
  type        = bool
  default     = false
}

variable "allow_delete_permissions" {
  description = "Grant the role permissions needed to delete LangSmith-managed resources."
  type        = bool
  default     = false
}

variable "allow_vpc_creation_permissions" {
  description = "Grant permissions to create and manage the base VPC network. Disable when the customer supplies the VPC, subnets, routing, gateways, endpoints, and flow logs."
  type        = bool
  default     = true
}

variable "vpc_ids" {
  description = "VPC IDs in which Crossplane may create tagged workload security groups when base VPC creation permissions are disabled."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for vpc_id in var.vpc_ids : can(regex("^vpc-[0-9a-f]+$", vpc_id))])
    error_message = "Every vpc_ids entry must be a valid VPC ID."
  }
}

variable "allow_iam_management_permissions" {
  description = "Grant IAM creation, mutation, and deletion permissions. Disable when the customer supplies roles, policies, instance profiles, and service-linked roles; IAM reads, scoped PassRole, and policy simulation remain available."
  type        = bool
  default     = true
}

variable "byoiam_role_arns" {
  description = "Exact ARNs of customer-managed BYOIAM roles whose names do not match the default *-smith-* patterns. The role may read and pass these roles; pass the byoiam module's role_arns output values."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.byoiam_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[\\w+=,.@-]{1,64}$", arn))])
    error_message = "Each entry must be an IAM role ARN with path / and no wildcards."
  }
}

variable "byoiam_instance_profile_name" {
  description = "Name of the customer-managed Karpenter instance profile, in this account with path /, when it does not match *-smith-karpenter-node-profile. Pass the byoiam module's karpenter_instance_profile_name output."
  type        = string
  default     = null

  validation {
    condition     = var.byoiam_instance_profile_name == null ? true : can(regex("^[\\w+=,.@-]{1,128}$", var.byoiam_instance_profile_name))
    error_message = "The instance profile name must be 1-128 characters of letters, digits, and +=,.@_-."
  }
}

variable "allow_self_hosted_migration_permissions" {
  description = "Self-hosted to BYOC migration only. Grants permissions needed for the migration. Enable for the duration of a self-hosted to BYOC migration."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to the IAM role"
  type        = map(string)
  default     = {}
}
