# ── Deployment identifier ─────────────────────────────────────────────────────

variable "identifier" {
  type        = string
  description = "Short suffix appended to every resource name to distinguish environments (e.g. \"-prod\", \"-staging\"). Must start with a hyphen or be empty. Set in terraform.tfvars."
  default     = ""

  validation {
    condition     = var.identifier == "" || can(regex("^-[a-z0-9][a-z0-9-]*$", var.identifier))
    error_message = "identifier must be empty or a hyphen followed by lowercase letters/numbers/hyphens (e.g. \"-prod\", \"-dev-dz\")."
  }
}

# ── Resource tagging ──────────────────────────────────────────────────────────
# Tags are applied to every Azure resource for cost allocation, compliance,
# and incident response. Required by most enterprise Azure policies.

variable "environment" {
  type        = string
  description = "Deployment environment. Used as the 'environment' tag on all resources."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be 'dev', 'staging', or 'prod'."
  }
}

variable "owner" {
  type        = string
  description = "Email or team name of the resource owner. Used as the 'owner' tag on all resources."
  default     = ""
}

variable "cost_center" {
  type        = string
  description = "Cost center or billing code for charge-back. Used as the 'cost_center' tag on all resources."
  default     = ""
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

variable "keyvault_name" {
  type        = string
  description = "Name for the Azure Key Vault. Must be globally unique, 3-24 chars. Defaults to 'langsmith-kv<identifier>' which you may need to customize to avoid naming conflicts."
  default     = ""
  # When empty, main.tf computes: "langsmith-kv${local.identifier}"
}

variable "keyvault_purge_protection" {
  type        = bool
  description = "Enable purge protection on Key Vault. Set false for dev environments where you need to destroy and recreate. Always true for production."
  default     = true
}

variable "location" {
  type        = string
  description = "The location of the LangSmith deployment"
  default     = "eastus"
}

variable "subscription_id" {
  type        = string
  description = "The subscription id of the LangSmith deployment"
}

variable "create_vnet" {
  type        = bool
  description = "Whether to create a new VNet. If false, you will need to provide a vnet id and subnet ids."
  default     = true
}

variable "vnet_id" {
  type        = string
  description = "The id of the existing VNet to use. If create_vnet is false, this is required."
  default     = ""
}

variable "aks_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the AKS cluster. If create_vnet is false, this is required."
  default     = ""
}

variable "postgres_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Postgres server. If create_vnet is false, this is required."
  default     = ""
}

variable "redis_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Redis server. If create_vnet is false, this is required."
  default     = ""
}

variable "postgres_source" {
  type        = string
  description = "PostgreSQL deployment type. 'external' provisions Azure Database for PostgreSQL Flexible Server (private VNet). 'in-cluster' uses the chart-managed in-cluster Postgres pod (dev/demo only)."
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be 'external' or 'in-cluster'."
  }
}

variable "redis_source" {
  type        = string
  description = "Redis deployment type. 'external' provisions Azure Cache for Redis (private VNet). 'in-cluster' uses the chart-managed in-cluster Redis pod (dev/demo only)."
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be 'external' or 'in-cluster'."
  }
}

variable "clickhouse_source" {
  type        = string
  description = "ClickHouse deployment type. 'in-cluster' deploys ClickHouse as a pod via Helm (dev/POC only). 'external' for LangChain Managed ClickHouse (recommended for production) — see https://docs.langchain.com/langsmith/langsmith-managed-clickhouse"
  default     = "in-cluster"

  validation {
    condition     = contains(["in-cluster", "external"], var.clickhouse_source)
    error_message = "clickhouse_source must be 'in-cluster' or 'external'."
  }
}

variable "redis_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Redis subnet. Can be disjoint IP ranges."
  default     = ["10.0.48.0/20"] # 4k IP addresses
}

variable "postgres_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Postgres subnet. Can be disjoint IP ranges."
  default     = ["10.0.32.0/20"] # 4k IP addresses
}

variable "redis_capacity" {
  type        = number
  description = "The capacity of the Redis server. This maps to a certain memory and CPU combination."
  default     = 2
}

variable "blob_ttl_enabled" {
  type        = bool
  description = "Enable TTL for the blob container"
  default     = true
}

variable "blob_ttl_short_days" {
  type        = number
  description = "The number of days to keep short-lived blobs"
  default     = 14
}

variable "blob_ttl_long_days" {
  type        = number
  description = "The number of days to keep long-lived blobs"
  default     = 400
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_DS3_v2" # 4 vCPU, 14GB RAM — DSv2 family (60 free vCPUs in eastus)
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max count of the default node pool. Set to at least 4 when using Agent Builder — the LGP postgres pod needs ~1 vCPU request."
  default     = 4
}

