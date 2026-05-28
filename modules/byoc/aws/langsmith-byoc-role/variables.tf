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

variable "control_plane_role_arn" {
  description = "ARN of the trusted control plane role."
  type        = string
}

variable "langsmith_break_glass_role_arn" {
  description = "ARN of the LangChain control-plane break-glass IAM role."
  type        = string
}

variable "allow_public_ingress" {
  description = "Not required. Grant the role permissions needed to expose the LangSmith data plane on the public internet."
  type        = bool
  default     = false
}
