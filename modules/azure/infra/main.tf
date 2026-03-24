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
  aks_name            = "langsmith-aks${local.identifier}"
  postgres_name       = "langsmith-postgres${local.identifier}"
  redis_name          = "langsmith-redis${local.identifier}"
  blob_name           = "langsmith-blob${local.identifier}" # blob module strips hyphens → "langsmithblobdz"

  # Key Vault name: max 24 chars, globally unique.
  # Uses the user-supplied keyvault_name or derives from identifier.
  keyvault_name = var.keyvault_name != "" ? var.keyvault_name : "langsmith-kv${local.identifier}"

  # Subnet ID resolution: use newly-created VNet subnets OR bring-your-own
  # existing ones (set create_vnet = false and supply the IDs via variables).
  vnet_id            = var.create_vnet ? module.vnet.vnet_id : var.vnet_id
  aks_subnet_id      = var.create_vnet ? module.vnet.subnet_main_id : var.aks_subnet_id
  postgres_subnet_id = var.create_vnet ? module.vnet.subnet_postgres_id : var.postgres_subnet_id
  redis_subnet_id    = var.create_vnet ? module.vnet.subnet_redis_id : var.redis_subnet_id

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

  default_node_pool_vm_size   = var.default_node_pool_vm_size
  default_node_pool_min_count = var.default_node_pool_min_count
  default_node_pool_max_count = var.default_node_pool_max_count
  default_node_pool_max_pods  = var.default_node_pool_max_pods

  # Additional pools (e.g. "large" for ClickHouse / memory-heavy workloads)
  additional_node_pools = var.additional_node_pools

  # Ingress controller: 'nginx' (Helm), 'istio' (Helm), 'istio-addon' (Azure managed), 'none'
  ingress_controller   = var.ingress_controller
  nginx_dns_label      = var.nginx_dns_label
  istio_version        = var.istio_version
  istio_addon_revision = var.istio_addon_revision

  langsmith_namespace    = var.langsmith_namespace
  langsmith_release_name = var.langsmith_release_name

  # Preserve existing identity name when migrating from storage module.
  # New deployments leave this unset and get "${cluster_name}-app-identity".
  workload_identity_name = "k8s-app-identity"

  availability_zones = var.availability_zones

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
  subnet_id           = local.redis_subnet_id
  capacity            = var.redis_capacity # P2 = 13 GB (default)

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

  # The managed identity used by LangSmith pods gets read-only access to
  # all secrets so future CSI-driver integration requires no RBAC changes.
  managed_identity_principal_id = module.blob.k8s_managed_identity_principal_id

  # ── Secrets ─────────────────────────────────────────────────────────────────
  # Values come from TF_VAR_* on first apply. setup-env.sh reads from Key Vault
  # on subsequent applies, eliminating local .secret files.
  postgres_admin_password = var.postgres_admin_password
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

  # Backing services — connection URLs are injected as K8s secrets.
  # generate-secrets.sh also writes these secrets with the full URL from KV.
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? module.postgres[0].connection_url : ""
  postgres_admin_password = var.postgres_source == "external" ? var.postgres_admin_password : ""
  use_external_redis      = var.redis_source == "external"
  redis_connection_url    = var.redis_source == "external" ? module.redis[0].connection_url : ""

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

# ── Front Door (optional) ─────────────────────────────────────────────────────
# Azure Front Door Standard/Premium as the edge layer for LangSmith.
# Provides managed TLS certificates (no cert-manager needed), HTTPS redirect,
# and global CDN acceleration. Works with any ingress controller (nginx, istio).
#
# TLS flow with Front Door:
#   1. Apply → note frontdoor_endpoint_hostname output
#   2. Registrar: CNAME langsmith.<domain> → frontdoor_endpoint_hostname
#   3. Registrar: TXT _dnsauth.langsmith.<domain> → frontdoor_validation_token
#   4. Azure issues managed cert automatically (no re-apply needed)
#
# vs DNS-01 + cert-manager: Front Door is simpler — no cert-manager, no Azure DNS zone needed.
# Enable with: create_frontdoor = true

module "frontdoor" {
  count               = var.create_frontdoor ? 1 : 0
  source              = "./modules/frontdoor"
  name                = "langsmith-fd${local.identifier}"
  resource_group_name = azurerm_resource_group.resource_group.name
  sku_name            = var.frontdoor_sku

  # Set after first apply — get from kubectl get svc
  origin_hostname = var.frontdoor_origin_hostname

  # Customer domain — Front Door issues managed TLS for this
  custom_domain = var.langsmith_domain

  # Optional WAF — requires Premium SKU and create_waf = true
  waf_policy_id = var.create_waf && var.frontdoor_sku == "Premium_AzureFrontDoor" ? module.waf[0].waf_policy_id : ""

  tags = local.common_tags
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
  enable_aks_diag      = true
  enable_keyvault_diag = true
  enable_postgres_diag = var.postgres_source == "external"

  tags = local.common_tags
}

# ── Bastion (optional) ────────────────────────────────────────────────────────
# Jump VM for private AKS cluster access. Uses Azure AD SSH login.
# Enable with: create_bastion = true in terraform.tfvars

module "bastion" {
  count               = var.create_bastion ? 1 : 0
  source              = "./modules/bastion"
  name                = "langsmith-bastion${local.identifier}"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.location
  subnet_id           = module.vnet.subnet_bastion_id
  vm_size             = var.bastion_vm_size
  admin_ssh_public_key = var.bastion_admin_ssh_public_key
  allowed_ssh_cidrs   = var.bastion_allowed_ssh_cidrs
  tags                = local.common_tags

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
