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
#   4. Stores all LangSmith secrets: passwords, salts, JWT secret, and
#      Fernet encryption keys for optional features.
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
# All sensitive values stored here survive rotation: each secret has full
# version history, audit log, and can be read by any authorized principal
# (setup-env.sh, CI/CD pipelines, future CSI driver).
#
# Naming convention: kebab-case, matching the TF variable names.
# setup-env.sh reads these by name: az keyvault secret show --name <name>

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  name         = "postgres-admin-password"
  value        = var.postgres_admin_password
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "postgres", module = "keyvault" })

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "langsmith_api_key_salt" {
  name         = "langsmith-api-key-salt"
  value        = var.langsmith_api_key_salt
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"

  # CRITICAL: Changing this value invalidates ALL existing LangSmith API keys.
  # The lifecycle ignore_changes ensures Terraform never updates this after creation
  # even if the variable value changes. Rotate only deliberately via the CLI:
  #   az keyvault secret set --vault-name <vault> --name langsmith-api-key-salt --value <new>
  lifecycle {
    ignore_changes = [value]
  }

  tags       = merge(var.tags, { component = "langsmith", stability = "critical", module = "keyvault" })
  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "langsmith_jwt_secret" {
  name         = "langsmith-jwt-secret"
  value        = var.langsmith_jwt_secret
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"

  # CRITICAL: Changing this invalidates all active LangSmith user sessions.
  lifecycle {
    ignore_changes = [value]
  }

  tags       = merge(var.tags, { component = "langsmith", stability = "critical", module = "keyvault" })
  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "langsmith_admin_password" {
  count        = var.langsmith_admin_password != "" ? 1 : 0
  name         = "langsmith-admin-password"
  value        = var.langsmith_admin_password
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "langsmith", module = "keyvault" })

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

resource "azurerm_key_vault_secret" "deployments_encryption_key" {
  count        = var.langsmith_deployments_encryption_key != "" ? 1 : 0
  name         = "langsmith-deployments-encryption-key"
  value        = var.langsmith_deployments_encryption_key
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"

  # CRITICAL: Changing this key corrupts all encrypted LangGraph deployment data.
  lifecycle {
    ignore_changes = [value]
  }

  tags       = merge(var.tags, { component = "deployments", stability = "critical", module = "keyvault" })
  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "agent_builder_encryption_key" {
  count        = var.langsmith_agent_builder_encryption_key != "" ? 1 : 0
  name         = "langsmith-agent-builder-encryption-key"
  value        = var.langsmith_agent_builder_encryption_key
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"

  lifecycle {
    ignore_changes = [value]
  }

  tags       = merge(var.tags, { component = "agent-builder", stability = "critical", module = "keyvault" })
  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "insights_encryption_key" {
  count        = var.langsmith_insights_encryption_key != "" ? 1 : 0
  name         = "langsmith-insights-encryption-key"
  value        = var.langsmith_insights_encryption_key
  key_vault_id = azurerm_key_vault.langsmith.id
  content_type = "text/plain"

  lifecycle {
    ignore_changes = [value]
  }

  tags       = merge(var.tags, { component = "insights", stability = "critical", module = "keyvault" })
  depends_on = [time_sleep.wait_for_rbac]
}
