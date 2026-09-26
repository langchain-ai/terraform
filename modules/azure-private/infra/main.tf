# ══════════════════════════════════════════════════════════════════════════════
# Module: langsmith (root / orchestration) — hardened always-BYO form
# Purpose: Wires all sub-modules together in the correct dependency order to
#          produce a full LangSmith deployment on Azure.
#
# Posture: Always BYO VNet/RG, CNI Overlay (Cilium), UDR egress, private API server.
#
# Deployment order (Terraform resolves via implicit dependencies):
#   1. data.azurerm_resource_group.existing — must exist before everything else
#   2. module.aks              — cluster needed for OIDC issuer URL (blob module)
#      module.postgres         — parallel with AKS (both need VNet)
#      module.redis            — parallel with AKS and postgres
#   3. module.blob             — needs AKS OIDC issuer URL for federated creds
#   4. module.keyvault         — needs blob managed identity principal ID for RBAC
#
# Deployment pattern (two-root split):
#   Root 1 — this file (infra/): azurerm-only; runs from anywhere (no k8s/helm providers).
#             terraform -chdir=infra apply
#   Root 2 — bootstrap/: in-cluster (KEDA, NGINX, namespace, secrets).
#             Run from the jumpbox AFTER the cluster is up.
#             terraform -chdir=bootstrap apply
# ══════════════════════════════════════════════════════════════════════════════

locals {
  identifier = var.identifier

  # Always BYO resource group — looked up, never created. Region inherited from it.
  resource_group_name = data.azurerm_resource_group.existing.name
  resource_group_id   = data.azurerm_resource_group.existing.id
  location            = data.azurerm_resource_group.existing.location

  # Derived resource names — all prefixed with "langsmith-<identifier>"
  vnet_name     = "langsmith-vnet${local.identifier}"
  aks_name      = "langsmith-aks${local.identifier}"
  postgres_name = "langsmith-postgres${local.identifier}"
  redis_name    = "langsmith-redis${local.identifier}"
  blob_name     = "langsmith-blob${local.identifier}" # blob module strips hyphens → "langsmithblobdz"

  # Key Vault name: max 24 chars, globally unique.
  # Uses the user-supplied keyvault_name or derives from identifier.
  keyvault_name = var.keyvault_name != "" ? var.keyvault_name : "langsmith-kv${local.identifier}"

  # Always BYO network — IDs supplied by the caller.
  vnet_id            = var.vnet_id
  aks_subnet_id      = var.aks_subnet_id
  postgres_subnet_id = var.postgres_subnet_id
  redis_subnet_id    = var.redis_subnet_id
  bastion_subnet_id  = var.bastion_subnet_id

  # ── Common tags ─────────────────────────────────────────────────────────────
  # Applied to every Azure resource in every sub-module.
  # Sub-modules merge their own { module = "..." } tag on top.
  # Customize via the environment/owner/cost_center variables.
  common_tags = merge(
    {
      environment = var.environment
      project     = "langsmith"
      managed_by  = "terraform"
    },
    var.owner != "" ? { owner = var.owner } : {},
    var.cost_center != "" ? { cost_center = var.cost_center } : {}
  )
}

# Existing resource group — resources deploy here; region taken from it.
data "azurerm_resource_group" "existing" {
  name = var.resource_group_name
}

# ── Kubernetes Cluster ────────────────────────────────────────────────────────
# AKS cluster with OIDC + Workload Identity enabled (azurerm-only; no k8s/helm providers).
# NGINX ingress, KEDA, and K8s secrets are installed by bootstrap/.
# The OIDC issuer URL output is consumed by module.blob for federated credentials.

module "aks" {
  source              = "./modules/k8s-cluster"
  cluster_name        = local.aks_name
  location            = local.location
  resource_group_name = local.resource_group_name
  subnet_id           = local.aks_subnet_id
  service_cidr        = var.aks_service_cidr   # K8s ClusterIP range (must not overlap VNet)
  dns_service_ip      = var.aks_dns_service_ip # CoreDNS IP (must be within service_cidr)

