resource "azurerm_storage_account" "storage_account" {
  name                     = replace(var.storage_account_name, "-", "")
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "container" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.storage_account.id
  container_access_type = "private"
}

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
