# aks_outbound_type: the cluster's egress path. userDefinedRouting and
# userAssignedNATGateway need a supplied AKS subnet that already carries the
# route table or the NAT gateway, so the subnet reads are stubbed at file level
# with one that carries both, in a reused VNet as byo_network.tftest.hcl sets
# up. Each refusal run breaks one input. The change guard compares the requested
# type with the one Azure reports, so those runs stub the cluster list read
# with a cluster that already exists; the other runs see no cluster.
#
# expect_failures names the resource, not the precondition, so there is one run
# per rule.

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

override_data {
  target = data.azurerm_virtual_network.byo_vnet
  values = {
    address_space = ["10.0.0.0/18"]
    location      = "eastus"
  }
}

# The supplied AKS subnet: both service endpoints, sized for the default
# node-subnet pools, and a route table.
override_data {
  target = data.azurerm_subnet.byo_aks_subnet
  values = {
    address_prefixes  = ["10.0.0.0/19"]
    service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
    route_table_id    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/routeTables/platform-egress"
  }
}

# A default route to the platform firewall.
override_data {
  target = data.azurerm_route_table.byo_aks_subnet
  values = {
    route = [{ name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "VirtualAppliance", next_hop_in_ip_address = "10.0.100.4" }]
  }
}

override_data {
  target = data.azapi_resource.byo_aks_subnet_nat
  values = {
    output = {
      properties = {
        natGateway = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/natGateways/platform-nat" }
      }
    }
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

  # Named so the change runs' stubbed cluster is the one this module manages.
  resource_group_name = "ls-rg-test"
  cluster_name        = "ls-aks-test"
}

# ── Each type reaches the cluster ────────────────────────────────────────────

run "the_default_is_load_balancer_and_reads_nothing" {
  command = plan

  variables {
    aks_outbound_type = "loadBalancer"
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "loadBalancer"
    error_message = "The default outbound type did not reach the cluster as loadBalancer"
  }
  assert {
    condition     = length(data.azurerm_route_table.byo_aks_subnet) == 0 && length(data.azapi_resource.byo_aks_subnet_nat) == 0
    error_message = "loadBalancer still read the subnet's route table or NAT gateway"
  }
}

run "user_defined_routing_reaches_the_cluster" {
  command = plan

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "userDefinedRouting"
    error_message = "aks_outbound_type = \"userDefinedRouting\" did not reach the cluster's network profile"
  }
  assert {
    condition     = length(data.azurerm_route_table.byo_aks_subnet) == 1
    error_message = "userDefinedRouting did not read the subnet's route table for the default-route check"
  }
}

run "a_user_assigned_nat_gateway_reaches_the_cluster" {
  command = plan

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "existing"
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "userAssignedNATGateway"
    error_message = "aks_outbound_type = \"userAssignedNATGateway\" did not reach the cluster's network profile"
  }
  assert {
    condition     = length(data.azapi_resource.byo_aks_subnet_nat) == 1
    error_message = "userAssignedNATGateway did not read the subnet for its NAT gateway"
  }
  assert {
    condition     = length(azurerm_nat_gateway.aks) == 0 && length(azurerm_subnet_nat_gateway_association.aks) == 0
    error_message = "aks_nat_gateway = \"existing\" still planned a NAT gateway of its own"
  }
}

# Nothing in the egress path depends on the IPAM mode: Microsoft's overlay page
# lists user-defined routes on the cluster subnet as an egress option.
run "user_defined_routing_plans_in_overlay_mode" {
  command = plan

  variables {
    aks_network_mode  = "overlay"
    aks_outbound_type = "userDefinedRouting"
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "userDefinedRouting" && module.aks.network_profile.network_plugin_mode == "overlay"
    error_message = "userDefinedRouting did not plan alongside overlay mode"
  }
}

# ── Refusals ─────────────────────────────────────────────────────────────────

run "an_unknown_type_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "managedNATGateway"
  }

  expect_failures = [var.aks_outbound_type]
}

run "user_defined_routing_on_a_carved_subnet_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "userDefinedRouting"
    aks_subnet_id     = ""
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

run "user_defined_routing_on_a_new_vnet_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "userDefinedRouting"
    create_vnet       = true
    vnet_id           = ""
    aks_subnet_id     = ""
    aks_service_cidr  = ""
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

