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
# Note: External PostgreSQL and Redis always use private connections (VPC peering)

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

variable "gke_node_service_account_email" {
  description = "Service account email to run standard-mode GKE nodes. Null keeps the GKE default; production deployments should pass a minimally privileged node service account. Pods use Workload Identity separately."
  type        = string
  default     = null
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

variable "gke_master_authorized_cidrs" {
  description = "External CIDRs permitted to reach the GKE master endpoint. Empty list (default) omits the master_authorized_networks_config block, leaving the master publicly reachable so Terraform-managed Helm/kubectl steps work from any apply host. Production deployments populate this with operator/CI egress CIDRs."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
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
  description = "Prevent deletion of the LangSmith Cloud SQL instance, both from Terraform and from the Cloud SQL API. Keep true for production. Set false for dev/test environments that are destroyed and rebuilt, and apply that change before running destroy."
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
    },
    {
      name  = "log_lock_waits"
      value = "on"
    },
    {
      name  = "log_temp_files"
      value = "0"
    }
  ]
}

variable "postgres_source" {
  description = "PostgreSQL deployment type: 'external' (default, Cloud SQL with private IP), or 'in-cluster' (deployed via Helm)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be one of: external, in-cluster"
  }
}

variable "postgres_password" {
  description = "PostgreSQL database password (required when postgres_source='external', sensitive - use TF_VAR_postgres_password env var)"
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.postgres_password == "" || length(var.postgres_password) >= 8
    error_message = "PostgreSQL password must be at least 8 characters long when provided."
  }
}

variable "postgres_ssl_mode" {
  description = "Cloud SQL SSL enforcement. ENCRYPTED_ONLY (default) requires TLS for every connection — LangSmith already speaks TLS. ALLOW_UNENCRYPTED_AND_ENCRYPTED accepts plaintext, only choose this if a legacy migration tool cannot be configured for SSL. TRUSTED_CLIENT_CERTIFICATE_REQUIRED additionally requires a client cert."
  type        = string
  default     = "ENCRYPTED_ONLY"

  validation {
    condition     = contains(["ALLOW_UNENCRYPTED_AND_ENCRYPTED", "ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"], var.postgres_ssl_mode)
    error_message = "postgres_ssl_mode must be one of ALLOW_UNENCRYPTED_AND_ENCRYPTED, ENCRYPTED_ONLY, TRUSTED_CLIENT_CERTIFICATE_REQUIRED."
  }
}

#------------------------------------------------------------------------------
# Redis Configuration
#------------------------------------------------------------------------------
variable "redis_source" {
  description = "Redis deployment type: 'external' (default, Memorystore with private IP), or 'in-cluster' (deployed via Helm)"
  type        = string
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be one of: external, in-cluster"
  }
}

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

