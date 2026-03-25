# ══════════════════════════════════════════════════════════════════════════════
# Module: blob
# Purpose: Azure Blob Storage for LangSmith trace data.
#
# LangSmith writes raw trace blobs (inputs/outputs, attachments) to blob storage
# rather than PostgreSQL to keep the database lean. Two TTL tiers:
#   ttl_s/ prefix  — short-lived traces, deleted after 14 days  (default)
#   ttl_l/ prefix  — long-lived  traces, deleted after 400 days (default)
#
# Authentication approach — Workload Identity (no static keys):
#   The User-Assigned Managed Identity and Federated Identity Credentials are
#   created in the k8s-cluster module (which owns the OIDC issuer). This module
#   receives the identity IDs via var.workload_identity_principal_id and
#   var.workload_identity_client_id and grants the identity Storage Blob Data
#   Contributor on this account.
# ══════════════════════════════════════════════════════════════════════════════

# Azure Storage Account — the container for LangSmith trace blobs.
# Storage account names must be globally unique, lowercase alphanumeric, 3-24 chars.
# replace() strips hyphens from the input name to satisfy Azure naming rules.
# Standard LRS: locally-redundant storage — adequate for trace data.
# Upgrade to ZRS or GRS in Stage 3 for higher durability.
resource "azurerm_storage_account" "storage_account" {
  name                     = replace(var.storage_account_name, "-", "")
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS" # Stage 3: consider ZRS or RA-GRS
  tags                     = merge(var.tags, { module = "blob" })
}

# Blob container — private container that holds all LangSmith trace objects.
# Access is private: only the Managed Identity (via Workload Identity) can read/write.
# Objects are organized by prefix: ttl_s/ (short-lived) and ttl_l/ (long-lived).
resource "azurerm_storage_container" "container" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

# Grant the Managed Identity permission to read and write blobs.
# "Storage Blob Data Contributor" allows: read, write, delete blobs.
# Scoped to the storage account (not the container) for flexibility.
# The identity is created in the k8s-cluster module and passed in via variable.
resource "azurerm_role_assignment" "blob_data_contributor" {
  principal_id         = var.workload_identity_principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_account.storage_account.id
}

# Lifecycle management policy — automatic blob deletion based on age and prefix.
# This keeps storage costs bounded without manual cleanup.
#
# Rule "base":    delete ttl_s/* blobs after N days (default: 14)  — traces that
#                 the user hasn't explicitly kept long-term
# Rule "extended": delete ttl_l/* blobs after N days (default: 400) — traces
#                  explicitly marked for long retention (~13 months)
resource "azurerm_storage_management_policy" "lifecycle_policy" {
  count              = var.ttl_enabled ? 1 : 0
  storage_account_id = azurerm_storage_account.storage_account.id

  rule {
    name    = "base"
    enabled = true
    filters {
      prefix_match = ["${var.container_name}/ttl_s"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.ttl_short_days
      }
      snapshot {
        delete_after_days_since_creation_greater_than = var.ttl_short_days
      }
      version {
        delete_after_days_since_creation = var.ttl_short_days
      }
    }
  }

  rule {
    name    = "extended"
    enabled = true
    filters {
      prefix_match = ["${var.container_name}/ttl_l"]
      blob_types   = ["blockBlob"]
    }
    actions {
      base_blob {
        delete_after_days_since_creation_greater_than = var.ttl_long_days
      }
      snapshot {
        delete_after_days_since_creation_greater_than = var.ttl_long_days
      }
      version {
        delete_after_days_since_creation = var.ttl_long_days
      }
    }
  }
}
