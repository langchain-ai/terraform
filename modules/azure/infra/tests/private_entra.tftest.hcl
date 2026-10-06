# Private API server, Entra-only access, and a user-assigned control-plane
# identity. The first runs plan the cluster module itself and read what it
# would create through module.aks.access_profile and module.aks.kube_auth. The
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
  # Role assignment reads and grants validate the principal as a UUID.
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      principal_id = "66666666-6666-6666-6666-666666666666"
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
  fixture_vnet_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"

  fixture_route_table_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/route-rg/providers/Microsoft.Network/routeTables/egress"
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
    error_message = "With aks_control_plane_identity at its default, the control plane was not planned with a system-assigned identity"
  }
  assert {
    condition     = module.aks.kube_auth == "certificate"
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
    aks_private_cluster_enabled   = true
    aks_private_dns_zone_id       = var.fixture_dns_zone_id
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
  }

  assert {
    condition     = module.aks.access_profile.private_dns_zone_id == var.fixture_dns_zone_id
    error_message = "A supplied aks_private_dns_zone_id did not reach the cluster"
  }
  assert {
    condition     = module.aks.access_profile.identity_type == "UserAssigned" && module.aks.access_profile.identity_ids == toset([var.fixture_identity_id])
    error_message = "aks_control_plane_identity_id did not plan a user-assigned control-plane identity"
  }
}

run "a_user_assigned_identity_alone_leaves_the_api_server_public" {
  command = plan

  variables {
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
  }

  assert {
    condition     = module.aks.access_profile.identity_type == "UserAssigned" && module.aks.access_profile.private_cluster_enabled == false
    error_message = "aks_control_plane_identity_id alone did not plan a public cluster with a user-assigned identity"
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
    condition     = module.aks.kube_auth == "entra"
    error_message = "aks_entra_only = true on a new cluster did not switch the providers to kubelogin"
  }
}

# ── The user-assigned control-plane identity and its grants ──────────────────
# The grants' scopes are known at plan only on a supplied VNet, so the runs that
# check them supply one.

run "a_user_identity_is_created_and_granted_on_the_subnet_the_module_builds" {
  command = plan

  variables {
    aks_control_plane_identity = "user"
  }

  assert {
    condition     = module.aks.access_profile.identity_type == "UserAssigned"
    error_message = "aks_control_plane_identity = \"user\" did not plan a user-assigned control-plane identity"
  }
  assert {
    condition     = module.aks.control_plane_identity.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane"
    error_message = "With aks_control_plane_identity_id empty, the module did not create <cluster>-control-plane in the deployment group"
  }
  assert {
    condition     = length(module.aks.control_plane_grants) == 1 && module.aks.control_plane_grants[0].role == "Network Contributor"
    error_message = "On a VNet the module builds, the control-plane identity was not granted Network Contributor alone"
  }
}

run "grants_on_a_supplied_network_land_on_the_vnet_and_the_dns_zone" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = [] }
  }

  variables {
    create_vnet                              = false
    vnet_id                                  = var.fixture_vnet_id
    aks_service_cidr                         = "172.20.0.0/16"
    aks_private_cluster_enabled              = true
    aks_private_dns_zone_id                  = var.fixture_dns_zone_id
    aks_control_plane_identity               = "user"
    aks_control_plane_identity_id            = var.fixture_identity_id
    aks_control_plane_identity_manage_grants = true
  }

  assert {
    condition = toset(module.aks.control_plane_grants) == toset([
      { role = "Network Contributor", scope = var.fixture_vnet_id },
      { role = "Private DNS Zone Contributor", scope = var.fixture_dns_zone_id },
    ])
    error_message = "The control-plane grants were not planned on the supplied VNet and DNS zone"
  }
}

