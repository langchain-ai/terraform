# Private API server, Entra-only access, and a user-assigned control-plane
# identity. The first runs plan the cluster module itself and read what it
# would create through module.aks.access_profile and module.aks.entra_auth. The
# variable rules each get a run of their own, since expect_failures names the
# variable and not the rule. The remaining runs stub the subscription's cluster
# list with a cluster of this name in this resource group, which the module
# reads as the cluster it manages: terraform_data.aks_access_guard compares the
# requested access with it, and the providers follow its Entra setting.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# The cluster module lists the subscription's AKS clusters to read the one it
# manages; the generated mock has no such shape, so give it an empty list.
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
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
  resource_group_name     = "ls-rg-test"
  cluster_name            = "ls-aks-test"

  # Fixture IDs, not real resources.
  fixture_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-control-plane"
  fixture_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.usgovvirginia.cx.aks.containerservice.azure.us"
  fixture_group_id    = "55555555-5555-5555-5555-555555555555"
}

# ── What the cluster is planned with ─────────────────────────────────────────

run "defaults_plan_a_public_cluster_with_local_accounts_and_a_system_identity" {
  command = plan

  assert {
    condition     = module.aks.access_profile.private_cluster_enabled == false && module.aks.access_profile.private_dns_zone_id == null
    error_message = "With every flag off, the cluster was planned with a private API server"
  }
  assert {
    condition     = module.aks.access_profile.local_account_disabled == null && module.aks.access_profile.azure_rbac_enabled == false
    error_message = "With aks_entra_only off, the cluster was planned with Entra integration or local accounts disabled"
  }
  assert {
    condition     = module.aks.access_profile.identity_type == "SystemAssigned" && module.aks.access_profile.identity_ids == null
    error_message = "With aks_cluster_identity_id empty, the control plane was not planned with a system-assigned identity"
  }
  assert {
    condition     = module.aks.entra_auth == false
    error_message = "With aks_entra_only off, the providers were set to authenticate through kubelogin"
  }
}

run "a_private_cluster_defaults_to_the_system_dns_zone" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
  }

  assert {
    condition     = module.aks.access_profile.private_cluster_enabled == true
    error_message = "aks_private_cluster_enabled = true did not plan a private API server"
  }
  assert {
    condition     = module.aks.access_profile.private_dns_zone_id == "System"
    error_message = "A private cluster with aks_private_dns_zone_id empty was not planned with the System zone"
  }
}

run "a_private_cluster_takes_a_zone_it_does_not_own" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = "None"
  }

  assert {
    condition     = module.aks.access_profile.private_dns_zone_id == "None"
    error_message = "aks_private_dns_zone_id = \"None\" did not reach the cluster"
  }
}

run "a_private_cluster_registers_in_a_supplied_zone_as_the_supplied_identity" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = var.fixture_dns_zone_id
    aks_cluster_identity_id     = var.fixture_identity_id
  }

  assert {
    condition     = module.aks.access_profile.private_dns_zone_id == var.fixture_dns_zone_id
    error_message = "A supplied aks_private_dns_zone_id did not reach the cluster"
  }
  assert {
    condition     = module.aks.access_profile.identity_type == "UserAssigned" && module.aks.access_profile.identity_ids == toset([var.fixture_identity_id])
    error_message = "aks_cluster_identity_id did not plan a user-assigned control-plane identity"
  }
}

run "a_user_assigned_identity_alone_leaves_the_api_server_public" {
  command = plan

  variables {
    aks_cluster_identity_id = var.fixture_identity_id
  }

  assert {
    condition     = module.aks.access_profile.identity_type == "UserAssigned" && module.aks.access_profile.private_cluster_enabled == false
    error_message = "aks_cluster_identity_id alone did not plan a public cluster with a user-assigned identity"
  }
}

run "entra_only_plans_azure_rbac_and_disables_local_accounts" {
  command = plan

  variables {
    aks_entra_only                   = true
    aks_entra_admin_group_object_ids = [var.fixture_group_id]
  }

  assert {
    condition     = module.aks.access_profile.local_account_disabled == true
    error_message = "aks_entra_only = true did not disable local accounts"
  }
  assert {
    condition     = module.aks.access_profile.azure_rbac_enabled == true && toset(module.aks.access_profile.admin_group_object_ids) == toset([var.fixture_group_id])
    error_message = "aks_entra_only = true did not plan Entra integration with Azure RBAC and the admin group"
  }
  assert {
    condition     = module.aks.entra_auth == true
    error_message = "aks_entra_only = true on a new cluster did not switch the providers to kubelogin"
  }
}

