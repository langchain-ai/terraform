# aks_nat_gateway = "create" pins the NAT gateway and its public IP to a zone
# only when availability_zones names exactly one. Zones are creation-time on
# both, so the module ignores zone changes on them, as the cluster does for its
# node pool, and check.aks_nat_gateway_zone_drift reports the discarded change.
#
# The only way to test "an existing NAT gateway" is to apply first, so this file
# applies against the mocks and then plans a change. Applying the root needs two
# mock defaults that plan-only files never reach: a kube_config element on the
# cluster (the providers index it) and a resource ID on the resource group (the
# Redis module parses it as a parent ID), or teardown fails on Terraform 1.11.
# The NAT resources get ID-shaped mock IDs because their associations parse them.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
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
  mock_resource "azurerm_nat_gateway" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/natGateways/ls-nat-test"
    }
  }
  mock_resource "azurerm_public_ip" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.Network/publicIPAddresses/ls-nat-test-pip"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test"
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

# Only the root's NAT gateway and public IP are under test. The other modules
# parse mock IDs, need computed principals or reach a cluster at apply, so
# stand in for them.
override_module {
  target = module.blob
}
override_module {
  target = module.postgres
}
override_module {
  target = module.redis
}
override_module {
  target = module.keyvault
}
override_module {
  target = module.aks
  outputs = {
    cluster_name    = "ls-aks-test"
    node_subnet_ids = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"]
  }
}
override_module {
  target = module.k8s_bootstrap
}

override_data {
  target = data.azurerm_virtual_network.byo_vnet
  values = {
    address_space = ["10.0.0.0/18"]
    location      = "eastus"
  }
}

# A supplied AKS subnet with both service endpoints and no NAT gateway yet, so
# create mode attaches the module's own.
override_data {
  target = data.azurerm_subnet.byo_aks_subnet
  values = {
    address_prefixes  = ["10.0.0.0/19"]
    service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
  }
}

override_data {
  target = data.azapi_resource.byo_aks_subnet_nat
  values = {
    output = { properties = {} }
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"

  create_vnet      = false
  vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
  aks_subnet_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks"
  aks_service_cidr = "10.100.0.0/16"
  aks_network_mode = "node-subnet"
  postgres_source  = "external"
  redis_source     = "external"

  resource_group_name = "ls-rg-test"
  cluster_name        = "ls-aks-test"

  aks_outbound_type = "userAssignedNATGateway"
  aks_nat_gateway   = "create"
}

run "create_pins_the_nat_gateway_to_the_single_zone" {
  command = apply

  variables {
    availability_zones = ["1"]
  }

  assert {
    condition     = toset(azurerm_nat_gateway.aks[0].zones) == toset(["1"]) && toset(azurerm_public_ip.aks_nat[0].zones) == toset(["1"])
    error_message = "With one availability zone, the NAT gateway and its public IP should be pinned to it"
  }
}

# Widening availability_zones on the running deployment would, without
# ignore_changes, set both resources' zones to null and replace them. The plan
# keeps the live zones instead, and the drift check warns.
run "widening_availability_zones_keeps_the_existing_nat_gateway" {
  command = plan

  variables {
    availability_zones = ["1", "2", "3"]
  }

  assert {
    condition     = toset(azurerm_nat_gateway.aks[0].zones) == toset(["1"])
    error_message = "A zone change on an existing NAT gateway must plan no change to its zones (a change replaces it)"
  }

  assert {
    condition     = toset(azurerm_public_ip.aks_nat[0].zones) == toset(["1"])
    error_message = "A zone change on an existing NAT gateway must plan no change to its public IP's zones (a change replaces it and moves the egress address)"
  }

  expect_failures = [check.aks_nat_gateway_zone_drift]
}

# Back to the live value: no drift, so no warning.
run "matching_zones_raise_no_drift_warning" {
  command = plan

  variables {
    availability_zones = ["1"]
  }

  assert {
    condition     = toset(azurerm_nat_gateway.aks[0].zones) == toset(["1"])
    error_message = "The NAT gateway should stay in zone 1"
  }
}
