# Variables for LangSmith GKE Terraform Configuration

#------------------------------------------------------------------------------
# Project Configuration
#------------------------------------------------------------------------------
variable "project_id" {
  description = "GCP Project ID where resources will be created"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Project ID must be 6-30 characters, start with a letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-west2"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]$", var.region))
    error_message = "Region must be a valid GCP region (e.g., us-west2, europe-west1)."
  }
}

variable "zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "us-west2-a"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone (e.g., us-west2-a)."
  }
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod", "test", "uat"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, test, uat."
  }
}

#------------------------------------------------------------------------------
# Naming Configuration (IMPORTANT: Prevents resource collisions)
#------------------------------------------------------------------------------
variable "name_prefix" {
  description = "Prefix for all resource names to avoid collisions (e.g., 'mycompany', 'team1'). Use lowercase letters, numbers, and hyphens only."
  type        = string
  default     = "ls" # Short for LangSmith

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,10}$", var.name_prefix))
    error_message = "Name prefix must be 1-11 characters, start with a letter, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "unique_suffix" {
  description = "Add a unique random suffix to resource names (recommended for multi-tenant projects)"
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Networking Configuration
#------------------------------------------------------------------------------
variable "use_private_networking" {
  description = "Use private IPs for Redis (requires servicenetworking.networksAdmin role). Cloud SQL always uses private IP. When false, Redis is deployed in-cluster via Helm."
  type        = bool
  default     = true
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet (must not overlap with existing ranges)"
  type        = string
  default     = "10.0.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "Subnet CIDR must be a valid CIDR notation."
  }
}

variable "pods_cidr" {
  description = "CIDR range for GKE pods (must not overlap with subnet or services)"
  type        = string
  default     = "10.4.0.0/14"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "Pods CIDR must be a valid CIDR notation."
  }
}

variable "services_cidr" {
  description = "CIDR range for GKE services (must not overlap with subnet or pods)"
  type        = string
  default     = "10.8.0.0/20"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "Services CIDR must be a valid CIDR notation."
  }
}

#------------------------------------------------------------------------------
# GKE Configuration
#------------------------------------------------------------------------------
variable "gke_use_autopilot" {
  description = "Use GKE Autopilot mode (recommended for simplicity, managed node pools)"
  type        = bool
  default     = false
}

variable "gke_node_count" {
  description = "Initial number of nodes per zone (Standard mode only)"
  type        = number
  default     = 2

  validation {
    condition     = var.gke_node_count >= 1 && var.gke_node_count <= 100
    error_message = "Node count must be between 1 and 100."
  }
}

variable "gke_min_nodes" {
  description = "Minimum number of nodes per zone for autoscaling"
  type        = number
  default     = 2

  validation {
    condition     = var.gke_min_nodes >= 1
    error_message = "Minimum nodes must be at least 1."
  }
}

variable "gke_max_nodes" {
  description = "Maximum number of nodes per zone for autoscaling"
  type        = number
  default     = 10

  validation {
    condition     = var.gke_max_nodes >= 1 && var.gke_max_nodes <= 1000
    error_message = "Maximum nodes must be between 1 and 1000."
  }
}

variable "gke_machine_type" {
  description = "Machine type for GKE nodes (e.g., e2-standard-4, n2-standard-8)"
  type        = string
  default     = "e2-standard-4"
}

variable "gke_disk_size" {
  description = "Disk size in GB for GKE nodes"
  type        = number
  default     = 100

  validation {
    condition     = var.gke_disk_size >= 30 && var.gke_disk_size <= 65536
    error_message = "Disk size must be between 30 and 65536 GB."
  }
}

variable "gke_release_channel" {
  description = "GKE release channel: RAPID, REGULAR, or STABLE"
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.gke_release_channel)
    error_message = "Release channel must be RAPID, REGULAR, or STABLE."
  }
}

variable "gke_deletion_protection" {
  description = "Enable deletion protection for the GKE cluster (recommended for production)"
  type        = bool
  default     = true
}