run "user_defined_routing_without_a_route_table_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_subnet.byo_aks_subnet
    values = {
      address_prefixes  = ["10.0.0.0/19"]
      service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
      route_table_id    = ""
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

run "an_existing_nat_gateway_that_is_missing_is_refused" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = { properties = {} }
    }
  }

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "existing"
  }

  expect_failures = [terraform_data.aks_nat_gateway_guard]
}

# Only a warning: a default route learned over BGP never appears in the table.
run "a_route_table_without_a_default_route_warns" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [{ name = "onprem", address_prefix = "10.0.0.0/8", next_hop_type = "VirtualNetworkGateway", next_hop_in_ip_address = "" }]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [check.aks_route_table_default_route]
}

# AKS refuses a default route to any next hop but VirtualAppliance or
# VirtualNetworkGateway, with RouteTableInvalidNextHop; None was seen live.
run "a_default_route_to_none_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [{ name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "None", next_hop_in_ip_address = "" }]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

# aks_network_owner_checks = false: the route table is not read at all (no
# read permission needed), so a default route AKS would refuse no longer stops
# the plan; Azure checks it at create.
run "network_owner_checks_off_skips_the_route_table_read" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [{ name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "None", next_hop_in_ip_address = "" }]
    }
  }

  variables {
    aks_outbound_type        = "userDefinedRouting"
    aks_network_owner_checks = false
  }

  assert {
    condition     = length(data.azurerm_route_table.byo_aks_subnet) == 0
    error_message = "aks_network_owner_checks = false still read the subnet's route table"
  }
}

run "a_default_route_to_the_internet_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [{ name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "Internet", next_hop_in_ip_address = "" }]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

run "a_default_route_to_vnet_local_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [{ name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "VnetLocal", next_hop_in_ip_address = "" }]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

# A default route on-premises, through the VPN or ExpressRoute gateway, and
# only Azure's own ranges straight out: plans, with a warning that the AKS
# required FQDNs outside AzureCloud depend on what sits behind the gateway.
run "a_gateway_default_route_with_only_service_tag_egress_warns" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [
        { name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "VirtualNetworkGateway", next_hop_in_ip_address = "" },
        { name = "azurecloud", address_prefix = "AzureCloud", next_hop_type = "Internet", next_hop_in_ip_address = "" },
      ]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  assert {
    condition     = length(local.aks_udr_default_routes) == 1 && length(local.aks_udr_bad_default_routes) == 0
    error_message = "A default route to VirtualNetworkGateway was not read as one allowed default route"
  }

  expect_failures = [check.aks_route_table_service_tag_egress]
}

# The file-level table: a default route to the firewall and nothing straight
# to Internet, so neither route warning applies.
run "an_appliance_default_route_does_not_warn" {
  command = plan

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  assert {
    condition     = !local.aks_udr_service_tag_only_egress && length(local.aks_udr_default_routes) == 1
    error_message = "A default route to VirtualAppliance with no Internet routes was flagged as service-tag-only egress"
  }
}

# An address range straight to Internet is general egress, not a service tag.
run "an_address_range_to_the_internet_does_not_warn" {
  command = plan

  override_data {
    target = data.azurerm_route_table.byo_aks_subnet
    values = {
      route = [
        { name = "default", address_prefix = "0.0.0.0/0", next_hop_type = "VirtualNetworkGateway", next_hop_in_ip_address = "" },
        { name = "azurecloud", address_prefix = "AzureCloud", next_hop_type = "Internet", next_hop_in_ip_address = "" },
        { name = "mcr", address_prefix = "150.171.0.0/16", next_hop_type = "Internet", next_hop_in_ip_address = "" },
      ]
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  assert {
    condition     = !local.aks_udr_service_tag_only_egress
    error_message = "An address-range route to Internet was ignored, so the service-tag warning still fired"
  }
}

run "an_attached_cluster_refuses_a_custom_type" {
  command = plan

  override_data {
    target = module.aks.data.azurerm_kubernetes_cluster.existing
    values = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-aks-rg/providers/Microsoft.ContainerService/managedClusters/platform-aks"
      location            = "eastus"
      oidc_issuer_enabled = true
      kube_config         = [{ host = "https://platform-aks.example", client_certificate = "", client_key = "", cluster_ca_certificate = "" }]
      agent_pool_profile = [
        { name = "system", vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks" },
      ]
    }
  }
  override_data {
    target = module.aks.data.azapi_resource.existing_security_profile
    values = {
      output = { properties = { securityProfile = { workloadIdentity = { enabled = true } } } }
    }
  }

  variables {
    create_cluster                       = false
    existing_cluster_name                = "platform-aks"
    existing_cluster_resource_group_name = "platform-aks-rg"
    cluster_name                         = ""
    aks_outbound_type                    = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

# ── aks_nat_gateway ──────────────────────────────────────────────────────────

run "the_nat_type_without_a_nat_gateway_mode_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "none"
  }

  expect_failures = [terraform_data.aks_nat_gateway_guard]
}

run "a_nat_gateway_with_the_load_balancer_type_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "loadBalancer"
    aks_nat_gateway   = "existing"
  }

  expect_failures = [terraform_data.aks_nat_gateway_guard]
}

