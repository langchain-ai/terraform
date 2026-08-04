# ══════════════════════════════════════════════════════════════════════════════
# Module: langsmith (root / orchestration)
# Purpose: Wires all sub-modules together in the correct dependency order to
#          produce a full LangSmith deployment on Azure.
#
# Deployment order (Terraform resolves via implicit dependencies):
#   1. azurerm_resource_group  — must exist before everything else
#   2. module.vnet             — network must exist before compute/DB
#   3. module.aks              — cluster needed for OIDC issuer URL (blob module)
#      module.postgres         — parallel with AKS (both need VNet)
#      module.redis            — parallel with AKS and postgres
#   4. module.blob             — needs AKS OIDC issuer URL for federated creds
#   5. module.keyvault         — needs blob managed identity principal ID for RBAC
#   6. module.k8s_bootstrap    — needs cluster credentials + all connection URLs
#
# Deployment pattern:
#   Pass 1 (this module): terraform apply → Azure infra only (AKS, Postgres, Redis, Blob, KV)
#   Pass 2+: helm/scripts/ → LangSmith Helm deploy, optional feature overlays
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # Identifier comes from var.identifier (set in terraform.tfvars).
  # Examples: "-prod", "-staging", "" (no suffix for single-environment setups).
  identifier = var.identifier

  # Derived resource names — all prefixed with "langsmith-<identifier>"
  resource_group_name = "langsmith-rg${local.identifier}"
  vnet_name           = "langsmith-vnet${local.identifier}"

  # Cluster name: derived for new clusters, or the customer's existing cluster
  # name when attaching to one (create_cluster = false). No fallback in the
  # attach case — an unset existing_cluster_name fails on the aks module's
  # precondition instead of looking up a cluster that was never created.
  aks_name      = var.create_cluster ? "langsmith-aks${local.identifier}" : var.existing_cluster_name
  postgres_name = "langsmith-postgres${local.identifier}"
  redis_name    = "langsmith-redis${local.identifier}"
  blob_name     = "langsmith-blob${local.identifier}" # blob module strips hyphens → "langsmithblobdz"

  # Key Vault name: max 24 chars, globally unique.
  # Uses the user-supplied keyvault_name or derives from identifier. When
  # attaching to a customer-owned vault (create_keyvault = false) the name is
  # theirs, with no fallback — an unset existing_keyvault_name fails on the
  # keyvault module's precondition instead of deriving a name for a vault that
  # was never created.
  keyvault_name = var.create_keyvault ? (var.keyvault_name != "" ? var.keyvault_name : "langsmith-kv${local.identifier}") : var.existing_keyvault_name

  # Whether the keyvault module creates each of its two role assignments. Both
  # default to create_keyvault: a vault this module creates gets both grants, a
  # customer's vault gets neither, because creating them there means calling
  # Microsoft.Authorization/roleAssignments/write on a resource their platform
  # team owns. Gated one apiece rather than together because the two requests
  # carry different principal types, and a subscription that delegates
  # roleAssignments/write through an ABAC condition on principalType can reject
  # the deployer's grant while permitting the managed identity's.
  keyvault_manage_terraform_admin_assignment  = var.keyvault_manage_terraform_admin_assignment != null ? var.keyvault_manage_terraform_admin_assignment : var.create_keyvault
  keyvault_manage_managed_identity_assignment = var.keyvault_manage_managed_identity_assignment != null ? var.keyvault_manage_managed_identity_assignment : var.create_keyvault

  # Subnet ID resolution: use newly-created VNet subnets OR bring-your-own
  # existing ones (set create_vnet = false and supply the IDs via variables).
  vnet_id            = var.create_vnet ? module.vnet.vnet_id : var.vnet_id
  aks_subnet_id      = var.create_vnet ? module.vnet.subnet_main_id : var.aks_subnet_id
  postgres_subnet_id = var.create_vnet ? module.vnet.subnet_postgres_id : var.postgres_subnet_id
  redis_subnet_id    = var.create_vnet ? module.vnet.subnet_redis_id : var.redis_subnet_id
  agic_subnet_id     = var.create_vnet ? module.vnet.subnet_agic_id : ""

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