variable "gke_network_policy_provider" {
  description = "GKE network policy provider: CALICO (legacy) or DATA_PLANE_V2 (Cilium-based, recommended). Note: Autopilot clusters always use Dataplane V2."
  type        = string
  default     = "DATA_PLANE_V2"

  validation {
    condition     = contains(["CALICO", "DATA_PLANE_V2"], var.gke_network_policy_provider)
    error_message = "Network policy provider must be CALICO or DATA_PLANE_V2."
  }
}

#------------------------------------------------------------------------------
# Cloud SQL (PostgreSQL) Configuration
#------------------------------------------------------------------------------
variable "postgres_version" {
  description = "PostgreSQL version"
  type        = string
  default     = "POSTGRES_15"

  validation {
    condition     = can(regex("^POSTGRES_[0-9]+$", var.postgres_version))
    error_message = "PostgreSQL version must be in format POSTGRES_XX."
  }
}

variable "postgres_tier" {
  description = "Cloud SQL instance tier (e.g., db-f1-micro, db-custom-2-8192)"
  type        = string
  default     = "db-custom-2-8192"
}

variable "postgres_disk_size" {
  description = "Disk size in GB for Cloud SQL"
  type        = number
  default     = 50

  validation {
    condition     = var.postgres_disk_size >= 10 && var.postgres_disk_size <= 65536
    error_message = "Disk size must be between 10 and 65536 GB."
  }
}

variable "postgres_high_availability" {
  description = "Enable high availability for Cloud SQL (REGIONAL)"
  type        = bool
  default     = true
}

variable "postgres_deletion_protection" {
  description = "Enable deletion protection for Cloud SQL (recommended for production)"
  type        = bool
  default     = true
}

variable "postgres_database_flags" {
  description = "List of database flags to set on the Cloud SQL instance"
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    {
      name  = "max_connections"
      value = "500"
    },
    {
      name  = "log_checkpoints"
      value = "on"
    },
    {
      name  = "log_connections"
      value = "on"
    },
    {
      name  = "log_disconnections"
      value = "on"
    }
  ]
}

variable "postgres_password" {
  description = "PostgreSQL database password (sensitive - use TF_VAR_postgres_password env var)"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 8
    error_message = "Password must be at least 8 characters long."
  }
}

#------------------------------------------------------------------------------
# Redis (Memorystore) Configuration
#------------------------------------------------------------------------------
variable "redis_version" {
  description = "Redis version"
  type        = string
  default     = "REDIS_7_0"

  validation {
    condition     = can(regex("^REDIS_[0-9]+_[0-9]+$", var.redis_version))
    error_message = "Redis version must be in format REDIS_X_Y."
  }
}

variable "redis_memory_size" {
  description = "Redis memory size in GB"
  type        = number
  default     = 5

  validation {
    condition     = var.redis_memory_size >= 1 && var.redis_memory_size <= 300
    error_message = "Redis memory size must be between 1 and 300 GB."
  }
}

variable "redis_high_availability" {
  description = "Enable high availability for Redis (Standard HA tier)"
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Cloud Storage Configuration
#------------------------------------------------------------------------------
variable "storage_ttl_short_days" {
  description = "Short term TTL in days for ttl_s/ prefix (default: 14 days per LangSmith docs)"
  type        = number
  default     = 14

  validation {
    condition     = var.storage_ttl_short_days > 0 && var.storage_ttl_short_days <= 3650
    error_message = "TTL short days must be between 1 and 3650 (10 years)."
  }
}

variable "storage_ttl_long_days" {
  description = "Long term TTL in days for ttl_l/ prefix (default: 400 days per LangSmith docs)"
  type        = number
  default     = 400

  validation {
    condition     = var.storage_ttl_long_days > 0 && var.storage_ttl_long_days <= 3650
    error_message = "TTL long days must be between 1 and 3650 (10 years)."
  }
}

variable "storage_force_destroy" {
  description = "Allow bucket deletion even with objects inside (use with caution)"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# LangSmith Configuration
#------------------------------------------------------------------------------
variable "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  type        = string
  default     = "langsmith"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.langsmith_namespace))
    error_message = "Namespace must be a valid Kubernetes namespace name."
  }
}

variable "langsmith_domain" {
  description = "Domain name for LangSmith (e.g., langsmith.example.com)"
  type        = string
  default     = "langsmith.example.com"
}

