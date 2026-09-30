# The create_vnet = false path: a VNet the operator owns, with each subnet either
# supplied by ID or carved into it by Terraform. Its cross-variable rules are
# preconditions on terraform_data.validate_network, several of them reading the
# supplied VNet and subnets at plan time. The reads are stubbed at file level
# with a network that passes every rule, so each run breaks one input and a
# failure on validate_network can only be the rule that input feeds.
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

# A /18 holds the default carve prefixes (10.0.0.0/19, 10.0.32.0/20 and
# 10.0.48.0/20) and stops short of 10.0.64.0/20, the create-path ClusterIP
# default, so leaving aks_service_cidr empty trips only the rule requiring it.
override_data {
  target = data.azurerm_virtual_network.byo_vnet
  values = {
    address_space = ["10.0.0.0/18"]
  }
}

# A supplied AKS subnet that already carries both service endpoints, sized for
# the default node-subnet pools.
override_data {
  target = data.azurerm_subnet.byo_aks_subnet
  values = {
    address_prefixes  = ["10.0.0.0/19"]
    service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]
  }
}

override_data {
  target = data.azapi_resource.byo_postgres_subnet
  values = {
    output = {
      properties = {
        delegations = [{ name = "postgres", properties = { serviceName = "Microsoft.DBforPostgreSQL/flexibleServers" } }]
      }
    }
  }
}