# Without a zone of its own, the node subnet is the scope, and the cluster
# waits for the grant to take effect.
run "managed_grants_land_on_the_subnet_and_hold_the_cluster_back" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  variables {
    location                  = "eastus"
    subnet_id                 = "${var.fixture_vnet_id}/subnets/aks"
    vnet_id                   = var.fixture_vnet_id
    control_plane_identity    = "user"
    control_plane_identity_id = var.fixture_identity_id
  }

  assert {
    condition     = output.control_plane_grants == [{ role = "Network Contributor", scope = "${var.fixture_vnet_id}/subnets/aks" }]
    error_message = "Without a supplied zone, Network Contributor was not planned on the node subnet alone"
  }
  assert {
    condition     = length(time_sleep.control_plane_grant_propagation) == 1
    error_message = "Managed grants did not plan the propagation wait ahead of the cluster"
  }
}

run "a_supplied_network_without_the_grants_is_refused" {
  command = plan

  # The check is a precondition on the cluster, which expect_failures reaches
  # only from the cluster module itself.
  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = { role_assignments = [] }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    vnet_id                              = var.fixture_vnet_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  expect_failures = [azurerm_kubernetes_cluster.main]
}

# A grant on the node subnet covers the network, but not the zone.
run "a_supplied_zone_without_its_grant_is_refused" {
  command = plan

  # The check is a precondition on the cluster, which expect_failures reaches
  # only from the cluster module itself.
  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
      }]
    }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    vnet_id                              = var.fixture_vnet_id
    private_cluster_enabled              = true
    private_dns_zone_id                  = var.fixture_dns_zone_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  expect_failures = [azurerm_kubernetes_cluster.main]
}

# A grant on the node subnet does not cover the subnet's route table, which sits
# in a resource group of its own.
run "a_route_table_without_its_grant_is_refused" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
      }]
    }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    subnet_route_table_id                = var.fixture_route_table_id
    vnet_id                              = var.fixture_vnet_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  expect_failures = [azurerm_kubernetes_cluster.main]
}

run "a_subnet_grant_and_a_route_table_grant_pass" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [
        {
          role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
          role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
        },
        {
          role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
          role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/route-rg/providers/Microsoft.Network/routeTables/egress"
        },
      ]
    }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    subnet_route_table_id                = var.fixture_route_table_id
    vnet_id                              = var.fixture_vnet_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.main) == 1 && contains(keys(data.azurerm_role_assignments.control_plane), "route_table")
    error_message = "A subnet grant and a route table grant did not satisfy the check, or the route table was not checked"
  }
}

# A zone its owner linked to the VNet leaves AKS nothing to do there, so a
# subnet grant and a zone grant are enough, with no role on the VNet. The
# override answers both checks, and each keeps the grant at or above its scope.
run "a_subnet_grant_and_a_zone_grant_pass_with_a_supplied_zone" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [
        {
          role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
          role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
        },
        {
          role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f"
          role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.usgovvirginia.cx.aks.containerservice.azure.us"
        },
      ]
    }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    vnet_id                              = var.fixture_vnet_id
    private_cluster_enabled              = true
    private_dns_zone_id                  = var.fixture_dns_zone_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.main) == 1
    error_message = "A subnet grant and a zone grant did not satisfy the check with a supplied zone"
  }
}

# Any role counts, so a custom one on the node subnet passes.
run "a_custom_role_on_the_subnet_passes_the_check" {
  command = plan

  module {
    source = "./modules/k8s-cluster"
  }

  override_data {
    target = data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/77777777-7777-7777-7777-777777777777"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
      }]
    }
  }

  variables {
    location                             = "eastus"
    subnet_id                            = "${var.fixture_vnet_id}/subnets/aks"
    vnet_id                              = var.fixture_vnet_id
    control_plane_identity               = "user"
    control_plane_identity_id            = var.fixture_identity_id
    control_plane_identity_manage_grants = false
  }

  assert {
    condition     = length(azurerm_kubernetes_cluster.main) == 1 && length(time_sleep.control_plane_grant_propagation) == 0
    error_message = "A custom role on the node subnet did not satisfy the check, or the owner's grants planned a wait"
  }
}

