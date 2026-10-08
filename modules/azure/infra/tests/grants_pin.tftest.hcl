# Who creates the control-plane identity and who makes its grants, pinned when
# the cluster is created. The pin lives in state, so these runs apply against
# mocked providers and plan the changes that follow, in order. They sit apart
# from private_entra.tftest.hcl, whose plans assume an empty state. After the
# first apply, each run stubs the subscription's cluster list with the cluster
# the module manages, running as the identity the module created.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  # Role assignment reads and grants validate the principal as a UUID.
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      principal_id = "66666666-6666-6666-6666-666666666666"
    }
  }
  # The runs parse the IDs of the network, the cluster, and the identity it runs
  # as.
  mock_resource "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/virtualNetworks/ls-vnet-test/subnets/main"
    }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/virtualNetworks/ls-vnet-test"
    }
  }
  # Teardown at Terraform 1.11 evaluates the outputs, which index the cluster's
  # kube_config and parse the resource group's ID.
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      kube_config = [{
        host                   = "https://ls-aks-test.example.invalid:443"
        client_certificate     = "Zml4dHVyZQ=="
        client_key             = "Zml4dHVyZQ=="
        cluster_ca_certificate = "Zml4dHVyZQ=="
        username               = "fixture"
        password               = "fixture"
      }]
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test"
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane"
      principal_id = "66666666-6666-6666-6666-666666666666"
    }
  }
}
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [] }
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id            = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password    = "fixture-not-a-real-secret-Aa1"
  resource_group_name        = "ls-rg-test"
  cluster_name               = "ls-aks-test"
  aks_control_plane_identity = "user"

  # The ID of the identity the module creates, as Azure reports it.
  fixture_created_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane"
}

run "the_first_apply_pins_a_created_identity_and_managed_grants" {
  command = apply

  plan_options {
    target = [terraform_data.aks_grants_pin]
  }

  assert {
    condition     = terraform_data.aks_grants_pin[0].output.mode == { create_identity = true, manage_grants = true }
    error_message = "The pin did not record the setting the cluster was created with"
  }
}

run "an_unchanged_setting_plans_clean" {
  command = plan

  plan_options {
    target = [terraform_data.aks_access_guard]
  }

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }
}

# The identity guard sees the same ID, while the module would destroy the
# identity it created.
run "supplying_the_identity_the_module_created_is_refused" {
  command = plan

  plan_options {
    target = [terraform_data.aks_access_guard]
  }

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity_id = var.fixture_created_identity_id
  }

  expect_failures = [terraform_data.aks_access_guard]
}

# The way through: after the state moves the error message names, -replace
# records the new setting.
run "replacing_the_pin_records_a_supplied_identity" {
  command = apply

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity_id = var.fixture_created_identity_id
  }

  plan_options {
    target  = [terraform_data.aks_grants_pin]
    replace = [terraform_data.aks_grants_pin[0]]
  }

  assert {
    condition     = terraform_data.aks_grants_pin[0].output.mode == { create_identity = false, manage_grants = true }
    error_message = "-replace did not record the new setting"
  }
}

# The grant check passes here, as it would against Azure: it reads the module's
# grants, which the apply would then delete.
run "leaving_the_grants_to_the_owner_is_refused" {
  command = plan

  plan_options {
    target = [terraform_data.aks_access_guard]
  }

  override_data {
    target = module.aks.data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/virtualNetworks/ls-vnet-test/subnets/main"
      }]
    }
  }

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity_id            = var.fixture_created_identity_id
    aks_control_plane_identity_manage_grants = false
  }

  expect_failures = [terraform_data.aks_access_guard]
}

run "replacing_the_pin_records_grants_left_to_the_owner" {
  command = apply

  plan_options {
    target  = [terraform_data.aks_grants_pin]
    replace = [terraform_data.aks_grants_pin[0]]
  }

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }
  override_data {
    target = module.aks.data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/virtualNetworks/ls-vnet-test/subnets/main"
      }]
    }
  }

  variables {
    aks_control_plane_identity_id            = var.fixture_created_identity_id
    aks_control_plane_identity_manage_grants = false
  }

  assert {
    condition     = terraform_data.aks_grants_pin[0].output.mode == { create_identity = false, manage_grants = false }
    error_message = "-replace did not record the new setting"
  }
}

# The module would create grants the owner already made, which Azure rejects.
run "taking_over_the_owners_grants_is_refused" {
  command = plan

  plan_options {
    target = [terraform_data.aks_access_guard]
  }

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = null
          private_dns_zone = null
          entra            = null
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity_id            = var.fixture_created_identity_id
    aks_control_plane_identity_manage_grants = true
  }

  expect_failures = [terraform_data.aks_access_guard]
}
