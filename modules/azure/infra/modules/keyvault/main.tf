# ══════════════════════════════════════════════════════════════════════════════
# Module: keyvault
# Purpose: Azure Key Vault for centralized secret management.
#
# What this module does:
#   1. Creates a Key Vault with RBAC authorization mode (not legacy access policies).
#   2. Grants the Terraform deployer (current az login identity) the
#      "Key Vault Secrets Officer" role to create and update secrets.
#   3. Grants the LangSmith pod managed identity "Key Vault Secrets User"
#      so K8s pods can read secrets at runtime via Workload Identity.
#   4. Stores the two secrets Terraform already holds in state for another
#      reason: the Postgres admin password and the LangSmith license key.
#      The LangSmith app secrets are seeded post-apply by a script so they
#      never enter Terraform state — see the Secrets section below.
#
# Security properties:
#   • RBAC mode: access controlled by Azure role assignments, not vault-level
#     access policies — auditable, revocable, least-privilege.
#   • Soft delete (90 days): secrets survive accidental deletion.
#   • Purge protection: vault cannot be permanently destroyed until retention
#     period expires — prevents data loss from mistaken `terraform destroy`.
#   • All secrets marked sensitive in Terraform outputs.
#
# First-apply note:
#   Azure RBAC role assignments can take 1–3 minutes to propagate. If secret
#   creation fails with a 403 "ForbiddenByRbac" error on the first apply,
#   run `terraform apply` again — the second apply will succeed.
# ══════════════════════════════════════════════════════════════════════════════

# Current Azure identity running Terraform (az login user or service principal).
# Used to grant the deployer permission to create/update Key Vault secrets.
data "azurerm_client_config" "current" {}

# ── Key Vault ─────────────────────────────────────────────────────────────────

resource "azurerm_key_vault" "langsmith" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # RBAC mode: access controlled by Azure role assignments on this vault's
  # resource ID. Preferred over legacy access policies — more granular and
  # auditable via Azure Activity Log.
  rbac_authorization_enabled = true

  # Soft delete: deleted secrets are retained for this many days before
  # permanent removal. Once set, retention_days cannot be reduced.
  soft_delete_retention_days = var.soft_delete_retention_days

  # Purge protection: vault cannot be immediately destroyed after deletion.
  # Set false for dev environments where you need to quickly destroy and recreate.
  purge_protection_enabled = var.purge_protection_enabled

  # Network ACLs gate the data plane (azurerm_key_vault_secret etc.). Default
  # is "Allow" because both the first apply and seed-keyvault-secrets.sh write
  # secrets via the data plane, and would be 403'd under "Deny" without an
  # operator-supplied IP allowlist. Production deployments override
  # default_action = "Deny" plus allowed_ips / allowed_subnet_ids. AKS pods
  # reach KV via the Microsoft.KeyVault service endpoint on the AKS subnet
  # (see networking module).
  network_acls {
    default_action             = var.network_default_action
    bypass                     = "AzureServices"
    ip_rules                   = var.allowed_ips
    virtual_network_subnet_ids = var.allowed_subnet_ids
  }

  tags = merge(var.tags, { module = "keyvault" })
}

# ── RBAC: Terraform deployer ───────────────────────────────────────────────────
# "Key Vault Secrets Officer" allows: create, read, update, delete, list secrets.
# This grants the person running `terraform apply` full secret management rights.
# For CI/CD pipelines, replace the object_id with a dedicated service principal.

resource "azurerm_role_assignment" "terraform_kv_admin" {
  scope                = azurerm_key_vault.langsmith.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ── RBAC: Pod managed identity ─────────────────────────────────────────────────
# "Key Vault Secrets User" allows: read (get) secrets only.
# LangSmith pods use Workload Identity to assume this managed identity and
# read secrets at runtime — currently used by setup-env.sh, and ready for
# the CSI Secrets Store driver in Phase 2.

resource "azurerm_role_assignment" "managed_identity_kv_reader" {
  scope                = azurerm_key_vault.langsmith.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.managed_identity_principal_id
}

# ── Wait for RBAC propagation ──────────────────────────────────────────────────
# Azure RBAC role assignments propagate within 1–3 minutes. Without this wait
# the first `terraform apply` would fail with 403 when creating secrets.
# Subsequent applies skip this (the role already exists).

resource "time_sleep" "wait_for_rbac" {
  create_duration = "30s"
  depends_on      = [azurerm_role_assignment.terraform_kv_admin]
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Terraform stores only the secrets it already holds in state for another reason:
#
#   postgres-admin-password — Terraform creates the Postgres flexible server with
#                             this value, so it is in state regardless.
#   langsmith-license-key   — consumed by the k8s_bootstrap module to create the
#                             langsmith-license K8s secret.
#
# The LangSmith application secrets (admin password, API key salt, JWT secret,
# and the Fernet encryption keys) are deliberately NOT managed here. Terraform
# would persist them in plaintext in state, so they are written directly to the
# vault by infra/scripts/seed-keyvault-secrets.sh after apply — matching how the
# AWS module writes SSM and the GCP module writes Secret Manager.
#
# Naming convention: kebab-case, matching the TF variable names.
# Scripts read these by name: az keyvault secret show --name <name>

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = var.postgres_admin_password
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "postgres", module = "keyvault" })

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "langsmith_license_key" {
  count        = var.langsmith_license_key != "" ? 1 : 0
  name         = "langsmith-license-key"
  value        = var.langsmith_license_key
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "langsmith", module = "keyvault" })

  depends_on = [time_sleep.wait_for_rbac]
}
