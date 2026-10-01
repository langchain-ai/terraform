variable "langsmith_external_id" {
  description = "External ID copied from Settings > Data Planes in the LangSmith UI. The federated credential accepts only tokens for this LangSmith organization."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,64}$", var.langsmith_external_id))
    error_message = "langsmith_external_id must be the external ID from the LangSmith UI: 1 to 64 letters, digits, or hyphens."
  }
}

variable "control_plane_issuers" {
  description = "OIDC issuer URLs of the LangSmith control plane. Each issuer gets one federated credential. During a control plane migration, list the old and the new issuer."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_issuers) >= 1 && length(var.control_plane_issuers) <= 20
    error_message = "control_plane_issuers must have 1 to 20 issuers. Azure allows 20 federated credentials for each identity."
  }

  validation {
    condition     = alltrue([for issuer in var.control_plane_issuers : startswith(issuer, "https://")])
    error_message = "Each control plane issuer must be an https:// URL."
  }
}

variable "control_plane_subject" {
  description = "The service account of the LangSmith control plane that requests tokens for your organization."
  type        = string
  default     = "system:serviceaccount:crossplane-system:langsmith-byoc-azure"
}

variable "location" {
  description = "Azure region of the resource group that holds the managed identity, for example westus3."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group for the managed identity."
  type        = string
  default     = "langsmith-byoc-identity"
}

variable "identity_name" {
  description = "Name of the user-assigned managed identity that LangSmith signs in as."
  type        = string
  default     = "langsmith-byoc"
}

variable "tags" {
  description = "Tags to apply to the resource group and the managed identity."
  type        = map(string)
  default     = {}
}