  # Network posture (overlay/cilium/UDR) is hardcoded inside the k8s-cluster module.
  pod_cidr = var.aks_pod_cidr

  default_node_pool_vm_size   = var.default_node_pool_vm_size
  default_node_pool_min_count = var.default_node_pool_min_count
  default_node_pool_max_count = var.default_node_pool_max_count
  default_node_pool_max_pods  = var.default_node_pool_max_pods

  # Additional pools (e.g. "large" for ClickHouse / memory-heavy workloads)
  additional_node_pools = var.additional_node_pools

  langsmith_namespace    = var.langsmith_namespace
  langsmith_release_name = var.langsmith_release_name

  # Preserve existing identity name when migrating from storage module.
  # New deployments leave this unset and get "${cluster_name}-app-identity".
  workload_identity_name = "k8s-app-identity"

  availability_zones = var.availability_zones

  # Private API server — always enabled (hardcoded inside k8s-cluster module).
  private_cluster_public_fqdn_enabled = var.aks_private_cluster_public_fqdn_enabled
  private_dns_zone_id                 = var.aks_private_dns_zone_id

  # Control-plane identity: user-assigned by default (matches always-BYO posture).
  create_cluster_identity = var.aks_create_cluster_identity
  cluster_identity_id     = var.aks_cluster_identity_id

  tags = local.common_tags
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
# Managed PostgreSQL Flexible Server in a private subnet.
# Only provisioned when postgres_source = "external".
# When postgres_source = "in-cluster", the Helm chart manages its own Postgres pod.

module "postgres" {
  count               = var.postgres_source == "external" ? 1 : 0
  source              = "./modules/postgres"
  name                = local.postgres_name
  location            = local.location
  resource_group_name = local.resource_group_name
  vnet_id             = local.vnet_id # needed to link the private DNS zone
  subnet_id           = local.postgres_subnet_id

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
  database_name  = var.postgres_database_name

  availability_zone            = var.availability_zones[0]
  standby_availability_zone    = var.postgres_standby_availability_zone
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  tags = local.common_tags
}

# ── Redis ─────────────────────────────────────────────────────────────────────
# Managed Redis Cache (Premium) in a private subnet.
# Only provisioned when redis_source = "external".
# When redis_source = "in-cluster", the Helm chart manages its own Redis pod.

module "redis" {
  count               = var.redis_source == "external" ? 1 : 0
  source              = "./modules/redis"
  name                = local.redis_name
  location            = local.location
  resource_group_name = local.resource_group_name
  resource_group_id   = local.resource_group_id # azapi parent_id for AMR
  subnet_id           = local.redis_subnet_id   # private endpoint goes here
  vnet_id             = local.vnet_id           # private DNS zone link
  amr_sku             = var.amr_sku

  tags = local.common_tags
}

# ── Blob Storage ──────────────────────────────────────────────────────────────
# Azure Blob Storage for trace objects.
# The Workload Identity (Managed Identity + Federated Credentials) is created
# in the k8s-cluster module and passed in here for the RBAC role assignment.

module "blob" {
  source               = "./modules/storage"
  storage_account_name = local.blob_name
  container_name       = "${local.blob_name}-container"
  location             = local.location
  resource_group_name  = local.resource_group_name

  ttl_enabled    = var.blob_ttl_enabled
  ttl_short_days = var.blob_ttl_short_days
  ttl_long_days  = var.blob_ttl_long_days

  # Workload Identity from k8s-cluster module — implicit dep on module.aks.
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  workload_identity_client_id    = module.aks.workload_identity_client_id

  # Default-deny on the storage data plane. AKS pods reach blobs via the
  # Microsoft.Storage service endpoint on the AKS subnet — enabling that
  # service endpoint (and Microsoft.KeyVault) is the operator's responsibility
  # as documented in the README prerequisites. Operators with extra clients
  # (CI runners, jumpboxes) add their public IPs via var.storage_allowed_ips.
  allowed_subnet_ids = [local.aks_subnet_id]
  allowed_ips        = var.storage_allowed_ips

