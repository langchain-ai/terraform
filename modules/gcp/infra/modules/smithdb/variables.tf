# smithdb: cloud dependencies for the in-chart SmithDB component of self-hosted
# LangSmith (chart 0.16+). Provisions the dedicated metastore Cloud SQL instance,
# the object-store GCS bucket, and the Workload Identity service account the
# SmithDB pods use for bucket access. The Kubernetes secrets and node pools that
# consume these are wired in the infra root; the Helm release itself is deployed
# in Pass 2 (helm/ or app/).

variable "name" {
  type        = string
  description = "Base name for SmithDB resources, e.g. {name_prefix}-{environment}-smithdb."
}

variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region. The object-store bucket is single-region here so segment reads stay local to the cluster."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to all SmithDB resources."
  default     = {}
}

#------------------------------------------------------------------------------
# Networking / GKE references
#------------------------------------------------------------------------------
variable "network_id" {
  type        = string
  description = "VPC network ID. The metastore is reachable only on its private IP inside this VPC."
}

# Cloud SQL private IP requires the VPC peering range to exist first. The
# ordering is enforced by depends_on at the module call site; this input keeps
# the requirement visible and matches the postgres module's signature.
variable "private_network_connection" {
  type        = string
  description = "Private service connection ID from the networking module."
  default     = ""
}

variable "metastore_instance_name" {
  type        = string
  description = "Cloud SQL instance name for the metastore. Empty derives {name}-metastore. Cloud SQL blocks name reuse for days after a delete, so pass a suffixed name for disposable stacks."
  default     = ""
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace LangSmith/SmithDB run in. Scopes the Workload Identity binding."
}

variable "release_name" {
  type        = string
  description = "Helm release name. The SmithDB service account is <release_name>-langsmith-smithdb (see the fullname note in main.tf)."
  default     = "langsmith"
}

#------------------------------------------------------------------------------
# Metastore (Cloud SQL Postgres) — a dedicated, empty database per the SmithDB
# supporting-infrastructure requirements. Never point this at the LangSmith
# operational Postgres. Set metastore_source = external to bring your own
# (AlloyDB via the Auth Proxy, or any reachable Postgres 17+).
#------------------------------------------------------------------------------
variable "metastore_source" {
  type        = string
  description = "SmithDB metastore Postgres: 'create' (dedicated Cloud SQL instance, default) or 'external' (bring-your-own)."
  default     = "create"

  validation {
    condition     = contains(["create", "external"], var.metastore_source)
    error_message = "metastore_source must be 'create' or 'external'."
  }
}

variable "metastore_database_version" {
  type        = string
  description = "Cloud SQL Postgres version for the SmithDB metastore. SmithDB requires Postgres 17 or later."
  default     = "POSTGRES_18"

  validation {
    condition     = can(regex("^POSTGRES_(1[7-9]|[2-9][0-9])$", var.metastore_database_version))
    error_message = "SmithDB requires Postgres 17 or later, e.g. POSTGRES_17 or POSTGRES_18."
  }
}

variable "metastore_tier" {
  type        = string
  description = "Cloud SQL machine tier for the SmithDB metastore."
  default     = "db-custom-2-8192"
}

variable "metastore_disk_size" {
  type        = number
  description = "Disk size in GB for the SmithDB metastore. Autoresize is enabled, so this is a floor."
  default     = 50
}

variable "metastore_high_availability" {
  type        = bool
  description = "Run the SmithDB metastore as a REGIONAL (HA) Cloud SQL instance."
  default     = false
}

variable "metastore_deletion_protection" {
  type        = bool
  description = "Prevent deletion of the SmithDB metastore instance, both from Terraform and from the Cloud SQL API. Set false for dev/test environments that are destroyed and rebuilt; a destroy fails while it is true."
  default     = true
}

variable "metastore_ssl_mode" {
  type        = string
  description = "Cloud SQL SSL enforcement for the metastore. ENCRYPTED_ONLY requires TLS on every connection."
  default     = "ENCRYPTED_ONLY"

  validation {
    condition     = contains(["ALLOW_UNENCRYPTED_AND_ENCRYPTED", "ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"], var.metastore_ssl_mode)
    error_message = "metastore_ssl_mode must be one of ALLOW_UNENCRYPTED_AND_ENCRYPTED, ENCRYPTED_ONLY, TRUSTED_CLIENT_CERTIFICATE_REQUIRED."
  }
}

variable "metastore_master_username" {
  type        = string
  description = "Master username for the SmithDB metastore."
  default     = "smithdb"
}

variable "metastore_master_password" {
  type        = string
  description = "Master password for the SmithDB metastore. Leave null to auto-generate (metastore_source = create)."
  default     = null
  sensitive   = true
}

# External metastore fields (used when metastore_source = external).
variable "external_metastore_host" {
  type        = string
  description = "Hostname of an existing Postgres instance for the SmithDB metastore. Use 127.0.0.1 when fronting AlloyDB with the Auth Proxy sidecar."
  default     = null
}

variable "external_metastore_port" {
  type        = number
  description = "Port of the existing SmithDB metastore Postgres instance."
  default     = 5432
}

variable "external_metastore_database" {
  type        = string
  description = "Database name on the existing SmithDB metastore Postgres instance."
  default     = "smithdb"
}

variable "external_metastore_username" {
  type        = string
  description = "Username for the existing SmithDB metastore Postgres instance."
  default     = null
}

variable "external_metastore_password" {
  type        = string
  description = "Password for the existing SmithDB metastore Postgres instance. Empty when using AlloyDB IAM database authentication."
  default     = null
  sensitive   = true
}

#------------------------------------------------------------------------------
# Object store (GCS)
#------------------------------------------------------------------------------
variable "bucket_name" {
  type        = string
  description = "Name of the SmithDB object-store bucket. Must be globally unique."
}

variable "bucket_kms_key" {
  type        = string
  description = "Cloud KMS key for CMEK on the object-store bucket. Empty uses Google-managed encryption."
  default     = ""
}

variable "bucket_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete a non-empty object-store bucket on destroy. Set true only for test stacks."
  default     = false
}

#------------------------------------------------------------------------------
# Workload Identity
#------------------------------------------------------------------------------
variable "service_account_email" {
  type        = string
  description = "Existing GCP service account email for the SmithDB pods. Leave null to have this module create a dedicated one."
  default     = null
}