run "a_nat_gateway_on_a_carved_subnet_is_refused" {
  command = plan

  variables {
    aks_outbound_type = "userDefinedRouting"
    aks_nat_gateway   = "create"
    aks_subnet_id     = ""
  }

  expect_failures = [terraform_data.aks_outbound_guard, terraform_data.aks_nat_gateway_guard]
}

# Create: a Standard NAT gateway and public IP in the deployment group, attached
# to the supplied subnet, which has none yet.
run "create_makes_and_attaches_a_nat_gateway" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = { properties = {} }
    }
  }

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "create"
  }

  assert {
    condition     = length(azurerm_nat_gateway.aks) == 1 && azurerm_nat_gateway.aks[0].sku_name == "Standard" && azurerm_nat_gateway.aks[0].resource_group_name == "ls-rg-test"
    error_message = "aks_nat_gateway = \"create\" did not plan a Standard NAT gateway in the deployment group"
  }
  assert {
    condition     = length(azurerm_public_ip.aks_nat) == 1 && azurerm_public_ip.aks_nat[0].sku == "Standard" && length(azurerm_nat_gateway_public_ip_association.aks) == 1
    error_message = "aks_nat_gateway = \"create\" did not plan a Standard public IP attached to the NAT gateway"
  }
  assert {
    condition     = length(azurerm_subnet_nat_gateway_association.aks) == 1 && azurerm_subnet_nat_gateway_association.aks[0].subnet_id == var.aks_subnet_id
    error_message = "aks_nat_gateway = \"create\" did not associate the NAT gateway with aks_subnet_id"
  }
  assert {
    condition     = azurerm_nat_gateway.aks[0].zones == null && azurerm_nat_gateway.aks[0].idle_timeout_in_minutes == 4
    error_message = "With availability_zones empty, the NAT gateway was pinned to a zone or lost the default idle timeout"
  }
}

run "create_pins_a_single_zone_and_takes_the_idle_timeout" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = { properties = {} }
    }
  }

  variables {
    aks_outbound_type                    = "userAssignedNATGateway"
    aks_nat_gateway                      = "create"
    aks_nat_gateway_idle_timeout_minutes = 10
    availability_zones                   = ["2"]
  }

  assert {
    condition     = toset(azurerm_nat_gateway.aks[0].zones) == toset(["2"]) && toset(azurerm_public_ip.aks_nat[0].zones) == toset(["2"])
    error_message = "With one availability zone, the NAT gateway and its public IP were not both pinned to it"
  }
  assert {
    condition     = azurerm_nat_gateway.aks[0].idle_timeout_in_minutes == 10
    error_message = "aks_nat_gateway_idle_timeout_minutes did not reach the NAT gateway"
  }
}

# A Standard NAT gateway lives in one zone, so three zones leave placement to Azure.
run "create_leaves_the_zone_to_azure_across_three_zones" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = { properties = {} }
    }
  }

  variables {
    aks_outbound_type  = "userAssignedNATGateway"
    aks_nat_gateway    = "create"
    availability_zones = ["1", "2", "3"]
  }

  assert {
    condition     = azurerm_nat_gateway.aks[0].zones == null
    error_message = "With three availability zones, the Standard NAT gateway was pinned to zones"
  }
}