  tags = local.common_tags
}

# ── Key Vault ─────────────────────────────────────────────────────────────────
# Centralized secret storage for all LangSmith sensitive values.
# Depends on blob module (needs the managed identity principal ID for RBAC).
# Secrets stored here: postgres password, admin password, license key, JWT
# secret, API key salt, and all Fernet encryption keys.
#
# First-apply: Key Vault is created and all current TF_VAR_* values are stored.
# Subsequent applies: setup-env.sh reads from Key Vault instead of local files.

module "keyvault" {
  source              = "./modules/keyvault"
  name                = local.keyvault_name
  location            = local.location
  resource_group_name = local.resource_group_name

  # The managed identity used by LangSmith pods gets read-only access to
  # all secrets so future CSI-driver integration requires no RBAC changes.
  managed_identity_principal_id = module.blob.k8s_managed_identity_principal_id

  # Network ACLs — default Allow keeps first-apply secret creation working.
  # Production deployments override keyvault_default_action = "Deny" and
  # populate keyvault_allowed_ips. The AKS subnet is always allowlisted so
  # pods can read secrets via the Microsoft.KeyVault service endpoint.
  network_default_action = var.keyvault_default_action
  allowed_ips            = var.keyvault_allowed_ips
  allowed_subnet_ids     = [local.aks_subnet_id]

  # ── Secrets ─────────────────────────────────────────────────────────────────
  # Values come from TF_VAR_* on first apply. setup-env.sh reads from Key Vault
  # on subsequent applies, eliminating local .secret files.
  postgres_admin_password  = var.postgres_admin_password
  langsmith_admin_password = var.langsmith_admin_password
  langsmith_license_key    = var.langsmith_license_key
  langsmith_api_key_salt   = var.langsmith_api_key_salt
  langsmith_jwt_secret     = var.langsmith_jwt_secret

  langsmith_deployments_encryption_key   = var.langsmith_deployments_encryption_key
  langsmith_agent_builder_encryption_key = var.langsmith_agent_builder_encryption_key
  langsmith_insights_encryption_key      = var.langsmith_insights_encryption_key
  langsmith_polly_encryption_key         = var.langsmith_polly_encryption_key

  # Connection URLs — written to Key Vault so the bootstrap/ root can read them
  # without this infra/ root needing kubernetes/helm providers.
  postgres_connection_url = var.postgres_source == "external" ? module.postgres[0].connection_url : ""
  redis_connection_url    = var.redis_source == "external" ? module.redis[0].connection_url : ""

  purge_protection_enabled = var.keyvault_purge_protection

  tags = local.common_tags

  depends_on = [module.blob]
}

# ── Diagnostics ────────────────────────────────────────────────────────────────
# Azure Monitor Log Analytics + diagnostic settings for AKS, Key Vault, Postgres.
# Always created in the hardened posture.

module "diagnostics" {
  source              = "./modules/diagnostics"
  name                = "langsmith-logs${local.identifier}"
  resource_group_name = local.resource_group_name
  location            = local.location
  retention_days      = var.log_retention_days

  aks_id      = module.aks.cluster_id
  keyvault_id = module.keyvault.vault_id
  postgres_id = var.postgres_source == "external" ? module.postgres[0].postgres_id : ""

  # Boolean flags known at plan time — count cannot depend on computed resource IDs.
  enable_aks_diag      = true
  enable_keyvault_diag = true
  enable_postgres_diag = var.postgres_source == "external"

  tags = local.common_tags
}

# ── Bastion ────────────────────────────────────────────────────────────────────
# Jump VM for private AKS cluster access. Uses Azure AD SSH login.
# Always created in the hardened posture (required for private cluster access).

module "bastion" {
  source               = "./modules/bastion"
  name                 = "langsmith-bastion${local.identifier}"
  resource_group_name  = local.resource_group_name
  location             = local.location
  subnet_id            = local.bastion_subnet_id
  vm_size              = var.bastion_vm_size
  admin_ssh_public_key = var.bastion_admin_ssh_public_key
  allowed_ssh_cidrs    = var.bastion_allowed_ssh_cidrs
  tags                 = local.common_tags
}