# A grant at the VNet's resource group covers the VNet, in Azure's casing.
run "a_supplied_network_with_the_grants_plans_none_of_its_own" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = [] }
  }
  override_data {
    target = module.aks.data.azurerm_role_assignments.control_plane
    values = {
      role_assignments = [{
        role_definition_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7"
        role_assignment_scope = "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/network-rg"
      }]
    }
  }

  variables {
    create_vnet                   = false
    vnet_id                       = var.fixture_vnet_id
    aks_service_cidr              = "172.20.0.0/16"
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
  }

  assert {
    condition     = length(module.aks.control_plane_grants) == 0
    error_message = "With the grants left to the network's owner, the module planned grants of its own"
  }
}

# The module's own identity has no principal until it is created, so its grants
# could only be checked partway through the apply.
run "a_new_identity_on_a_network_whose_owner_grants_it_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = [] }
  }

  variables {
    create_vnet                = false
    vnet_id                    = var.fixture_vnet_id
    aks_service_cidr           = "172.20.0.0/16"
    aks_control_plane_identity = "user"
  }

  expect_failures = [var.aks_control_plane_identity_id]
}

run "a_new_identity_on_a_supplied_network_is_allowed_when_terraform_grants_it" {
  command = plan

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = [] }
  }

  variables {
    create_vnet                              = false
    vnet_id                                  = var.fixture_vnet_id
    aks_service_cidr                         = "172.20.0.0/16"
    aks_control_plane_identity               = "user"
    aks_control_plane_identity_manage_grants = true
  }

  assert {
    condition     = module.aks.control_plane_identity.id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane"
    error_message = "With aks_control_plane_identity_manage_grants = true, a supplied network refused the identity the module creates"
  }
}

# ── Variable rules ───────────────────────────────────────────────────────────

run "an_identity_mode_outside_system_and_user_is_refused" {
  command = plan

  variables {
    aks_control_plane_identity = "UserAssigned"
  }

  expect_failures = [var.aks_control_plane_identity]
}

run "an_identity_id_with_a_system_identity_is_refused" {
  command = plan

  variables {
    aks_control_plane_identity_id = var.fixture_identity_id
  }

  expect_failures = [var.aks_control_plane_identity_id]
}

run "manage_grants_with_a_system_identity_is_refused" {
  command = plan

  variables {
    aks_control_plane_identity_manage_grants = true
  }

  expect_failures = [var.aks_control_plane_identity_manage_grants]
}

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
    aks_private_cluster_enabled   = true
    aks_private_dns_zone_id       = "privatelink.eastus.azmk8s.io"
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
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

# Local accounts are disabled, so the certificate can never sign in.
run "certificate_sign_in_with_entra_only_is_refused" {
  command = plan

  variables {
    aks_entra_only = true
    aks_kube_auth  = "certificate"
  }

  expect_failures = [var.aks_kube_auth]
}

run "a_cluster_identity_that_is_not_a_user_assigned_identity_is_refused" {
  command = plan

  variables {
    aks_control_plane_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.Network/virtualNetworks/not-an-identity"
  }

  expect_failures = [var.aks_control_plane_identity_id]
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
    aks_private_cluster_enabled   = true
    aks_private_dns_zone_id       = var.fixture_dns_zone_id
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
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
    aks_private_cluster_enabled   = true
    aks_private_dns_zone_id       = var.fixture_dns_zone_id
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
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
    condition     = module.aks.kube_auth == "certificate"
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
    condition     = module.aks.kube_auth == "entra"
    error_message = "A cluster that already takes Entra tokens did not switch the providers to kubelogin"
  }
}

# ── An existing cluster's identity ───────────────────────────────────────────

run "the_live_identity_plans_clean" {
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
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
  }
}

run "the_live_system_identity_plans_clean" {
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
          identity         = "SystemAssigned"
          identity_ids     = null
        }]
      }
    }
  }
}

run "moving_an_existing_cluster_to_a_user_identity_is_refused" {
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
          identity         = "SystemAssigned"
          identity_ids     = null
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity = "user"
  }

  expect_failures = [terraform_data.aks_access_guard]
}

run "swapping_an_existing_clusters_user_identity_is_refused" {
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
          identity         = "UserAssigned"
          identity_ids     = { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ls-aks-test-control-plane" = {} }
        }]
      }
    }
  }

  variables {
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = var.fixture_identity_id
  }

  expect_failures = [terraform_data.aks_access_guard]
}