variable "redis_prevent_destroy" {
  description = "Prevent accidental Terraform destroy of Redis instance"
  type        = bool
  default     = false
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

variable "langsmith_helm_chart_version" {
  description = "Optional LangSmith Helm chart version to pin in install/upgrade commands (e.g., 0.10.12). Empty = use latest chart."
  type        = string
  default     = ""
}

variable "langsmith_release_name" {
  description = "Helm release name for LangSmith. Must match what Pass 2 installs, because chart-created service account names derive from it (see the SmithDB Workload Identity binding)."
  type        = string
  default     = "langsmith"
}

#------------------------------------------------------------------------------
# Optional GCP modules
#------------------------------------------------------------------------------
variable "enable_gcp_iam_module" {
  description = "Enable GCP IAM module for Workload Identity and bucket IAM bindings."
  type        = bool
  default     = true
}

variable "enable_secret_manager_module" {
  description = "Enable Secret Manager module to store generated/bootstrap credentials."
  type        = bool
  default     = false
}

variable "enable_dns_module" {
  description = "Enable Cloud DNS + managed certificate module wiring."
  type        = bool
  default     = false
}

variable "dns_create_zone" {
  description = "Create a new Cloud DNS managed zone when enable_dns_module is true."
  type        = bool
  default     = true
}

variable "dns_existing_zone_name" {
  description = "Existing Cloud DNS zone name to use when dns_create_zone is false."
  type        = string
  default     = ""
}

variable "dns_create_certificate" {
  description = "Create a Google-managed SSL certificate when enable_dns_module is true."
  type        = bool
  default     = true
}

#------------------------------------------------------------------------------
# Ingress Configuration
#------------------------------------------------------------------------------
variable "install_ingress" {
  description = "Whether to install ingress controller via Terraform. Note: Gateway uses HTTPS only, so TLS must be configured (tls_certificate_source must be 'letsencrypt' or 'existing')."
  type        = bool
  default     = true
}

variable "ingress_type" {
  description = "Type of ingress to install: 'envoy' (implemented), 'istio' or 'other' (reserved for future implementation)"
  type        = string
  default     = "envoy"

  validation {
    condition     = contains(["envoy", "istio", "other"], var.ingress_type)
    error_message = "Ingress type must be 'envoy' (currently implemented), 'istio', or 'other' (reserved for future)."
  }
}

#------------------------------------------------------------------------------
# ClickHouse Configuration
# Reference: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse
#------------------------------------------------------------------------------
variable "clickhouse_source" {
  description = "ClickHouse deployment type: 'in-cluster' (dev/POC only), 'langsmith-managed' (recommended for production — see https://docs.langchain.com/langsmith/langsmith-managed-clickhouse), or 'external' (self-hosted)"
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

#------------------------------------------------------------------------------
# LangGraph Platform Features
# Boolean flags that control which product addons are active in Helm (Pass 2).
# init-values.sh and deploy.sh read these to select the right values overlays.
# Each addon requires the corresponding entitlement in your LangSmith license.
#------------------------------------------------------------------------------
variable "enable_deployments" {
  type        = bool
  description = "Enable LangGraph Platform Deployments (listener, operator, host-backend). Requires Deployments entitlement in license."
  default     = false
}

variable "enable_agent_builder" {
  type        = bool
  description = "Enable Agent Builder (visual agent building UI). Requires enable_deployments = true and Agent Builder entitlement in license."
  default     = false
}

variable "enable_insights" {
  type        = bool
  description = "Enable Insights (ClickHouse-backed analytics). Requires Insights entitlement in license."
  default     = false
}

#------------------------------------------------------------------------------
# LangGraph Platform Encryption Keys
# Fernet keys for optional feature modules. Generate once and never change.
# Set via TF_VAR_* environment variables — do not commit to terraform.tfvars.
# Required only when enabling the corresponding feature overlay in Helm.
#------------------------------------------------------------------------------
variable "langsmith_deployments_encryption_key" {
  type        = string
  description = "Fernet key for LangSmith Deployments. Generate once: python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'."
  sensitive   = true
  default     = ""
}

variable "langsmith_agent_builder_encryption_key" {
  type        = string
  description = "Fernet key for Agent Builder. Generate once and keep stable — changing requires re-encrypting all Agent Builder configs."
  sensitive   = true
  default     = ""
}

variable "langsmith_insights_encryption_key" {
  type        = string
  description = "Fernet key for Insights. Generate once — changing breaks existing Insights data. Shared by enable_insights and enable_standalone_insights."
  sensitive   = true
  default     = ""
}

variable "langsmith_polly_encryption_key" {
  type        = string
  description = "Fernet key for Polly. Generate once — changing breaks existing Polly data. Shared by enable_polly and enable_standalone_polly."
  sensitive   = true
  default     = ""
}

#------------------------------------------------------------------------------
# Helm Sizing Profile
#------------------------------------------------------------------------------
variable "sizing_profile" {
  type        = string
  description = "Helm sizing profile. See https://docs.langchain.com/langsmith/self-host-scale for workload patterns. 'production' (~20 users, ~100 traces/sec), 'production-large' (~50 users, ~1000 traces/sec), 'dev' (single-replica, minimal resources for dev/CI/demos), 'minimum' (absolute floor for cost parking/demos), or 'default' (chart defaults, no sizing file)."
  default     = "default"

  validation {
    condition     = contains(["production", "production-large", "dev", "minimum", "default"], var.sizing_profile)
    error_message = "sizing_profile must be one of: production, production-large, dev, minimum, default."
  }
}

#------------------------------------------------------------------------------
# Optional Feature Addons
#------------------------------------------------------------------------------
variable "enable_polly" {
  type        = bool
  description = "Enable Polly (AI-powered evaluation and monitoring). Requires enable_deployments = true and Polly entitlement in license."
  default     = false
}

variable "enable_fleet" {
  type        = bool
  description = "Enable Fleet standalone deployment (chart v0.15+). Does NOT require enable_deployments. Reuses langsmith_agent_builder_encryption_key when migrating from enable_agent_builder."
  default     = false
}

variable "enable_standalone_polly" {
  type        = bool
  description = "Enable Polly standalone deployment (chart v0.15+). Does NOT require enable_deployments. Reuses langsmith_polly_encryption_key."
  default     = false
}

variable "enable_standalone_insights" {
  type        = bool
  description = "Enable Insights standalone deployment (chart v0.15+). Does NOT require enable_deployments. Reuses langsmith_insights_encryption_key."
  default     = false
}

variable "enable_usage_telemetry" {
  type        = bool
  description = "Enable extended usage telemetry reporting (PHONE_HOME_USAGE_REPORTING_ENABLED)."
  default     = false
}

#------------------------------------------------------------------------------
# SmithDB (chart 0.16+, optional)
#
# SmithDB is the in-chart columnar store/query engine that runs alongside
# ClickHouse. Enabling it provisions a dedicated Cloud SQL metastore, its own GCS
# bucket, a Workload Identity service account, and two GKE node pools (one Local
# SSD-backed for the cache). Off by default — no effect on existing deployments.
#
# Enabling the infrastructure never changes the chart line on its own: Pass 2
# requires an explicit chart version, and every LangSmith integration gate below
# starts disabled.
#------------------------------------------------------------------------------
variable "enable_smithdb" {
  type        = bool
  description = "Provision the SmithDB cloud dependencies (Cloud SQL metastore, GCS object store, Workload Identity service account, Local SSD + compute node pools). Requires an explicit chart version of 0.16 or newer in Pass 2, and GKE Standard rather than Autopilot."
  default     = false
}

# --- Staged rollout gates ---------------------------------------------------
# SmithDB services deploy fully detached from LangSmith. Each gate is a separate
# validated stage: stand the services up, confirm they reach the metastore and
# the bucket, then enable ingestion, then optionally backfill, then move reads.
# Keep ClickHouse enabled throughout.
variable "smithdb_ingestion_enabled" {
  type        = bool
  description = "Route new LangSmith writes to SmithDB as well as ClickHouse. Enable only after the SmithDB services pass readiness checks."
  default     = false
}

variable "smithdb_migration_enabled" {
  type        = bool
  description = "Enable the historical ClickHouse-to-SmithDB migration integration. Requires smithdb_ingestion_enabled. Also spins up an in-chart taskdb Postgres for migration task state."
  default     = false
}

variable "smithdb_query_enabled" {
  type        = bool
  description = "Serve LangSmith UI and API reads from SmithDB. Requires smithdb_ingestion_enabled, and any historical migration you need, to be validated first."
  default     = false
}

# --- Metastore --------------------------------------------------------------
variable "smithdb_metastore_source" {
  type        = string
  description = "SmithDB metastore Postgres: 'create' (dedicated Cloud SQL instance) or 'external' (bring your own, e.g. AlloyDB behind the Auth Proxy). Must be a dedicated, empty database — never the LangSmith operational Postgres."
  default     = "create"

  validation {
    condition     = contains(["create", "external"], var.smithdb_metastore_source)
    error_message = "smithdb_metastore_source must be 'create' or 'external'."
  }
}

variable "smithdb_metastore_database_version" {
  type        = string
  description = "Cloud SQL Postgres version for the SmithDB metastore. SmithDB requires Postgres 17 or later."
  default     = "POSTGRES_18"
}

variable "smithdb_metastore_tier" {
  type        = string
  description = "Cloud SQL machine tier for the SmithDB metastore."
  default     = "db-custom-2-8192"
}

variable "smithdb_metastore_disk_size" {
  type        = number
  description = "Disk size in GB for the SmithDB metastore. Autoresize is on, so this is a floor."
  default     = 50
}

variable "smithdb_metastore_high_availability" {
  type        = bool
  description = "Run the SmithDB metastore as a REGIONAL (HA) Cloud SQL instance."
  default     = false
}

variable "smithdb_metastore_deletion_protection" {
  type        = bool
  description = "Prevent deletion of the SmithDB metastore instance, both from Terraform and from the Cloud SQL API. Keep true for production. Set false for dev/test environments that are destroyed and rebuilt, and apply that change before running destroy."
  default     = true
}

variable "smithdb_metastore_ssl_mode" {
  type        = string
  description = "Cloud SQL SSL enforcement for the SmithDB metastore. ENCRYPTED_ONLY requires TLS on every connection."
  default     = "ENCRYPTED_ONLY"
}

variable "smithdb_metastore_use_ssl" {
  type        = bool
  description = "Tell SmithDB to connect to the metastore over TLS. Keep true with ENCRYPTED_ONLY. Set false when an AlloyDB Auth Proxy sidecar terminates TLS on the pod loopback."
  default     = true
}

variable "smithdb_metastore_master_username" {
  type        = string
  description = "Master username for the SmithDB metastore."
  default     = "smithdb"
}

variable "smithdb_metastore_master_password" {
  type        = string
  description = "Master password for the SmithDB metastore. Leave null to auto-generate. Use TF_VAR_smithdb_metastore_master_password if setting explicitly."
  default     = null
  sensitive   = true
}

variable "smithdb_external_metastore_host" {
  type        = string
  description = "Hostname of an existing Postgres instance for the SmithDB metastore. Use 127.0.0.1 when fronting AlloyDB with the Auth Proxy sidecar."
  default     = null
}

variable "smithdb_external_metastore_port" {
  type        = number
  description = "Port of the existing SmithDB metastore Postgres instance."
  default     = 5432
}

variable "smithdb_external_metastore_database" {
  type        = string
  description = "Database name on the existing SmithDB metastore Postgres instance."
  default     = "smithdb"
}

variable "smithdb_external_metastore_username" {
  type        = string
  description = "Username for the existing SmithDB metastore Postgres instance."
  default     = null
}

variable "smithdb_external_metastore_password" {
  type        = string
  description = "Password for the existing SmithDB metastore. Empty when using AlloyDB IAM database authentication. Use TF_VAR_smithdb_external_metastore_password."
  default     = null
  sensitive   = true
}

# --- Object store -----------------------------------------------------------
variable "smithdb_bucket_name" {
  type        = string
  description = "Name of the SmithDB object-store bucket. Empty auto-generates {project_id}-{prefix}-{env}-smithdb{suffix}. Single-region is strongly recommended to avoid replication cost and unpredictable tail latency."
  default     = ""
}

variable "smithdb_bucket_kms_key" {
  type        = string
  description = "Cloud KMS key for CMEK on the SmithDB bucket. Empty uses Google-managed encryption."
  default     = ""
}

variable "smithdb_bucket_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete a non-empty SmithDB bucket on destroy. Set true only for test stacks."
  default     = false
}

variable "smithdb_service_account_email" {
  type        = string
  description = "Existing GCP service account email for the SmithDB pods. Leave null to create a dedicated least-privilege one."
  default     = null
}

# --- Node pools -------------------------------------------------------------
variable "smithdb_node_locations" {
  type        = list(string)
  description = "Zones for the SmithDB node pools. Empty uses every zone in the region, which fails if the machine type or Local SSD count is unavailable in any of them. Pin this after verifying availability."
  default     = []
}

variable "smithdb_instance_store_machine_type" {
  type        = string
  description = "Machine type for the Local SSD (cache) pool. N2/N2D take an explicit disk count; C3/C4/Z3 '-lssd' types bundle a fixed count and require smithdb_instance_store_local_ssd_count = 0. At chart defaults the three cache workloads request 4 CPU each, which fits within the ~15.9 allocatable vCPU of an n2-standard-16."
  default     = "n2-standard-16"
}

variable "smithdb_instance_store_local_ssd_count" {
  type        = number
  description = "Number of 375 GB Local SSDs per cache node, combined into one ephemeral-storage filesystem. At chart defaults the three cache workloads request 200Gi (query) + 100Gi (ingestion) + 100Gi (compactionWorker), so a node holding all of them needs roughly 430 GB allocatable; the default 3 disks (~1125 GB raw) covers that with headroom. Raise it if you override the resource requests upward."
  default     = 3
}

variable "smithdb_instance_store_disk_size" {
  type        = number
  description = "Boot disk size in GB for cache pool nodes. The cache itself lives on Local SSD."
  default     = 100
}

variable "smithdb_instance_store_min_nodes" {
  type        = number
  description = "Minimum nodes per zone in the cache pool. 0 lets the autoscaler scale to zero when SmithDB is idle."
  default     = 0
}

variable "smithdb_instance_store_max_nodes" {
  type        = number
  description = "Maximum nodes per zone in the cache pool."
  default     = 3
}

variable "smithdb_compute_machine_type" {
  type        = string
  description = "Machine type for the SmithDB compute pool (compaction, clusterManager)."
  default     = "n2-standard-8"
}

variable "smithdb_compute_disk_size" {
  type        = number
  description = "Boot disk size in GB for compute pool nodes."
  default     = 100
}

variable "smithdb_compute_min_nodes" {
  type        = number
  description = "Minimum nodes per zone in the SmithDB compute pool."
  default     = 0
}

variable "smithdb_compute_max_nodes" {
  type        = number
  description = "Maximum nodes per zone in the SmithDB compute pool."
  default     = 3
}