override_data {
  target = data.azapi_resource.byo_agic_subnet_delegations
  values = {
    output = {
      properties = {
        delegations = [{ name = "agw", properties = { serviceName = "Microsoft.Network/applicationGateways" } }]
      }
    }
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
  # Throwaway keypair, generated for the wiring suite and the private half
  # discarded. create_bastion = true with the empty default fails inside
  # azurerm's own schema validator rather than at a precondition.
  bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLvAeJ8tG7HNaDGXt2T05HJmj1X1qaP+jb2MTDRBLNEPOwsvT7UrCsGp/8AB5MZIyMmRLoNOz1GTRWWBQsgQoKJD1jPUJNvSDZ16g4yFV4wX2o6nxooi53U9L6JWH6XrXn2Ozhca7tC0o26Oyd2toFrf8An8H8Gnwsdr3EOIrqvL0ZxXvjgGLZDx9auENfrlrhob8+6QLsZkEzphDWqKhbYpy46WEYtwHvKRpYX1YlDN6jbObN0wifqu98UZNsIr7FoZR3luNj1bA/kjqUC61GW6UziPyCoMhk3Jf9IMQ24OBXn2Xp4JWMZ3jYp+IL1fi9YVgofvsOvlYM2XGtmgzt plan-tests-fixture"

  create_vnet      = false
  vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
  aks_service_cidr = "10.100.0.0/16"
  # Pinned rather than inherited: the capacity arithmetic above assumes
  # node-subnet mode, and AGIC on overlay raises a check of its own.
  aks_network_mode = "node-subnet"
  postgres_source  = "external"
  redis_source     = "external"
}

# ── The shapes that plan clean ───────────────────────────────────────────────

run "a_reused_vnet_with_no_subnet_ids_plans_clean" {
  command = plan

  assert {
    condition     = length(data.azurerm_virtual_network.byo_vnet) == 1
    error_message = "create_vnet = false did not read vnet_id for its address space"
  }
  assert {
    condition     = length(data.azurerm_subnet.byo_aks_subnet) == 0 && length(data.azapi_resource.byo_postgres_subnet) == 0
    error_message = "With no subnet IDs supplied, a supplied-subnet read was still planned"
  }
}

run "supplied_subnets_are_read_and_not_carved" {
  command = plan

  variables {
    aks_subnet_id      = "${var.vnet_id}/subnets/aks"
    postgres_subnet_id = "${var.vnet_id}/subnets/postgres"
    redis_subnet_id    = "${var.vnet_id}/subnets/redis"
  }

  assert {
    condition     = length(data.azurerm_subnet.byo_aks_subnet) == 1 && length(data.azapi_resource.byo_postgres_subnet) == 1
    error_message = "A supplied AKS or Postgres subnet was not read at plan time"
  }
  assert {
    condition     = module.vnet.subnet_main_id == null && module.vnet.subnet_postgres_id == null && module.vnet.subnet_redis_id == null
    error_message = "A subnet was supplied by ID and Terraform still planned to carve one for it"
  }
  assert {
    condition     = length(azapi_update_resource.byo_aks_subnet_endpoints) == 0
    error_message = "manage_byo_subnet_service_endpoints is off, and the supplied AKS subnet was still patched"
  }
}

# ── Required inputs ──────────────────────────────────────────────────────────

run "a_reused_vnet_requires_a_service_cidr" {
  command = plan

  variables {
    aks_service_cidr = ""
  }

  expect_failures = [terraform_data.validate_network]
}

run "subnet_ids_are_refused_on_the_create_path" {
  command = plan

  variables {
    create_vnet     = true
    redis_subnet_id = "${var.vnet_id}/subnets/redis"
  }

  expect_failures = [terraform_data.validate_network]
}

# ── Subnet identity ──────────────────────────────────────────────────────────

run "a_subnet_in_another_vnet_is_refused" {
  command = plan

  variables {
    redis_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/other-vnet/subnets/redis"
  }

  expect_failures = [terraform_data.validate_network]
}

# Azure resource names are case-insensitive, so a subnet ID copied from the
# portal can spell the VNet differently from vnet_id. The membership check
# lowercases both before comparing.
run "a_subnet_id_in_a_different_case_is_still_in_the_vnet" {
  command = plan

  variables {
    redis_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Network-RG/providers/Microsoft.Network/virtualNetworks/Shared-VNet/subnets/redis"
  }
}

run "the_same_subnet_twice_is_refused" {
  command = plan

  variables {
    postgres_subnet_id = "${var.vnet_id}/subnets/data"
    redis_subnet_id    = "${var.vnet_id}/subnets/data"
  }

  expect_failures = [terraform_data.validate_network]
}

# ── Address space ────────────────────────────────────────────────────────────

run "a_carved_prefix_outside_the_vnet_is_refused" {
  command = plan

  variables {
    redis_subnet_address_prefix = ["10.1.0.0/20"]
  }

  expect_failures = [terraform_data.validate_network]
}

# The prefix is outside the VNet, but the service runs in-cluster, so Terraform
# carves nothing and has nothing to check.
run "an_in_cluster_service_prefix_is_not_checked" {
  command = plan

  variables {
    redis_source                = "in-cluster"
    redis_subnet_address_prefix = ["10.1.0.0/20"]
  }
}

run "a_service_cidr_inside_the_vnet_is_refused" {
  command = plan

  variables {
    aks_service_cidr = "10.0.16.0/20"
  }

  expect_failures = [terraform_data.validate_network]
}

# ── Supplied subnet properties ───────────────────────────────────────────────

run "an_undelegated_postgres_subnet_is_refused" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_postgres_subnet
    values = {
      output = { properties = { delegations = [] } }
    }
  }

  variables {
    postgres_subnet_id = "${var.vnet_id}/subnets/postgres"
  }

  expect_failures = [terraform_data.validate_network]
}

run "an_aks_subnet_without_service_endpoints_is_refused" {
  command = plan

  override_data {
    target = data.azurerm_subnet.byo_aks_subnet
    values = {
      address_prefixes  = ["10.0.0.0/19"]
      service_endpoints = ["Microsoft.Storage"]
    }
  }

  variables {
    aks_subnet_id = "${var.vnet_id}/subnets/aks"
  }

  expect_failures = [terraform_data.validate_network]
}

