# Apply tests with mocked providers: no credentials and no state. Run with
# terraform init -backend=false && terraform test in the module directory.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_data "azurerm_resources" {
    defaults = {
      resources = [{ name = "dp-smith-aks" }]
    }
  }
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      principal_id = "55555555-5555-5555-5555-555555555555"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-byoc-prod"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-byoc-prod/providers/Microsoft.KeyVault/vaults/ls-prod-abcdef"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      principal_id = "66666666-6666-6666-6666-666666666666"
    }
  }
  mock_resource "azurerm_role_definition" {
    defaults = {
      role_definition_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/77777777-7777-7777-7777-777777777777"
    }
  }
}

mock_provider "azuread" {
  mock_resource "azuread_service_principal" {
    defaults = {
      object_id = "88888888-8888-8888-8888-888888888888"
    }
  }
}

mock_provider "random" {}

variables {
  langsmith_app_client_id = "5b0a74cb-9f37-4797-b557-c15d7be80d3b"
  external_id             = "external-id"
}

run "full_access_conditions_user_access_administrator" {


  variables {
    data_planes = { prod = { location = "eastus" } }
  }

  assert {
    condition     = azurerm_role_assignment.langsmith_user_access_administrator["prod"].condition_version == "2.0"
    error_message = "The User Access Administrator assignment uses an ABAC condition."
  }

  assert {
    condition = alltrue([
      for id in [
        "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
        "b24988ac-6180-42a0-ab88-20f7382dd24c",
        "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
        "f58310d9-a9f6-439a-9e8d-f62e7b41a168",
        "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b",
        "88888888-8888-8888-8888-888888888888",
      ] : strcontains(azurerm_role_assignment.langsmith_user_access_administrator["prod"].condition, id)
    ])
    error_message = "The condition blocks the privileged roles and limits LangSmith self-assignment to AKS RBAC Cluster Admin."
  }
}

run "no_user_access_administrator_with_byo_iam_or_reduced_access" {


  variables {
    data_planes = {
      byo     = { location = "eastus", byo_iam = true }
      reduced = { location = "eastus", reduced_access = true }
    }
  }

  assert {
    condition     = length(azurerm_role_assignment.langsmith_user_access_administrator) == 0
    error_message = "byo_iam and reduced_access give LangSmith no User Access Administrator."
  }
}
