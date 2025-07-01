locals {
  service_accounts_for_workload_identity = [
    "${var.langsmith_release_name}-platform-backend",
    "${var.langsmith_release_name}-queue",
    "${var.langsmith_release_name}-backend",
  ]
}

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

resource "azurerm_user_assigned_identity" "k8s_app" {
  name                = "k8s-app-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  principal_id         = azurerm_user_assigned_identity.k8s_app.principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_account.storage_account.id
}

resource "azurerm_federated_identity_credential" "k8s_app" {
  for_each = toset(local.service_accounts_for_workload_identity)

  name                = "langsmith-federated-${each.value}"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.k8s_app.id

  audience = [
    "api://AzureADTokenExchange"
  ]

  issuer  = var.aks_oidc_issuer_url
  subject = "system:serviceaccount:${var.langsmith_namespace}:${each.value}"
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
