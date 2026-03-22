#------------------------------------------------------------------------------
# Infrastructure outputs — auto-populated by `make init-app` or set manually.
#
# Resolution: explicit variable → pull-infra-outputs.sh → error
# All default to null. Anything still null at plan time fails with a
# precondition error telling you exactly what's missing.
#------------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = null
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = null
}

variable "environment" {
  description = "Environment name used by the infra module"
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Name prefix used by the infra module"
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = null
}

variable "workload_identity_annotation" {
  description = "GCP service account email for iam.gke.io/gcp-service-account annotation (null when IAM module disabled)"
  type        = string
  default     = null
}

variable "bucket_name" {
  description = "GCS bucket name for blob storage"
  type        = string
  default     = null
}

variable "ingress_ip" {
  description = "Envoy Gateway external IP address"
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "TLS certificate source: none, letsencrypt, or existing"
  type        = string
  default     = null
}

variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = null
}

variable "postgres_source" {
  description = "PostgreSQL deployment type: external (Cloud SQL) or in-cluster"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be one of: external, in-cluster."
  }
}

variable "redis_source" {
  description = "Redis deployment type: external (Memorystore) or in-cluster"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["redis_source", "in-cluster"], var.redis_source) || contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be one of: external, in-cluster."
  }
}

#------------------------------------------------------------------------------
# App configuration — set these in terraform.tfvars
#------------------------------------------------------------------------------

variable "hostname" {
  description = "LangSmith hostname. Defaults to ingress_ip if not set (for IP-only deployments without DNS)."
  type        = string
  default     = null
}

variable "admin_email" {
  description = "Initial org admin email address"
  type        = string
  default     = "admin@example.com"
}

variable "release_name" {
  description = "Helm release name"
  type        = string
  default     = "langsmith"
}

variable "chart_version" {
  description = "LangSmith Helm chart version. Empty string = latest."
  type        = string
  default     = ""
}

variable "helm_timeout" {
  description = "Helm install/upgrade timeout in seconds"
  type        = number
  default     = 1200
}

variable "helm_force_update" {
  description = "Force a Helm upgrade on every apply, even when values haven't changed. Useful during initial bring-up; disable for steady-state."
  type        = bool
  default     = false
}

variable "helm_values_path" {
  description = "Path to directory containing Helm values YAML files. Defaults to helm/values/ (populated by make init-values). Override for custom values."
  type        = string
  default     = null
}

#------------------------------------------------------------------------------
# Sizing
#------------------------------------------------------------------------------

variable "sizing" {
  description = "Resource sizing profile: production (~20 users, ~100 traces/sec), production-large (~50 users, ~1000 traces/sec), dev (single-replica, minimal resources), minimum (absolute floor, not for production), or none (chart defaults)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "production-large", "dev", "minimum", "none"], var.sizing)
    error_message = "sizing must be one of: production, production-large, dev, minimum, none."
  }
}

#------------------------------------------------------------------------------
# Feature toggles
#------------------------------------------------------------------------------

variable "enable_agent_deploys" {
  description = "Enable the Deployments feature (LangGraph Platform)"
  type        = bool
  default     = false
}

variable "enable_agent_builder" {
  description = "Enable Agent Builder (requires enable_agent_deploys = true)"
  type        = bool
  default     = false
}

variable "enable_insights" {
  description = "Enable Insights (requires ClickHouse)"
  type        = bool
  default     = false
}

variable "enable_polly" {
  description = "Enable Polly AI eval/monitoring (requires enable_agent_deploys = true)"
  type        = bool
  default     = false
}

variable "enable_usage_telemetry" {
  description = "Enable extended usage telemetry reporting (PHONE_HOME_USAGE_REPORTING_ENABLED)"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# ClickHouse (required when enable_insights = true)
#------------------------------------------------------------------------------

variable "clickhouse_host" {
  description = "ClickHouse hostname or endpoint"
  type        = string
  default     = ""
}

variable "clickhouse_port" {
  description = "ClickHouse native port (9440 for TLS, 9000 for non-TLS)"
  type        = number
  default     = 9440
}

variable "clickhouse_http_port" {
  description = "ClickHouse HTTP port (8443 for TLS, 8123 for non-TLS)"
  type        = number
  default     = 8443
}

variable "clickhouse_database" {
  description = "ClickHouse database name"
  type        = string
  default     = "default"
}

variable "clickhouse_username" {
  description = "ClickHouse username"
  type        = string
  default     = "default"
}

variable "clickhouse_password" {
  description = "ClickHouse password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "clickhouse_tls" {
  description = "Enable TLS for ClickHouse connection"
  type        = bool
  default     = true
}
