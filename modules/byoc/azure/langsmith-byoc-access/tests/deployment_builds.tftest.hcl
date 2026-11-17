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

run "byo_iam_without_builds" {
  variables {
    data_planes = { prod = { location = "eastus", byo_iam = true } }
  }

  assert {
    condition     = !contains(keys(azurerm_user_assigned_identity.data_plane), "prod/deployment-builds")
    error_message = "Without deployment_builds, the module creates no build identity."
  }

  assert {
    condition     = length(azurerm_role_assignment.deployment_builds_push) + length(azurerm_role_assignment.deployment_builds_kubelet_pull) + length(data.azurerm_resources.deployment_builds_cluster) == 0
    error_message = "Without deployment_builds, the module reads no cluster and grants nothing on the registry."
  }
}

run "byo_iam_with_builds" {
  variables {
    data_planes = { prod = { location = "eastus", byo_iam = true, deployment_builds = true } }
  }

  assert {
    condition     = azurerm_user_assigned_identity.data_plane["prod/deployment-builds"].name == "langsmith-deployment-builds-identity"
    error_message = "The build identity has the name that LangSmith observes."
  }

  assert {
    condition = [for grant in [azurerm_role_assignment.deployment_builds_push["prod"], azurerm_role_assignment.deployment_builds_kubelet_pull["prod"]] : [grant.role_definition_name, grant.principal_id, grant.scope]] == [
      ["AcrPush", "66666666-6666-6666-6666-666666666666", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-byoc-prod"],
      ["AcrPull", "55555555-5555-5555-5555-555555555555", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-byoc-prod"],
    ]
    error_message = "The build identity may push and the kubelet may pull, on the data plane resource group only."
  }

  assert {
    condition = [data.azurerm_resources.deployment_builds_cluster["prod"].resource_group_name, data.azurerm_user_assigned_identity.deployment_builds_kubelet["prod"].name, data.azurerm_user_assigned_identity.deployment_builds_kubelet["prod"].resource_group_name] == [
      "langsmith-byoc-prod", "dp-smith-aks-agentpool", "dp-smith-aks-nodes",
    ]
    error_message = "The module finds the cluster in the data plane resource group and reads its kubelet identity from the node resource group."
  }

  assert {
    condition     = !contains(keys(azurerm_user_assigned_identity.data_plane), "prod/host-backend") && length(azurerm_role_definition.cli_builds_registry) + length(azurerm_role_definition.cli_builds_sources) + length(azurerm_role_assignment.cli_builds_image_delete) == 0
    error_message = "Without cli_builds, the module creates no host-backend identity and no CLI build roles."
  }
}

run "byo_iam_with_cli_builds" {
  variables {
    data_planes = { prod = { location = "eastus", byo_iam = true, deployment_builds = true, cli_builds = true } }
  }

  assert {
    condition     = azurerm_user_assigned_identity.data_plane["prod/host-backend"].name == "langsmith-host-backend-identity"
    error_message = "CLI builds create the host-backend identity that LangSmith observes."
  }

  assert {
    condition = [for grant in [azurerm_role_assignment.cli_builds_registry["prod"], azurerm_role_assignment.cli_builds_image_delete["prod"], azurerm_role_assignment.cli_builds_sources["prod"]] : [grant.principal_id, grant.scope]] == [
      for _ in range(3) : ["66666666-6666-6666-6666-666666666666", "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-byoc-prod"]
    ]
    error_message = "The host-backend identity gets the CLI build grants on the data plane resource group only."
  }

  assert {
    condition     = azurerm_role_assignment.cli_builds_image_delete["prod"].role_definition_name == "AcrDelete"
    error_message = "The host-backend identity may delete images."
  }

  assert {
    condition     = strcontains(azurerm_role_assignment.cli_builds_sources["prod"].condition, "containers:name] StringEquals 'source'")
    error_message = "The source role reaches only the source container."
  }

  assert {
    condition = alltrue([for action in one(azurerm_role_definition.cli_builds_registry["prod"].permissions).actions : startswith(action, "Microsoft.ContainerRegistry/registries/")]) && one(azurerm_role_definition.cli_builds_sources["prod"].permissions).actions == tolist([
      "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action",
    ])
    error_message = "The CLI build roles hold registry token actions and the user delegation key action only."
  }

  assert {
    condition     = length(azurerm_role_assignment.host_backend_observability) == 2 && length(azurerm_role_assignment.host_backend_dedicated_deployments) == 0
    error_message = "The host-backend identity reads deployment observability, without the dedicated deployments role."
  }
}

run "cli_builds_without_deployment_builds" {
  command = plan

  variables {
    data_planes = { prod = { location = "eastus", byo_iam = true, cli_builds = true } }
  }

  expect_failures = [var.data_planes]
}

run "builds_without_byo_iam" {
  variables {
    data_planes = { prod = { location = "eastus", deployment_builds = true } }
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.data_plane) + length(azurerm_role_assignment.deployment_builds_push) + length(azurerm_role_assignment.deployment_builds_kubelet_pull) == 0
    error_message = "Without byo_iam, LangSmith creates the build identity and grants, so the module creates none."
  }
}

run "builds_before_the_cluster" {
  command = plan

  variables {
    data_planes = { prod = { location = "eastus", byo_iam = true, deployment_builds = true } }
  }

  override_data {
    target = data.azurerm_resources.deployment_builds_cluster["prod"]
    values = {
      resources = []
    }
  }

  expect_failures = [data.azurerm_resources.deployment_builds_cluster["prod"]]
}
