#------------------------------------------------------------------------------
# Infrastructure outputs — auto-populated by `make init-app` or set manually.
#
# Resolution: explicit variable → pull-infra-outputs.sh → error
# All default to null. Anything still null at plan time fails with a
# precondition error telling you exactly what's missing.
#------------------------------------------------------------------------------

variable "region" {
  description = "AWS region"
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Name prefix used by the infra module (used for SSM path)"
  type        = string
  default     = null
}

variable "environment" {
  description = "Environment name used by the infra module (used for SSM path)"
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = null
}

variable "langsmith_irsa_role_arn" {
  description = "IAM role ARN for LangSmith pods (IRSA) — S3 access"
  type        = string
  default     = null
}

variable "bucket_name" {
  description = "S3 bucket name for blob storage"
  type        = string
  default     = null
}

variable "alb_arn" {
  description = "ARN of the pre-provisioned ALB"
  type        = string
  default     = null
}

variable "alb_scheme" {
  description = "ALB scheme: 'internet-facing' or 'internal'"
  type        = string
  default     = "internet-facing"
}

variable "alb_dns_name" {
  description = "ALB DNS hostname"
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "TLS certificate source: acm, letsencrypt, or none"
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate. Required when tls_certificate_source = acm."
  type        = string
  default     = null
}

variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = null
}

variable "langsmith_domain" {
  description = "Custom domain for LangSmith (e.g. langsmith.example.com). Auto-populated from infra outputs by make init-app. When set, used as config.hostname instead of the ALB DNS name."
  type        = string
  default     = null
}

#------------------------------------------------------------------------------
# App configuration — set these in terraform.tfvars
#------------------------------------------------------------------------------

variable "hostname" {
  description = "LangSmith hostname. Defaults to alb_dns_name if not set."
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

variable "eso_refresh_interval" {
  description = "How often ESO syncs secrets from SSM into the langsmith-config K8s Secret (e.g. 1h, 15m, 5m). Lower values help during debugging or secret rotation."
  type        = string
  default     = "1h"
}

variable "helm_values_path" {
  description = "Path to directory containing Helm values YAML files. Defaults to helm/values/ (populated by make init-values). Override for BYOI or custom values."
  type        = string
  default     = null
}

#------------------------------------------------------------------------------
# Sizing
#------------------------------------------------------------------------------

variable "sizing" {
  description = "Resource sizing profile: production (~20 users, ~100 traces/sec), production-large (~50 users, ~1000 traces/sec), dev (single-replica, minimal resources), or none (chart defaults). See https://docs.langchain.com/langsmith/self-host-scale"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "production-large", "dev", "none"], var.sizing)
    error_message = "sizing must be one of: production, production-large, dev, none"
  }
}

#------------------------------------------------------------------------------
# External services
#------------------------------------------------------------------------------

variable "postgres_source" {
  description = "PostgreSQL deployment type: 'external' (RDS, default) or 'in-cluster' (Helm)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be one of: external, in-cluster."
  }
}

variable "redis_source" {
  description = "Redis deployment type: 'external' (ElastiCache, default) or 'in-cluster' (Helm)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be one of: external, in-cluster."
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
  description = "Enable Insights (requires external ClickHouse)"
  type        = bool
  default     = false
}

variable "enable_polly" {
  description = "Enable Polly (AI-powered evaluation and monitoring). Requires enable_agent_deploys = true."
  type        = bool
  default     = false
}

variable "enable_usage_telemetry" {
  description = "Enable extended usage telemetry reporting (PHONE_HOME_USAGE_REPORTING_ENABLED)"
  type        = bool
  default     = false
}

variable "tls_enabled_for_deploys" {
  description = "Whether agent deployment endpoints use HTTPS. Auto-detected from tls_certificate_source if not set."
  type        = bool
  default     = null
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
  description = "ClickHouse HTTP port"
  type        = number
  default     = 8123
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