# ── Variable rules ───────────────────────────────────────────────────────────

run "a_private_cluster_refuses_authorized_ip_ranges" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
    aks_authorized_ip_ranges    = ["203.0.113.0/24"]
  }

  expect_failures = [var.aks_private_cluster_enabled]
}

run "a_dns_zone_without_a_private_cluster_is_refused" {
  command = plan

  variables {
    aks_private_dns_zone_id = "System"
  }

  expect_failures = [var.aks_private_dns_zone_id]
}

run "a_dns_zone_that_is_not_a_zone_id_is_refused" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = "privatelink.eastus.azmk8s.io"
    aks_cluster_identity_id     = var.fixture_identity_id
  }

  expect_failures = [var.aks_private_dns_zone_id]
}

run "a_supplied_dns_zone_without_a_user_assigned_identity_is_refused" {
  command = plan

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = var.fixture_dns_zone_id
  }

  expect_failures = [var.aks_private_dns_zone_id]
}

run "admin_groups_without_entra_only_are_refused" {
  command = plan

  variables {
    aks_entra_admin_group_object_ids = [var.fixture_group_id]
  }

  expect_failures = [var.aks_entra_admin_group_object_ids]
}

run "an_admin_group_that_is_not_a_guid_is_refused" {
  command = plan

  variables {
    aks_entra_only                   = true
    aks_entra_admin_group_object_ids = ["aks-admins"]
  }

  expect_failures = [var.aks_entra_admin_group_object_ids]
}

run "a_cluster_identity_that_is_not_a_user_assigned_identity_is_refused" {
  command = plan

  variables {
    aks_cluster_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.Network/virtualNetworks/not-an-identity"
  }

  expect_failures = [var.aks_cluster_identity_id]
}

# ── An existing cluster ──────────────────────────────────────────────────────

run "the_live_access_plans_clean" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = true
          private_dns_zone = "system"
          entra            = true
        }]
      }
    }
  }

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = "System"
    aks_entra_only              = true
  }
}

run "making_an_existing_cluster_private_is_refused" {
  command = plan

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
        }]
      }
    }
  }

  variables {
    aks_private_cluster_enabled = true
  }

  expect_failures = [terraform_data.aks_access_guard]
}

run "making_an_existing_private_cluster_public_is_refused" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = true
          private_dns_zone = "system"
          entra            = null
        }]
      }
    }
  }

  expect_failures = [terraform_data.aks_access_guard]
}

run "moving_an_existing_private_cluster_to_another_zone_is_refused" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = true
          private_dns_zone = "system"
          entra            = null
        }]
      }
    }
  }

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = var.fixture_dns_zone_id
    aks_cluster_identity_id     = var.fixture_identity_id
  }

  expect_failures = [terraform_data.aks_access_guard]
}

# Azure returns the zone ID in its own casing, which need not match tfvars.
run "the_supplied_zone_in_another_case_plans_clean" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name             = "ls-aks-test"
          dataplane        = "azure"
          policy           = "azure"
          private          = true
          private_dns_zone = "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/dns-rg/providers/microsoft.network/privatednszones/privatelink.usgovvirginia.cx.aks.containerservice.azure.us"
          entra            = null
        }]
      }
    }
  }

  variables {
    aks_private_cluster_enabled = true
    aks_private_dns_zone_id     = var.fixture_dns_zone_id
    aks_cluster_identity_id     = var.fixture_identity_id
  }
}

run "turning_entra_off_is_refused" {
  command = plan

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
          entra            = true
        }]
      }
    }
  }

  expect_failures = [terraform_data.aks_access_guard]
}

# Azure turns Entra integration on in place, so the guard lets it through, and
# the providers keep the certificate the cluster accepts until it has.
run "turning_entra_on_for_an_existing_cluster_keeps_the_certificate_for_now" {
  command = plan

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
        }]
      }
    }
  }

  variables {
    aks_entra_only = true
  }

  assert {
    condition     = module.aks.entra_auth == false
    error_message = "Turning Entra on for an existing cluster switched the providers to kubelogin before the cluster takes Entra tokens"
  }
}

run "providers_use_kubelogin_once_the_cluster_takes_entra" {
  command = plan

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
          entra            = true
        }]
      }
    }
  }

  variables {
    aks_entra_only = true
  }

  assert {
    condition     = module.aks.entra_auth == true
    error_message = "A cluster that already takes Entra tokens did not switch the providers to kubelogin"
  }
}
