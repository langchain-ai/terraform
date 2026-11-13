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

# ── Subscription ──────────────────────────────────────────────────────────────

variable "subscription_id" {
  type        = string
  description = "The subscription id of the LangSmith deployment"
}

# ── BYO resource group ────────────────────────────────────────────────────────

variable "resource_group_name" {
  type        = string
  description = "Name of the existing resource group to deploy into. All resources deploy here and the region is taken from this RG."
  default     = ""
}

# ── BYO network ───────────────────────────────────────────────────────────────

variable "vnet_id" {
  type        = string
  description = "The id of the existing VNet to use."
  default     = ""
}

variable "aks_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the AKS cluster."
  default     = ""
}

variable "postgres_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Postgres server."
  default     = ""
}

variable "redis_subnet_id" {
  type        = string
  description = "The id of the existing subnet to use for the Redis server."
  default     = ""
}

variable "bastion_subnet_id" {
  type        = string
  description = "Existing bastion subnet ID."
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

variable "keyvault_default_action" {
  type        = string
  description = "Default action for the Key Vault data-plane firewall. \"Allow\" (default) keeps the starter UX working — first apply creates ~10 secrets via the data plane and \"Deny\" without operator IP allowlisting blocks that. Production deployments set \"Deny\" and populate keyvault_allowed_ips."
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.keyvault_default_action)
    error_message = "keyvault_default_action must be 'Allow' or 'Deny'."
  }
}

variable "keyvault_allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the Key Vault firewall when keyvault_default_action = \"Deny\". The AKS subnet is allowlisted automatically via the Microsoft.KeyVault service endpoint."
  default     = []
}

# ── Backing services ──────────────────────────────────────────────────────────

variable "postgres_database_name" {
  type        = string
  description = "Name of the PostgreSQL database LangSmith connects to. Must match the database that exists on the server."
  default     = "langsmith"
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

variable "amr_sku" {
  type        = string
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest. Bump (Balanced_B1/B3/...) if the region reports AllocationFailed. (Replaces the classic redis_capacity.)"
  default     = "Balanced_B0"
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

variable "storage_allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the storage account default-deny firewall. AKS pod traffic is allowlisted automatically via the Microsoft.Storage service endpoint on the AKS subnet — only add operator workstations, CI runners, or other external clients that need to reach the blob data plane."
  default     = []
}

# ── AKS node pool sizing guidance ─────────────────────────────────────────────
# Pass 2 (core LangSmith): ~13 vCPU / 24 GiB scheduled across default pool nodes.
#   backend×3 (3 vCPU/6Gi) + platformBackend (1 vCPU/2Gi) + queue×3 (3 vCPU/6Gi)
#   + ingestQueue×3 (3 vCPU/6Gi) + frontend + playground + aceBackend + system pods
#   → Standard_D8s_v3 × 3 nodes (24 vCPU / 96 GiB) comfortably fits Pass 2.
#
# Pass 3–5 (LangGraph Platform, Agent Builder, Insights): add ~3 vCPU / 5 GiB.
#   Total with autoscale headroom: max_count = 12 (Standard_D8s_v3).
#
# ClickHouse: 3.5 vCPU / 15 GiB request — always scheduled to the large pool
#   (Standard_D16s_v3, 16 vCPU / 64 GiB) via node affinity set in the chart.
#   Production recommendation from upstream: 8 vCPU / 32 GiB for heavy tracing load.
#
# Official LangSmith minimum: 16 vCPU / 64 GiB cluster-wide.
# See: https://docs.langchain.com/langsmith/kubernetes

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size for the default AKS node pool. Standard_D8s_v3 (8 vCPU / 32 GiB) is the recommended baseline for Pass 2+ (external Postgres + Redis). Use Standard_D4s_v3 (4 vCPU / 16 GiB) only for light/demo deployments (in-cluster DBs). See sizing comment above."
  default     = "Standard_D8s_v3" # 8 vCPU, 32 GiB
}

variable "default_node_pool_min_count" {
  type        = number
  description = "Min node count for the default pool. Autoscaler never scales below this floor. Set to 3 for production — Pass 2 needs ~14.4 vCPU and 3× Standard_D8s_v3 provides 18,870m allocatable (76% CPU). Set to 1 for minimum/dev deployments."
  default     = 1
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max node count for the default pool. Pass 2: 4–6 nodes. Pass 3 (LangGraph Platform): 6. Pass 4 (Agent Builder): 8. Pass 5 (Insights): 10–12. Autoscaler scales within this limit — increasing max_count takes effect immediately with no node restarts."
  default     = 10
}

