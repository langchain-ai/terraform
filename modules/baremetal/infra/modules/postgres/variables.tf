#------------------------------------------------------------------------------
# Inputs for one Postgres instance.
# Covers namespace, image, database and user, storage, resources, connection
# limit, which namespaces may connect, and extra databases for optional
# features.
# Set by the root module (main.tf); not meant to be called on its own.
#------------------------------------------------------------------------------

variable "namespace" {
  type        = string
  description = "Namespace created for this instance (one Postgres per namespace)."
}

variable "image" {
  type        = string
  description = "Official Postgres image, exact tag (18+: data lives under /var/lib/postgresql/<major>/docker)."
}

variable "database" {
  type        = string
  description = "Database created on first start."
}

variable "username" {
  type        = string
  description = "Owner role created on first start."
}

variable "storage_size" {
  type        = string
  description = "PVC size (local-path doesn't enforce it; it documents intent and feeds the budget)."
}

variable "storage_class" {
  type        = string
  description = "StorageClass for the data volume. Use the Retain class so a deleted PVC never deletes the data."
}

variable "resources" {
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  description = "Container requests and limits (from the root budget)."
}

variable "memory_limit_mi" {
  type        = number
  description = "Memory limit in MiB, used to size shared_buffers (25%) and effective_cache_size (50%) so Postgres stays under the limit."
}

variable "max_connections" {
  type        = number
  default     = 200
  description = "Postgres max_connections. Each connection is a backend process using a few MiB."
}

variable "allowed_namespaces" {
  type        = list(string)
  description = "Namespaces allowed to connect on 5432 (NetworkPolicy). The instance's own namespace is always allowed."
}

variable "datastore_label" {
  type        = map(string)
  description = "Label shared by every datastore pod; a preferred anti-affinity on it spreads datastores across nodes."
}

variable "extra_databases" {
  type        = list(string)
  default     = []
  description = "Additional databases on this instance, owned by the same role (e.g. langsmith_polly). Created idempotently by a Job; never dropped."

  validation {
    condition     = alltrue([for d in var.extra_databases : can(regex("^[a-z_][a-z0-9_]*$", d))])
    error_message = "extra_databases names must match ^[a-z_][a-z0-9_]*$."
  }
}
