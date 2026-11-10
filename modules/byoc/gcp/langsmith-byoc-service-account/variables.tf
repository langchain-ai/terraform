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
  description = "Prefix of the custom role IDs the module creates in the project (Provisioner, ProjectIamGranter, ServiceAccountUser, ServiceAccountIamManager, ClusterConnect, Named<kind> roles such as NamedCloudSql and NamedNetworks, and with byo_iam PostgresSetup)."
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

variable "cluster_tag_value" {
  description = "Value of the managed_by tag on the data plane GKE clusters. The LangSmith control plane administers only clusters with it. Keep the default unless LangChain gives you another value."
  type        = string
  default     = "langsmith"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,61}[a-zA-Z0-9])?$", var.cluster_tag_value))
    error_message = "cluster_tag_value must be 1 to 63 letters, digits, periods, underscores or hyphens, starting and ending with a letter or digit."
  }
}

variable "cluster_tag_key" {
  description = "ID (tagKeys/<number>) of the project's managed_by tag key, when it already exists: created by another copy of this module, or by you. Unset, the module creates the key."
  type        = string
  default     = null

  validation {
    condition     = var.cluster_tag_key == null || can(regex("^tagKeys/[0-9]+$", var.cluster_tag_key))
    error_message = "cluster_tag_key must be a tag key ID such as tagKeys/123456789."
  }
}