# The layout where the route table sends 0.0.0.0/0 to a gateway and other
# prefixes to Internet through the NAT gateway. Plans; not proven on a cluster.
run "create_with_user_defined_routing_plans" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = { properties = {} }
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
    aks_nat_gateway   = "create"
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "userDefinedRouting" && length(azurerm_subnet_nat_gateway_association.aks) == 1
    error_message = "userDefinedRouting with aks_nat_gateway = \"create\" did not plan both"
  }
}

# On a later apply the subnet carries the NAT gateway this module created.
run "create_accepts_its_own_nat_gateway_on_the_subnet" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_aks_subnet_nat
    values = {
      output = {
        properties = {
          natGateway = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/LS-RG-TEST/providers/Microsoft.Network/natGateways/langsmith-nat" }
        }
      }
    }
  }

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "create"
  }
}

# The file-level stub is a subnet that already has the network owner's NAT gateway.
run "create_refuses_to_replace_another_nat_gateway" {
  command = plan

  variables {
    aks_outbound_type = "userAssignedNATGateway"
    aks_nat_gateway   = "create"
  }

  expect_failures = [terraform_data.aks_nat_gateway_guard]
}

run "a_nat_gateway_on_an_attached_cluster_is_refused" {
  command = plan

  override_data {
    target = module.aks.data.azurerm_kubernetes_cluster.existing
    values = {
      id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/platform-aks-rg/providers/Microsoft.ContainerService/managedClusters/platform-aks"
      location            = "eastus"
      oidc_issuer_enabled = true
      kube_config         = [{ host = "https://platform-aks.example", client_certificate = "", client_key = "", cluster_ca_certificate = "" }]
      agent_pool_profile = [
        { name = "system", vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks" },
      ]
    }
  }
  override_data {
    target = module.aks.data.azapi_resource.existing_security_profile
    values = {
      output = { properties = { securityProfile = { workloadIdentity = { enabled = true } } } }
    }
  }

  variables {
    create_cluster                       = false
    existing_cluster_name                = "platform-aks"
    existing_cluster_resource_group_name = "platform-aks-rg"
    cluster_name                         = ""
    aks_nat_gateway                      = "create"
    # A type that takes a NAT gateway, so only the attached-cluster rule in the
    # NAT guard can fire; the outbound guard refuses the type on its own.
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard, terraform_data.aks_nat_gateway_guard]
}

# ── A cluster that already exists ────────────────────────────────────────────

run "the_live_type_plans_clean" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name      = "ls-aks-test"
          dataplane = "azure"
          policy    = "azure"
          outbound  = "loadBalancer"
        }]
      }
    }
  }

  variables {
    aks_outbound_type = "loadBalancer"
  }

  assert {
    condition     = module.aks.live_network_profile.outbound == "loadBalancer"
    error_message = "The stubbed cluster's outbound type did not reach live_network_profile, so the guard compared against nothing"
  }
}

run "a_change_on_an_existing_cluster_is_refused_without_the_flag" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name      = "ls-aks-test"
          dataplane = "azure"
          policy    = "azure"
          outbound  = "loadBalancer"
        }]
      }
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }

  expect_failures = [terraform_data.aks_outbound_guard]
}

run "a_change_on_an_existing_cluster_passes_with_the_flag" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name      = "ls-aks-test"
          dataplane = "azure"
          policy    = "azure"
          outbound  = "loadBalancer"
        }]
      }
    }
  }

  variables {
    aks_outbound_type              = "userDefinedRouting"
    aks_allow_outbound_type_change = true
  }

  assert {
    condition     = module.aks.network_profile.outbound_type == "userDefinedRouting"
    error_message = "With aks_allow_outbound_type_change, the change still did not reach the cluster"
  }
}

# A read with no outbound field (a stub written before this check, or an API
# shape without it) never counts as a change.
run "a_live_read_without_an_outbound_type_is_not_a_change" {
  command = plan

  override_data {
    target = module.aks.data.azapi_resource_list.clusters
    values = {
      output = {
        clusters = [{
          id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
          name      = "ls-aks-test"
          dataplane = "azure"
          policy    = "azure"
        }]
      }
    }
  }

  variables {
    aks_outbound_type = "userDefinedRouting"
  }
}
