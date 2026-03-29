#------------------------------------------------------------------------------
# Infrastructure outputs — auto-populated by `make init-app` or set manually.
#
# Resolution: explicit variable → pull-infra-outputs.sh → error
# All default to null. Anything still null at plan time fails with a
# precondition error telling you exactly what's missing.
#------------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = null
}

variable "resource_group_name" {
  description = "Azure resource group containing the AKS cluster and Key Vault"
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = null
}

variable "keyvault_name" {
  description = "Azure Key Vault name holding LangSmith secrets"
  type        = string
  default     = null
}

variable "storage_account_name" {
  description = "Azure Blob Storage account name for LangSmith traces"
  type        = string
  default     = null
}

variable "storage_container_name" {
  description = "Blob container name within the storage account"
  type        = string
  default     = null
}

variable "workload_identity_client_id" {
  description = "Client ID of the managed identity for Workload Identity (blob storage access)"
  type        = string
  default     = null
}

variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "TLS certificate source: none, letsencrypt, dns01, existing"
  type        = string
  default     = null
}

variable "ingress_controller" {
  description = "Ingress controller type: nginx, istio, istio-addon, agic, envoy-gateway, none"
  type        = string
  default     = null
}

variable "dns_label" {
  description = "Azure Public IP DNS label — results in <label>.<region>.cloudapp.azure.com. Works with any ingress controller. Empty = not used."
  type        = string
  default     = null
}


#------------------------------------------------------------------------------
# App configuration — set these in terraform.tfvars
#------------------------------------------------------------------------------

variable "hostname" {
  description = "LangSmith hostname. Auto-detected from dns_label or Front Door if not set."
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
  description = "Force a Helm upgrade on every apply, even when values haven't changed."
  type        = bool
  default     = false
}

variable "helm_values_path" {
  description = "Path to directory containing Helm values YAML files. Defaults to helm/values/ (populated by make init-values)."
  type        = string
  default     = null
}

#------------------------------------------------------------------------------
# Sizing
#------------------------------------------------------------------------------

variable "sizing" {
  description = "Resource sizing profile: production, production-large, dev, or none (chart defaults). See SIZING.md."
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
  description = "PostgreSQL deployment type: 'external' (Azure DB for PostgreSQL) or 'in-cluster' (Helm)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be one of: external, in-cluster."
  }
}

variable "redis_source" {
  description = "Redis deployment type: 'external' (Azure Cache for Redis) or 'in-cluster' (Helm)"
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
  description = "Enable Polly AI eval/monitoring (requires enable_agent_deploys = true)"
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
