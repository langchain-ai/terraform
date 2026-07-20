variable "role_name" {
  description = "Name of the IAM role to be created in the target account."
  type        = string
}

variable "external_id" {
  description = "External ID required to assume this role."
  type        = string
}

variable "tags" {
  description = "Tags to apply to the IAM role"
  type        = map(string)
  default     = {}
}

variable "control_plane_reconcile_role_arn" {
  description = "ARN of the LangChain control plane reconciliation role."
  type        = string
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

variable "allow_break_glass_access" {
  description = "Allow trusted LangSmith Identity Center users to assume the customer-side break-glass role."
  type        = bool
  default     = false
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
