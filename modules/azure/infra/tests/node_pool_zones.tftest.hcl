# availability_zones reaches every additional node pool, not only the default
# pool, and a pool can set zones of its own for a VM size not offered in every
# zone. The cluster module resolves each pool's zones (its own, else
# availability_zones) and sets null, a regional pool, when neither names a
# zone, so a cluster built under the [] default plans no change. The pools are
# read through the module's node_pool_zones output, keyed by pool name, as the
# os_sku tests read node_pool_os_skus. The expected values are toset() on both
# sides because the provider stores zones as a set.
#
# The last two runs cover an existing pool, which only an apply can produce:
# they apply the pools against the mocks with zones (targeted, so only the
# cluster and what it needs are created) and then plan with no zones
# requested. The pools keep their zones, because the module ignores zone
# changes on an existing pool, and the empty request is exempt from
# check.aks_additional_node_pool_zone_drift, so the run passes. The opposite
# case, a regional pool under a zoned request, fires that check as intended
# (confirmed by hand) but cannot be a run here: a check in a child module
# cannot be named in expect_failures, and a failing check fails the run.
# Applying the root needs the mock defaults the teardown reads on Terraform
# 1.11 (a kube_config element on the cluster, resource IDs on the group, the
# network and the subnet), as nat_gateway_zones.tftest.hcl explains.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
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
}

run "availability_zones_reaches_every_additional_pool" {
  command = plan

  variables {
    availability_zones = ["1", "2", "3"]
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2 }
    }
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["platform"]) == toset(["1", "2", "3"])
    error_message = "A pool with no zones of its own should take availability_zones"
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["data"]) == toset(["1", "2", "3"])
    error_message = "Every pool with no zones of its own should take availability_zones, not only the first"
  }
}

run "a_pool_s_own_zones_win_for_that_pool_only" {
  command = plan

  variables {
    availability_zones = ["1", "2", "3"]
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2, zones = ["2"] }
    }
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["data"]) == toset(["2"])
    error_message = "A pool's own zones should be used for that pool instead of availability_zones"
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["platform"]) == toset(["1", "2", "3"])
    error_message = "One pool's own zones should not reach another pool, which keeps availability_zones"
  }
}

run "no_zones_anywhere_leaves_every_pool_regional" {
  command = plan

  variables {
    availability_zones = []
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2 }
    }
  }

  assert {
    condition     = module.aks.node_pool_zones["platform"] == null && module.aks.node_pool_zones["data"] == null
    error_message = "With availability_zones = [] and no per-pool zones the pools should set no zones, so a cluster created before this setting plans no change"
  }
}

run "a_pool_can_stay_regional_under_zoned_availability_zones" {
  command = plan

  variables {
    availability_zones = ["1", "2", "3"]
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2, zones = [] }
    }
  }

  assert {
    condition     = module.aks.node_pool_zones["data"] == null
    error_message = "zones = [] on a pool should leave it regional rather than fall through to availability_zones"
  }
}

run "refuses_a_zone_azure_does_not_have" {
  command = plan

  variables {
    availability_zones = ["1", "2", "3"]
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3, zones = ["1", "4"] }
    }
  }

  expect_failures = [var.additional_node_pools]
}

# ── An existing pool ─────────────────────────────────────────────────────────

run "pools_are_created_in_the_requested_zones" {
  command = apply

  plan_options {
    target = [module.aks.azurerm_kubernetes_cluster_node_pool.node_pool]
  }

  variables {
    availability_zones = ["1", "2", "3"]
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2 }
    }
  }
}

# Without ignore_changes the plan would set both pools' zones to null, which
# rotates each pool through its temporary pool and drains every node. The
# bootstrap module is stubbed because its providers read the applied cluster's
# mock kube_config, which is not a usable credential.
run "dropping_the_request_keeps_an_existing_pool_s_zones" {
  command = plan

  override_module {
    target = module.k8s_bootstrap
  }

  variables {
    availability_zones = []
    additional_node_pools = {
      platform = { vm_size = "Standard_D8s_v5", min_count = 1, max_count = 3 }
      data     = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2 }
    }
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["platform"]) == toset(["1", "2", "3"]) && toset(module.aks.node_pool_zones["data"]) == toset(["1", "2", "3"])
    error_message = "A zone change on an existing pool must plan no change to its zones (a change rotates the pool and drains every node on it)"
  }
}