variable "langsmith_license_key" {
  description = "LangSmith license key (sensitive - use TF_VAR_langsmith_license_key env var)"
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# Ingress Configuration
#------------------------------------------------------------------------------
variable "install_ingress" {
  description = "Whether to install ingress controller via Terraform"
  type        = bool
  default     = true
}

variable "ingress_type" {
  description = "Type of ingress to install: 'nginx' or 'envoy'"
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "envoy"], var.ingress_type)
    error_message = "Ingress type must be 'nginx' or 'envoy'."
  }
}

#------------------------------------------------------------------------------
# ClickHouse Configuration
# Reference: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse
#------------------------------------------------------------------------------
variable "clickhouse_source" {
  description = "ClickHouse deployment type: 'in-cluster' (default, deployed via Helm), 'langsmith-managed' (managed by LangChain), or 'external' (self-hosted)"
  type        = string
  default     = "in-cluster"

  validation {
    condition     = contains(["in-cluster", "langsmith-managed", "external"], var.clickhouse_source)
    error_message = "clickhouse_source must be one of: in-cluster, langsmith-managed, external"
  }
}

variable "clickhouse_host" {
  description = "ClickHouse host (required for 'langsmith-managed' or 'external')"
  type        = string
  default     = ""
}

variable "clickhouse_port" {
  description = "ClickHouse native port (default: 9440 for TLS, 9000 for non-TLS)"
  type        = number
  default     = 9440
}

variable "clickhouse_http_port" {
  description = "ClickHouse HTTP port (default: 8443 for TLS, 8123 for non-TLS)"
  type        = number
  default     = 8443
}

variable "clickhouse_user" {
  description = "ClickHouse username (required for 'langsmith-managed' or 'external')"
  type        = string
  default     = "default"
}

variable "clickhouse_password" {
  description = "ClickHouse password (required for 'langsmith-managed' or 'external')"
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
  description = "Enable TLS for ClickHouse connections"
  type        = bool
  default     = true
}

variable "clickhouse_ca_cert" {
  description = "ClickHouse CA certificate (PEM format) for TLS verification. Leave empty to use system CAs."
  type        = string
  default     = ""
  sensitive   = true
}

#------------------------------------------------------------------------------
# LangSmith Deployment Configuration
# Reference: https://docs.langchain.com/langsmith/deploy-self-hosted-full-platform
#------------------------------------------------------------------------------
variable "enable_langsmith_deployment" {
  description = "Enable LangSmith Deployment feature (deploy agents/apps from UI). Installs KEDA."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# TLS / Certificate Configuration
#------------------------------------------------------------------------------
variable "tls_certificate_source" {
  description = "Source of TLS certificates: 'none' (no TLS), 'letsencrypt' (auto via cert-manager), 'existing' (provide your own certs)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "letsencrypt", "existing"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be one of: none, letsencrypt, existing"
  }
}

variable "install_cert_manager" {
  description = "Install cert-manager for automatic TLS certificates with Let's Encrypt"
  type        = bool
  default     = false
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt notifications (required if tls_certificate_source is 'letsencrypt')"
  type        = string
  default     = ""
}

variable "tls_certificate_crt" {
  description = "TLS certificate in PEM format (required if tls_certificate_source is 'existing'). Use file() to load from a file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_certificate_key" {
  description = "TLS private key in PEM format (required if tls_certificate_source is 'existing'). Use file() to load from a file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_secret_name" {
  description = "Name for the TLS secret in Kubernetes"
  type        = string
  default     = "langsmith-tls"
}

#------------------------------------------------------------------------------
# Tags/Labels (Applied to all resources)
#------------------------------------------------------------------------------
variable "labels" {
  description = "Custom labels to apply to all resources (in addition to default labels)"
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.labels : can(regex("^[a-z][a-z0-9_-]{0,62}$", k))])
    error_message = "Label keys must be valid GCP label keys."
  }
}

variable "owner" {
  description = "Owner of the resources (team or individual) - used in labels"
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost center for billing attribution - used in labels"
  type        = string
  default     = ""
}