# The resource group that contains all LangSmith Azure resources.
# Deleting this resource group will delete EVERYTHING inside it.
resource "azurerm_resource_group" "resource_group" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ── Networking ────────────────────────────────────────────────────────────────
# Creates VNet + three dedicated subnets (AKS, PostgreSQL, Redis).
# Skip this block (create_vnet = false) to reuse an existing VNet.

module "vnet" {
  source              = "./modules/networking"
  network_name        = local.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  # Controls whether the Postgres/Redis subnets are created.
  # Set false if using in-cluster Postgres/Redis (no dedicated subnets needed).
  enable_external_postgres = var.postgres_source == "external"
  enable_external_redis    = var.redis_source == "external"

  postgres_subnet_address_prefix = var.postgres_subnet_address_prefix
  redis_subnet_address_prefix    = var.redis_subnet_address_prefix

  enable_bastion     = var.create_bastion
  availability_zones = var.availability_zones

  # AGIC subnet: provisioned only when ingress_controller = "agic"
  enable_agic                = var.ingress_controller == "agic"
  agic_subnet_address_prefix = var.agic_subnet_address_prefix

  tags = local.common_tags
}

# ── Kubernetes Cluster ────────────────────────────────────────────────────────
# AKS cluster with OIDC + Workload Identity enabled, NGINX ingress installed.
# The OIDC issuer URL output is consumed by module.blob for federated credentials.

module "aks" {
  source              = "./modules/k8s-cluster"
  cluster_name        = local.aks_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id           = local.aks_subnet_id
  service_cidr        = var.aks_service_cidr   # K8s ClusterIP range (must not overlap VNet)
  dns_service_ip      = var.aks_dns_service_ip # CoreDNS IP (must be within service_cidr)

  # Bring-your-own cluster: read an existing AKS cluster instead of creating one.
  create_cluster = var.create_cluster
  create_vnet    = var.create_vnet

  # Both of these are passed straight from variables, never derived from another
  # resource. azurerm_resource_group.resource_group is pending creation on a first
  # apply, and local.aks_subnet_id reads module.vnet.subnet_main_id, whose module
  # has no count and so is pending too. A reference to either draws a dependency
  # edge that defers the cluster lookup to apply, taking the OIDC issuer, Workload
  # Identity, node subnet, and region guards with it, silent on exactly the run
  # where a misconfiguration is most likely. var.aks_subnet_id is the right value
  # to use because create_cluster = false requires create_vnet = false.
  existing_cluster_resource_group_name = var.existing_cluster_resource_group_name
  existing_cluster_subnet_id           = var.aks_subnet_id

  default_node_pool_vm_size   = var.default_node_pool_vm_size
  default_node_pool_min_count = var.default_node_pool_min_count
  default_node_pool_max_count = var.default_node_pool_max_count
  default_node_pool_max_pods  = var.default_node_pool_max_pods

  # Additional pools (e.g. "large" for ClickHouse / memory-heavy workloads).
  # On a pre-existing cluster whose node pools the customer owns, pass an empty
  # map so Terraform doesn't attach pools to a cluster it doesn't manage.
  additional_node_pools = var.create_cluster || var.existing_cluster_node_pools_managed ? var.additional_node_pools : {}

  # Ingress controller: 'nginx' (Helm), 'istio' (Helm), 'istio-addon' (Azure managed), 'agic', 'envoy-gateway', 'none'
  ingress_controller   = var.ingress_controller
  dns_label            = var.dns_label
  istio_version        = var.istio_version
  istio_addon_revision = var.istio_addon_revision

  # AGIC — wired from vnet module output
  subscription_id = var.subscription_id
  agic_subnet_id  = local.agic_subnet_id
  agw_sku_tier    = var.agw_sku_tier

  # Envoy Gateway
  envoy_gateway_version = var.envoy_gateway_version

  langsmith_namespace    = var.langsmith_namespace
  langsmith_release_name = var.langsmith_release_name

  # Preserve existing identity name when migrating from storage module.
  # New deployments leave this unset and get "${cluster_name}-app-identity".
  workload_identity_name = "k8s-app-identity"

  availability_zones = var.availability_zones

  # API server access — empty list keeps the master publicly reachable for
  # Terraform-driven Helm/kubectl steps. Populate var.aks_authorized_ip_ranges
  # in terraform.tfvars to restrict to operator/CI CIDRs.
  authorized_ip_ranges = var.aks_authorized_ip_ranges

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
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  vnet_id             = local.vnet_id # needed to link the private DNS zone
  subnet_id           = local.postgres_subnet_id

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
  database_name  = var.postgres_database_name

