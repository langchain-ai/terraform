variable "project_id" {
  description = "The GCP project that hosts the LangSmith data planes."
  type        = string
}

variable "service_account_id" {
  description = "Account ID of the provisioner service account to create in the project."
  type        = string
  default     = "langsmith-byoc-provisioner"
}

variable "crossplane_service_account" {
  description = "Email of the LangSmith control plane Crossplane service account that impersonates the provisioner. Provided by LangChain."
  type        = string
}

variable "external_id" {
  description = "External ID copied from Settings > Data Planes in the LangSmith UI. The module writes it as the description of the provisioner service account. LangSmith reads it to verify that you own the provisioner."
  type        = string

  validation {
    condition     = length(trimspace(var.external_id)) > 0
    error_message = "external_id must not be empty. Copy it from Settings > Data Planes in the LangSmith UI."
  }

  validation {
    condition     = length(var.external_id) <= 256
    error_message = "external_id must be at most 256 characters, the limit of a service account description."
  }
}

variable "enable_apis" {
  description = "Enable the GCP APIs that data planes use. Disable when the project's APIs are managed elsewhere."
  type        = bool
  default     = true
}

variable "custom_role_id_prefix" {
  description = "Prefix of the custom role IDs the module creates in the project (Provisioner, ProjectIamGranter, ServiceAccountUser, ServiceAccountIamManager)."
  type        = string
  default     = "langsmithByoc"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,40}$", var.custom_role_id_prefix))
    error_message = "custom_role_id_prefix must be 3 to 40 letters, digits, underscores or periods."
  }
}

variable "byo_iam" {
  description = "Bring your own IAM. The module then creates the data plane service accounts and their project role grants, and the provisioner gets no service account admin and no project IAM writes. Set it before you create data planes in the project."
  type        = bool
  default     = false
}

variable "deployment_observability" {
  description = "Let LangSmith turn on deployment observability: Monitoring charts and searchable log history for LangGraph deployments, kept in this project. Adds the Cloud Logging and Monitoring APIs, the provisioner's log bucket and sink permissions, and roles/logging.viewAccessor and roles/monitoring.viewer for the LangSmith app. Set it before LangSmith turns the feature on for a data plane, and keep it until LangSmith turns it off or deletes every such data plane. Not supported with byo_iam."
  type        = bool
  default     = false

  validation {
    condition     = !(var.deployment_observability && var.byo_iam)
    error_message = "deployment_observability is not supported with byo_iam."
  }
}