# With the flag on, the missing endpoint is Terraform's to add, so the check
# steps aside. The patch appends to what is there: Azure replaces the whole
# list on write, so rebuilding it would drop the existing endpoint's locations.
run "a_managed_aks_subnet_gains_the_missing_endpoint" {
  command = plan

  override_data {
    target = data.azurerm_subnet.byo_aks_subnet
    values = {
      address_prefixes  = ["10.0.0.0/19"]
      service_endpoints = ["Microsoft.Storage"]
    }
  }
  override_data {
    target = data.azapi_resource.byo_aks_subnet_endpoints
    values = {
      output = { properties = { serviceEndpoints = [{ service = "Microsoft.Storage", locations = ["eastus", "westus"] }] } }
    }
  }

  variables {
    aks_subnet_id                       = "${var.vnet_id}/subnets/aks"
    manage_byo_subnet_service_endpoints = true
  }

  assert {
    condition     = length(azapi_update_resource.byo_aks_subnet_endpoints) == 1
    error_message = "manage_byo_subnet_service_endpoints = true did not plan the service endpoint patch"
  }
  assert {
    condition     = [for e in azapi_update_resource.byo_aks_subnet_endpoints[0].body.properties.serviceEndpoints : e.service] == ["Microsoft.Storage", "Microsoft.KeyVault"]
    error_message = "The patch did not append Microsoft.KeyVault after the subnet's existing Microsoft.Storage endpoint"
  }
  assert {
    condition     = azapi_update_resource.byo_aks_subnet_endpoints[0].body.properties.serviceEndpoints[0].locations == ["eastus", "westus"]
    error_message = "The patch dropped the locations on the subnet's existing endpoint"
  }
}

# ── Bastion and AGIC subnets ─────────────────────────────────────────────────
# Terraform carves neither inside a VNet it does not own.

run "a_bastion_without_a_supplied_subnet_is_refused" {
  command = plan

  variables {
    create_bastion = true
  }

  expect_failures = [terraform_data.validate_network]
}

run "a_bastion_subnet_with_the_wrong_name_is_refused" {
  command = plan

  variables {
    create_bastion    = true
    bastion_subnet_id = "${var.vnet_id}/subnets/bastion"
  }

  expect_failures = [terraform_data.validate_network]
}

run "a_delegated_agic_subnet_plans_clean" {
  command = plan

  variables {
    ingress_controller = "agic"
    agic_subnet_id     = "${var.vnet_id}/subnets/agw"
  }
}

# A check and not a precondition: a gateway created before Azure required the
# delegation keeps running without it, so the plan warns and proceeds.
run "an_undelegated_agic_subnet_warns" {
  command = plan

  override_data {
    target = data.azapi_resource.byo_agic_subnet_delegations
    values = {
      output = { properties = { delegations = [] } }
    }
  }

  variables {
    ingress_controller = "agic"
    agic_subnet_id     = "${var.vnet_id}/subnets/agw"
  }

  expect_failures = [check.agic_subnet_delegation]
}

# ── Subnet NSGs ──────────────────────────────────────────────────────────────
# A supplied subnet keeps its owner's NSG, and the carved subnets admit the
# supplied AKS subnet's real prefixes rather than the unused carve default.

run "a_supplied_aks_subnet_gets_no_nsg" {
  command = plan

  variables {
    aks_subnet_id             = "${var.vnet_id}/subnets/aks"
    aks_subnet_address_prefix = ["10.0.200.0/24"]
    enable_subnet_nsgs        = true
  }

  assert {
    condition     = module.vnet.subnet_nsg_rules.aks == null
    error_message = "enable_subnet_nsgs = true planned an NSG on a supplied AKS subnet"
  }
  assert {
    condition     = one([for r in module.vnet.subnet_nsg_rules.postgres : r.source_address_prefixes if r.name == "allow-aks-postgres"]) == toset(["10.0.0.0/19"])
    error_message = "the Postgres NSG does not admit the supplied AKS subnet's prefixes"
  }
}


# An attached cluster's node pools can span subnets, and the data-tier NSGs admit
# aks_subnet_id alone. The two runs differ only in the second pool's subnet.

run "subnet_nsgs_plan_on_an_attached_cluster_in_one_subnet" {
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
        { name = "user", vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/AKS" },
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
    aks_subnet_id                        = "${var.vnet_id}/subnets/aks"
    enable_subnet_nsgs                   = true
  }

  assert {
    condition     = module.vnet.subnet_nsg_rules.postgres != null
    error_message = "enable_subnet_nsgs = true on an attached cluster in one subnet did not plan the Postgres NSG"
  }
}

run "subnet_nsgs_are_refused_on_an_attached_cluster_across_subnets" {
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
        { name = "user", vnet_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/aks-user" },
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
    aks_subnet_id                        = "${var.vnet_id}/subnets/aks"
    enable_subnet_nsgs                   = true
  }

  expect_failures = [terraform_data.validate_network]
}