  availability_zone            = var.availability_zones[0]
  standby_availability_zone    = var.postgres_standby_availability_zone
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  # Create the dedicated langsmith_fleet database when standalone Fleet is enabled.
  enable_fleet = var.enable_fleet

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
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  resource_group_id   = azurerm_resource_group.resource_group.id # azapi parent_id for AMR
  subnet_id           = local.redis_subnet_id                    # private endpoint goes here
  vnet_id             = local.vnet_id                            # private DNS zone link
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
  location             = var.location
  resource_group_name  = azurerm_resource_group.resource_group.name

  ttl_enabled    = var.blob_ttl_enabled
  ttl_short_days = var.blob_ttl_short_days
  ttl_long_days  = var.blob_ttl_long_days

  # Workload Identity from k8s-cluster module — implicit dep on module.aks.
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  workload_identity_client_id    = module.aks.workload_identity_client_id

  # Default-deny on the storage data plane. AKS pods reach blobs via the
  # Microsoft.Storage service endpoint on the AKS subnet (see networking module).
  # Operators with extra clients (CI runners, jumpboxes) add their public IPs
  # via var.storage_allowed_ips.
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
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  # Bring-your-own Key Vault: attach to a customer-owned vault instead of
  # creating one. The module writes its secrets into that vault and changes
  # nothing else about it, so the network ACL and retention settings below are
  # ignored on this path.
  create_keyvault                       = var.create_keyvault
  existing_keyvault_name                = var.existing_keyvault_name
  existing_keyvault_resource_group_name = var.existing_keyvault_resource_group_name
  manage_terraform_admin_assignment     = local.keyvault_manage_terraform_admin_assignment
  manage_managed_identity_assignment    = local.keyvault_manage_managed_identity_assignment

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

  purge_protection_enabled = var.keyvault_purge_protection

  tags = local.common_tags

  depends_on = [module.blob]
}

# ── Kubernetes Bootstrap ───────────────────────────────────────────────────────
# Connects to the AKS cluster and:
#   1. Creates the langsmith namespace, service account, resource quota, network policies
#   2. Installs cert-manager (TLS automation) and KEDA (autoscaling)
#   3. Creates K8s secrets for PostgreSQL and Redis connection URLs
#
# LangSmith application deployment is handled outside Terraform:
#   Pass 1.5: bash helm/scripts/get-kubeconfig.sh <cluster> <rg>
#   Pass 1.6: ACME_EMAIL=... bash helm/scripts/apply-cluster-issuers.sh
#   Pass 2:   bash helm/scripts/generate-secrets.sh && bash helm/scripts/deploy.sh
#   Pass 3+:  bash helm/scripts/deploy.sh --overlay overlays/<feature>.yaml
#
# Note: This module configures its own kubernetes/helm providers internally,
# so depends_on cannot be used here. Implicit deps via input variables ensure
# correct ordering (AKS/postgres/redis/blob must be ready before this runs).

module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"

  # Cluster connection — passed directly to the kubernetes/helm providers
  # inside the k8s-bootstrap module.
  host                   = module.aks.host
  client_certificate     = module.aks.client_certificate
  client_key             = module.aks.client_key
  cluster_ca_certificate = module.aks.cluster_ca_certificate

  # K8s namespace for LangSmith workloads
  langsmith_namespace = var.langsmith_namespace

  # Ingress controller — drives the NetworkPolicy's allowed source namespace.
  ingress_controller = var.ingress_controller

  # Backing services — connection URLs are injected as K8s secrets.
  # generate-secrets.sh also writes these secrets with the full URL from KV.
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? module.postgres[0].connection_url : ""
  postgres_admin_password = var.postgres_source == "external" ? var.postgres_admin_password : ""
  use_external_redis      = var.redis_source == "external"
  redis_connection_url    = var.redis_source == "external" ? module.redis[0].connection_url : ""

  # Standalone Fleet — creates the langsmith-fleet-postgres secret pointing at the
  # dedicated langsmith_fleet database. No fleet Redis secret: Fleet uses the chart's
  # in-cluster bundled Redis (Azure Managed Redis can't do the logical-DB isolation
  # the AWS/GCP Fleet relies on).
  enable_fleet                  = var.enable_fleet
  fleet_postgres_connection_url = var.postgres_source == "external" && var.enable_fleet ? module.postgres[0].fleet_connection_url : ""

  # Blob storage — Workload Identity client ID is added as a pod annotation
  # so the OIDC token exchange can bind the pod to the Managed Identity.
  blob_managed_identity_client_id = module.blob.k8s_managed_identity_client_id

  # License key — stored in K8s secret langsmith-license.
  # App secrets (api_key_salt, jwt_secret, admin_password) are written by
  # helm/scripts/generate-secrets.sh from Azure Key Vault.
  langsmith_license_key = var.langsmith_license_key

  # TLS / cert-manager
  tls_certificate_source          = var.tls_certificate_source
  letsencrypt_email               = var.letsencrypt_email
  cert_manager_identity_client_id = module.aks.cert_manager_identity_client_id
  subscription_id                 = var.subscription_id
  dns_zone_name                   = var.create_dns_zone ? var.langsmith_domain : ""
  dns_resource_group_name         = azurerm_resource_group.resource_group.name
}