variable "default_node_pool_max_pods" {
  type        = number
  description = "Max pods per node in the default pool. AKS Azure CNI default is 30 — too low for LangSmith. Pass 2 alone needs ~32 pods (17 LangSmith + 15 system). Set to 60 to fit full multi-pass deployments on a single node. Immutable — changing requires node pool recreation."
  default     = 60
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
  description = "Additional node pools. The 'large' pool (Standard_D16s_v3, 16 vCPU / 64 GiB) is required for ClickHouse (requests 3.5 vCPU / 15 GiB) and LangGraph Platform agent pods. min_count = 0 means it scales to zero when idle. Increase max_count to 3+ for Pass 4 (Agent Builder) with multiple simultaneous deployments."
  default = {
    large = {
      vm_size   = "Standard_D16s_v3" # 16 vCPU, 64 GiB — ClickHouse (3.5 vCPU/15Gi request) + dataplane agent pods
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

# TLS: the ingress consumes a Kubernetes secret named `langsmith-tls`, created by
# infra/scripts/create-tls-secret.sh (self-signed for testing; replace for prod).
# There is no cert-manager and no tls_certificate_source variable — see DEPLOYMENT.md.

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
# scripts/create-k8s-secrets.sh pulls them from Key Vault into the cluster.

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith (used for Workload Identity federated credential subjects in the k8s-cluster module)"
  default     = "langsmith"

  # The chart renders service-account names as <langsmith.fullname>-<component>, and
  # langsmith.fullname collapses to just the release name only when the release name
  # CONTAINS the chart name "langsmith". If it doesn't, the rendered SA names won't
  # match the federated-credential subjects and Workload Identity fails silently.
  validation {
    condition     = can(regex("langsmith", var.langsmith_release_name))
    error_message = "langsmith_release_name must contain the substring \"langsmith\" so the chart's rendered ServiceAccount names match the Workload Identity federation (see DEPLOYMENT.md → Chart-version compatibility)."
  }
}

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key. Stored in Key Vault; surfaced into the cluster as key langsmith_license_key of the langsmith-config-secret by create-k8s-secrets.sh."
  sensitive   = true
  default     = ""
}

variable "langsmith_admin_password" {
  type        = string
  description = "Initial LangSmith organization admin password. Stored in Key Vault: langsmith-admin-password."
  sensitive   = true
  default     = ""
}

variable "langsmith_admin_email" {
  type        = string
  description = "Initial LangSmith organization admin email. Set via setup-env.sh — used as initialOrgAdminEmail in Helm values."
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
# Stored in Key Vault by Terraform. Surfaced into the cluster by
# scripts/create-k8s-secrets.sh when the matching feature is enabled via Helm
# overlays. Generate once and never change.

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

# ── Diagnostics ───────────────────────────────────────────────────────────────

variable "log_retention_days" {
  type        = number
  description = "Log Analytics workspace retention in days."
  default     = 90
}

# ── Bastion ───────────────────────────────────────────────────────────────────

variable "bastion_vm_size" {
  type        = string
  description = "VM SKU for the bastion host."
  default     = "Standard_B2s"
}

variable "bastion_admin_ssh_public_key" {
  type        = string
  description = "SSH public key for emergency admin access to the bastion VM."
  default     = ""
}

variable "bastion_allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed inbound SSH to the bastion. Restrict to VPN/corporate ranges in production."
  default     = ["0.0.0.0/0"]
}

# ── Multi-AZ ─────────────────────────────────────────────────────────────────

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to deploy into. Use [\"1\",\"2\",\"3\"] for zone-redundant HA. Default [\"1\"] for single-zone."
  default     = ["1"]
}

variable "postgres_standby_availability_zone" {
  type        = string
  description = "Standby AZ for Postgres HA (ZoneRedundant mode). Leave empty to disable HA standby."
  default     = ""
}

variable "postgres_geo_redundant_backup" {
  type        = bool
  description = "Enable geo-redundant backups for PostgreSQL."
  default     = false
}

# ── Helm / deployment flags (read by bash scripts, not by Terraform) ──────────
# These variables are declared here only to prevent Terraform from warning
# about undeclared variables in terraform.tfvars. They are read by
# helm/scripts/init-values.sh and helm/scripts/deploy.sh.

variable "sizing_profile" {
  type        = string
  description = "Helm sizing overlay. One of: minimum | dev | production | production-large. Read by helm/scripts/init-values.sh and deploy.sh — Terraform ignores this value."
  default     = "production"
}

variable "enable_deployments" {
  type        = bool
  description = "Pass 3 — enable LangGraph Platform (hostBackend, listener, operator). Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_agent_builder" {
  type        = bool
  description = "Pass 4 — enable Agent Builder UI. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_insights" {
  type        = bool
  description = "Pass 5 — enable Insights / Clio. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_polly" {
  type        = bool
  description = "Pass 5 — enable Polly AI eval agent. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

# ── AKS networking (Azure CNI Overlay / egress) ──────────────────────────────
# NOTE: network_plugin_mode, network_policy, and outbound_type are hardcoded
# in main.tf (overlay / cilium / userDefinedRouting). Only the pod CIDR is
# exposed as a variable since it must not overlap VNet/service ranges.

variable "aks_pod_cidr" {
  type        = string
  description = "Pod CIDR for Azure CNI Overlay. Must not overlap the VNet, aks_service_cidr, or peered/on-prem ranges."
  default     = "10.244.0.0/16"
}

# ── AKS private API server ────────────────────────────────────────────────────

variable "aks_private_cluster_public_fqdn_enabled" {
  type        = bool
  description = "Expose a public FQDN for the private API server. Default false (disabled)."
  default     = false
}

variable "aks_private_dns_zone_id" {
  type        = string
  description = "Private DNS zone for the private API server. \"\" => \"System\" (AKS-managed). \"None\" => BYO DNS. Or a private DNS zone resource ID. Note: \"None\" requires aks_private_cluster_public_fqdn_enabled = true — AKS does not support \"None\" together with a disabled public FQDN."
  default     = ""
}

# ── AKS control-plane (cluster) managed identity ──────────────────────────────

variable "aks_create_cluster_identity" {
  type        = bool
  description = "Create a user-assigned managed identity for the AKS control plane and grant it Network Contributor on the VNet — VNet scope so it can join the subnet and link the System private DNS zone for a private cluster. Azure recommends a user-assigned identity for BYO-VNet / userDefinedRouting. Default true (always-user-assigned posture). Mutually exclusive with aks_cluster_identity_id."
  default     = true
}

variable "aks_cluster_identity_id" {
  type        = string
  description = "Resource ID of an existing user-assigned managed identity to use as the AKS control-plane identity. Required for a custom (BYO) API-server private DNS zone — pre-grant it Private DNS Zone Contributor on the zone and Network Contributor on the VNet/subnet. Mutually exclusive with aks_create_cluster_identity. Empty => system-assigned."
  default     = ""
}
