# Variables for K8s Bootstrap Module

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

#------------------------------------------------------------------------------
# Namespace Configuration
#------------------------------------------------------------------------------
variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"
}

variable "service_account_email" {
  description = "GCP service account email for Workload Identity"
  type        = string
}

#------------------------------------------------------------------------------
# Database Credentials
#------------------------------------------------------------------------------
variable "use_external_postgres" {
  description = "Whether using external PostgreSQL (Cloud SQL). When false, skips PostgreSQL secret creation."
  type        = bool
  default     = true
}

variable "postgres_connection_url" {
  description = "PostgreSQL connection URL (format: postgresql://user:password@host:port/database) - only used when use_external_postgres = true"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# Redis Credentials
#------------------------------------------------------------------------------
variable "use_managed_redis" {
  description = "Whether using managed Redis (Memorystore). When false, skips Redis secret creation."
  type        = bool
  default     = true
}

variable "redis_connection_url" {
  description = "Redis connection URL (format: redis://host:port) - only used when use_managed_redis = true"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# License
#------------------------------------------------------------------------------
variable "langsmith_license_key" {
  description = "LangSmith license key"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# KEDA Configuration
#------------------------------------------------------------------------------
variable "install_keda" {
  description = "Install KEDA for LangSmith Deployment feature (autoscaling agent deployments)"
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# TLS / Certificate Configuration
#------------------------------------------------------------------------------
variable "tls_certificate_source" {
  description = "Source of TLS certificates: 'none' (no TLS), 'letsencrypt' (auto via cert-manager), 'existing' (provide your own)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "letsencrypt", "existing"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be one of: none, letsencrypt, existing"
  }
}

variable "install_cert_manager" {
  description = "Install cert-manager for automatic TLS certificate management with Let's Encrypt"
  type        = bool
  default     = false
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt certificate notifications (required if tls_certificate_source is 'letsencrypt')"
  type        = string
  default     = ""
}

variable "gateway_name" {
  description = "Name of the Gateway resource for cert-manager HTTP01 challenges (Envoy Gateway)"
  type        = string
  default     = "langsmith-gateway"
}

#------------------------------------------------------------------------------
# Existing TLS Certificate (when tls_certificate_source = "existing")
#------------------------------------------------------------------------------
variable "tls_certificate_crt" {
  description = "TLS certificate (PEM format). Can be base64 encoded or raw PEM content."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_certificate_key" {
  description = "TLS private key (PEM format). Can be base64 encoded or raw PEM content."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_secret_name" {
  description = "Name for the TLS secret in Kubernetes"
  type        = string
  default     = "langsmith-tls"
}

variable "langsmith_domain" {
  description = "Domain name for LangSmith (used for TLS secret annotations)"
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# ClickHouse Configuration
#------------------------------------------------------------------------------
variable "clickhouse_source" {
  description = "ClickHouse deployment type: 'in-cluster', 'langsmith-managed', or 'external'"
  type        = string
  default     = "in-cluster"
}

variable "clickhouse_host" {
  description = "ClickHouse host (for external/managed)"
  type        = string
  default     = ""
}

variable "clickhouse_port" {
  description = "ClickHouse native port"
  type        = number
  default     = 9440
}

variable "clickhouse_http_port" {
  description = "ClickHouse HTTP port"
  type        = number
  default     = 8443
}

variable "clickhouse_user" {
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

variable "clickhouse_database" {
  description = "ClickHouse database name"
  type        = string
  default     = "default"
}

variable "clickhouse_tls" {
  description = "Enable TLS for ClickHouse"
  type        = bool
  default     = true
}

variable "clickhouse_ca_cert" {
  description = "ClickHouse CA certificate (PEM)"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
