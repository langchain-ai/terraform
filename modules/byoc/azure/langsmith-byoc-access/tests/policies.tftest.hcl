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
  mock_resource "azurerm_policy_definition" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/policyDefinitions/langsmith-byoc-guardrail"
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

run "guardrails_on_each_data_plane" {
  variables {
    data_planes = {
      prod = { location = "eastus" }
      byo  = { location = "eastus", byo_iam = true, reduced_access = true }
    }
  }

  assert {
    condition     = length(azurerm_resource_group_policy_assignment.storage_shared_key_off) == 2 && length(azurerm_resource_group_policy_assignment.federated_credential_issuer) == 2
    error_message = "Every data plane resource group gets both guardrails, in every access mode."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.storage_shared_key_off[0].policy_rule)["if"]["allOf"][1]["notEquals"] == false
    error_message = "The storage guardrail denies any account without allowSharedKeyAccess = false."
  }

  assert {
    condition     = jsondecode(azurerm_policy_definition.federated_credential_issuer[0].policy_rule)["if"]["allOf"][1]["anyOf"][2]["notEquals"] == "00000000-0000-0000-0000-000000000000"
    error_message = "The issuer guardrail pins the tenant of the AKS issuer to this tenant."
  }
}

run "no_guardrails_without_data_planes" {
  variables {
    data_planes = {}
  }

  assert {
    condition     = length(azurerm_policy_definition.storage_shared_key_off) + length(azurerm_policy_definition.federated_credential_issuer) == 0
    error_message = "Without data planes, the module creates no policy definitions."
  }
}