variable "aks_service_cidr" {
  type        = string
  description = "The service CIDR of the AKS cluster"
  default     = "10.0.64.0/20"
}

variable "aks_dns_service_ip" {
  type        = string
  description = "The DNS service IP of the AKS cluster"
  default     = "10.0.64.10"
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Additional node pools to be created"
  default = {
    large = {
      vm_size   = "Standard_DS4_v2" # 8 vCPU, 28GB RAM — DSv2 family (widely available quota)
      min_count = 0
      max_count = 2
    }
  }
}

variable "aks_deletion_protection" {
  type        = bool
  description = "Prevent accidental AKS cluster deletion. Set false for dev/test environments where you need to destroy and recreate."
  default     = true
}

variable "postgres_deletion_protection" {
  type        = bool
  description = "Prevent accidental PostgreSQL server deletion. Set false for dev/test environments."
  default     = true
}

variable "langsmith_namespace" {
  type        = string
  description = "Namespace of the LangSmith deployment. Used to set up workload identity in a specific namespace for blob storage."
  default     = "langsmith"
}

variable "nginx_ingress_enabled" {
  type        = bool
  description = "Install the nginx ingress helm chart on the AKS cluster."
  default     = true
}

variable "letsencrypt_email" {
  type        = string
  description = "Email address for Let's Encrypt certificate notifications. Required when tls_certificate_source = 'letsencrypt'."
  default     = ""
}

variable "langsmith_domain" {
  type        = string
  description = "Hostname for the LangSmith deployment (e.g. langsmith.example.com). Used in Helm values and ingress TLS configuration."
  default     = ""
}

variable "langsmith_helm_chart_version" {
  type        = string
  description = "Pin a specific LangSmith Helm chart version for reproducible deploys. Empty string = use latest available."
  default     = ""
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS certificate source. 'letsencrypt' = automatic via cert-manager. 'existing' = bring your own cert. 'none' = HTTP only (demo/dev)."
  default     = "letsencrypt"

  validation {
    condition     = contains(["none", "letsencrypt", "existing"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be 'none', 'letsencrypt', or 'existing'."
  }
}

variable "postgres_admin_username" {
  type        = string
  description = "The username of the Postgres administrator"
  default     = "langsmith"
}

variable "postgres_admin_password" {
  type        = string
  description = "The password of the Postgres administrator. Set via: source setup-env.sh"
  sensitive   = true
  default     = ""
}

# ── LangSmith secrets (stored in Key Vault by the keyvault module) ────────────
# These are written to Azure Key Vault on first apply. On subsequent runs,
# setup-env.sh reads them back from Key Vault so they stay stable.
# Application deployment uses helm/scripts/generate-secrets.sh to pull from KV.

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith (used for Workload Identity federated credential subjects in the blob module)"
  default     = "langsmith"
}

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key. Stored in Key Vault and in K8s secret langsmith-license."
  sensitive   = true
  default     = ""
}

variable "langsmith_admin_password" {
  type        = string
  description = "Initial LangSmith organization admin password. Stored in Key Vault: langsmith-admin-password."
  sensitive   = true
  default     = ""
}

variable "langsmith_api_key_salt" {
  type        = string
  description = "Salt used to hash LangSmith API keys. Generate once: openssl rand -base64 32. Keep stable — changing invalidates all API keys. Stored in Key Vault: langsmith-api-key-salt. Set via setup-env.sh (TF_VAR_langsmith_api_key_salt)."
  sensitive   = true
  default     = ""
}

variable "langsmith_jwt_secret" {
  type        = string
  description = "JWT secret for LangSmith Basic Auth sessions. Generate once: openssl rand -base64 32. Keep stable. Stored in Key Vault: langsmith-jwt-secret. Set via setup-env.sh (TF_VAR_langsmith_jwt_secret)."
  sensitive   = true
  default     = ""
}

# ── LangGraph Platform encryption keys ───────────────────────────────────────
# Stored in Key Vault by Terraform. Read by generate-secrets.sh when enabling
# optional features via Helm overlays. Generate once and never change.

variable "langsmith_deployments_encryption_key" {
  type        = string
  description = "Fernet key for LangSmith Deployments. Stored in Key Vault: langsmith-deployments-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_agent_builder_encryption_key" {
  type        = string
  description = "Fernet key for Agent Builder. Stored in Key Vault: langsmith-agent-builder-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_insights_encryption_key" {
  type        = string
  description = "Fernet key for Insights (Clio). Stored in Key Vault: langsmith-insights-encryption-key. Must stay stable — changing breaks existing insights data."
  sensitive   = true
  default     = ""
}

variable "langsmith_polly_encryption_key" {
  type        = string
  description = "Fernet key for Polly agent. Stored in Key Vault: langsmith-polly-encryption-key. Must stay stable — changing breaks existing Polly data."
  sensitive   = true
  default     = ""
}
