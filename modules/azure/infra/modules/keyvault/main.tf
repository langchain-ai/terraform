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
  count = var.create_keyvault ? 1 : 0

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

# ── Bring-your-own Key Vault ───────────────────────────────────────────────────
# Read-only lookup of a customer-owned vault (create_keyvault = false). Never
# creates or modifies it: the vault's auth mode, network rules, and retention
# settings belong to whoever provisioned it, so every var this module would
# otherwise apply to those settings is ignored on this path.

data "azurerm_key_vault" "existing" {
  count = var.create_keyvault ? 0 : 1

  name                = var.existing_keyvault_name
  resource_group_name = var.existing_keyvault_resource_group_name

  lifecycle {
    precondition {
      condition     = var.existing_keyvault_name != ""
      error_message = "create_keyvault = false requires existing_keyvault_name to be set to the name of the Key Vault to attach to."
    }

    precondition {
      condition     = var.existing_keyvault_resource_group_name != ""
      error_message = "create_keyvault = false requires existing_keyvault_resource_group_name to be set to the resource group holding Key Vault '${var.existing_keyvault_name}'. Find it with: az keyvault show --name ${var.existing_keyvault_name} --query resourceGroup -o tsv"
    }

    postcondition {
      condition     = self.rbac_authorization_enabled || !(var.manage_terraform_admin_assignment || var.manage_managed_identity_assignment)
      error_message = "Key Vault '${var.existing_keyvault_name}' uses access policies, not Azure RBAC, so the role assignments this module creates would grant nothing while the apply still succeeded. Either set keyvault_manage_terraform_admin_assignment = false and keyvault_manage_managed_identity_assignment = false and have the vault owner grant access with an access policy, or supply a vault with RBAC authorization enabled."
    }
  }
}

locals {
  # One vault, reached two ways. Only one of the two ever has an instance, so
  # the [0] index is always the live one.
  vault_id   = var.create_keyvault ? azurerm_key_vault.langsmith[0].id : data.azurerm_key_vault.existing[0].id
  vault_name = var.create_keyvault ? azurerm_key_vault.langsmith[0].name : data.azurerm_key_vault.existing[0].name
  vault_uri  = var.create_keyvault ? azurerm_key_vault.langsmith[0].vault_uri : data.azurerm_key_vault.existing[0].vault_uri
}

# ── RBAC: Terraform deployer ───────────────────────────────────────────────────
# "Key Vault Secrets Officer" allows: create, read, update, delete, list secrets.
# This grants the person running `terraform apply` full secret management rights.
# For CI/CD pipelines, replace the object_id with a dedicated service principal.
#
# principal_type is a variable here, unlike the managed-identity grant below:
# this principal is a user for an interactive `az login` and a service principal
# in CI, so no literal is correct for both. Null (the default) omits the field
# and lets Azure infer it — see var.terraform_principal_type.
#
# Skipped by default on a customer-owned vault, where creating it means calling
# Microsoft.Authorization/roleAssignments/write against a resource the platform
# team owns — the call such a team most often denies. The deployer exists before
# apply starts and Azure RBAC inherits downward, so that team can grant this
# role at the vault or its resource group ahead of time instead.
#
# Gated separately from the managed-identity grant below, because a subscription
# that delegates roleAssignments/write through an ABAC condition on principalType
# rejects this request and permits that one. Set terraform_principal_type first;
# turning the assignment off is what gets a deployment through when the grant has
# to be made out of band anyway.

resource "azurerm_role_assignment" "terraform_kv_admin" {
  count = var.manage_terraform_admin_assignment ? 1 : 0

  scope                = local.vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
  principal_type       = var.terraform_principal_type
}

# ── RBAC: Pod managed identity ─────────────────────────────────────────────────
# "Key Vault Secrets User" allows: read (get) secrets only.
#
# principal_type is set explicitly: subscriptions that delegate roleAssignments/write
# with an ABAC condition on principalType return 403 when the request omits it.
#
# Nobody can pre-grant this one: the identity is created by the k8s-cluster
# module partway through the same apply, so there is no object ID to grant to
# beforehand. Skipping it on a customer-owned vault costs nothing today, because
# no runtime path reads the vault — create-k8s-secrets.sh reads it with the
# operator's own credentials and writes a Kubernetes Secret, and there is no
# SecretProviderClass in the tree. Wiring up the CSI Secrets Store driver later
# would need this grant, and on a customer-owned vault that means asking the
# vault owner for it.

resource "azurerm_role_assignment" "managed_identity_kv_reader" {
  count = var.manage_managed_identity_assignment ? 1 : 0

  scope                = local.vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.managed_identity_principal_id
  principal_type       = "ServicePrincipal"
}

# ── Wait for RBAC propagation ──────────────────────────────────────────────────
# Azure RBAC role assignments propagate within 1–3 minutes. Without this wait
# the first `terraform apply` would fail with 403 when creating secrets.
# Subsequent applies skip this (the role already exists).
#
# Only the deployer's grant is worth waiting on, because the secret writes below
# are what would 403 without it. The managed-identity grant is read at runtime by
# pods that start long after this apply, and an access grant that came from
# outside this apply propagated long ago. manage_secrets = false leaves no
# writes to wait for either way.

resource "time_sleep" "wait_for_rbac" {
  count = var.manage_terraform_admin_assignment && var.manage_secrets ? 1 : 0

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
# var.manage_secrets = false writes neither, for a deployer with no Key Vault
# data-plane access; seed-keyvault-secrets.sh writes all nine afterwards.
# Flipping it on a live deployment deletes both from the vault — `terraform
# state rm` them first. See PERMISSIONS.md.
#
# Naming convention: kebab-case, matching the TF variable names.
# Scripts read these by name: az keyvault secret show --name <name>

resource "azurerm_key_vault_secret" "postgres_admin_password" {
  count = var.manage_secrets ? 1 : 0

  name         = "postgres-admin-password"
  value        = var.postgres_admin_password
  key_vault_id = local.vault_id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "postgres", module = "keyvault" })

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "langsmith_license_key" {
  count        = var.manage_secrets && var.langsmith_license_key != "" ? 1 : 0
  name         = "langsmith-license-key"
  value        = var.langsmith_license_key
  key_vault_id = local.vault_id
  content_type = "text/plain"
  tags         = merge(var.tags, { component = "langsmith", module = "keyvault" })

  depends_on = [time_sleep.wait_for_rbac]
}