# ── WAF (optional) ────────────────────────────────────────────────────────────
# Deploy Azure WAF policy with OWASP 3.2 + bot protection.
# Attach to Application Gateway or Azure Front Door after creation.
# Enable with: create_waf = true in terraform.tfvars

module "waf" {
  count               = var.create_waf ? 1 : 0
  source              = "./modules/waf"
  name                = "langsmith-waf${local.identifier}"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.location
  waf_mode            = var.waf_mode
  tags                = local.common_tags
}

# ── Diagnostics (optional) ────────────────────────────────────────────────────
# Azure Monitor Log Analytics + diagnostic settings for AKS, Key Vault, Postgres.
# Enable with: create_diagnostics = true in terraform.tfvars

module "diagnostics" {
  count               = var.create_diagnostics ? 1 : 0
  source              = "./modules/diagnostics"
  name                = "langsmith-logs${local.identifier}"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.location
  retention_days      = var.log_retention_days

  aks_id      = module.aks.cluster_id
  keyvault_id = module.keyvault.vault_id
  postgres_id = var.postgres_source == "external" ? module.postgres[0].postgres_id : ""

  # Boolean flags known at plan time — count cannot depend on computed resource IDs.
  # Key Vault diagnostics only when this module owns the vault: writing a
  # diagnostic setting onto a customer's vault changes their resource, and a
  # platform-owned vault usually already has one collecting AuditEvent.
  enable_aks_diag      = true
  enable_keyvault_diag = var.create_keyvault
  enable_postgres_diag = var.postgres_source == "external"

  tags = local.common_tags
}

# ── Bastion (optional) ────────────────────────────────────────────────────────
# Jump VM for private AKS cluster access. Uses Azure AD SSH login.
# Enable with: create_bastion = true in terraform.tfvars

module "bastion" {
  count                = var.create_bastion ? 1 : 0
  source               = "./modules/bastion"
  name                 = "langsmith-bastion${local.identifier}"
  resource_group_name  = azurerm_resource_group.resource_group.name
  location             = var.location
  subnet_id            = module.vnet.subnet_bastion_id
  vm_size              = var.bastion_vm_size
  admin_ssh_public_key = var.bastion_admin_ssh_public_key
  allowed_ssh_cidrs    = var.bastion_allowed_ssh_cidrs
  tags                 = local.common_tags

  depends_on = [module.vnet]
}

# ── DNS (optional) ────────────────────────────────────────────────────────────
# Azure DNS zone + A record. Delegates DNS-01 to cert-manager for TLS.
# Enable with: create_dns_zone = true and set langsmith_domain + ingress_ip.

module "dns" {
  count               = var.create_dns_zone ? 1 : 0
  source              = "./modules/dns"
  domain              = var.langsmith_domain
  resource_group_name = azurerm_resource_group.resource_group.name
  ingress_ip          = var.ingress_ip
  tags                = local.common_tags

  # Grant cert-manager DNS Zone Contributor so it can create TXT records
  # for DNS-01 ACME challenges. Only needed when tls_certificate_source = "dns01".
  cert_manager_principal_id = var.tls_certificate_source == "dns01" ? module.aks.cert_manager_identity_principal_id : ""
}
