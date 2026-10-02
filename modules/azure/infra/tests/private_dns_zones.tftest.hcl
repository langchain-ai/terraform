# Central private DNS zones (PostgreSQL) and the Key Vault Private Endpoint.
# A supplied zone must stop Terraform creating a second zone of the same name
# and its VNet link, and must reach the resource that registers in it. Every
# run sets the variables it asserts on, so a default change shows up here.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
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
  # Throwaway keypair, generated for this fixture and the private half discarded.
  bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLvAeJ8tG7HNaDGXt2T05HJmj1X1qaP+jb2MTDRBLNEPOwsvT7UrCsGp/8AB5MZIyMmRLoNOz1GTRWWBQsgQoKJD1jPUJNvSDZ16g4yFV4wX2o6nxooi53U9L6JWH6XrXn2Ozhca7tC0o26Oyd2toFrf8An8H8Gnwsdr3EOIrqvL0ZxXvjgGLZDx9auENfrlrhob8+6QLsZkEzphDWqKhbYpy46WEYtwHvKRpYX1YlDN6jbObN0wifqu98UZNsIr7FoZR3luNj1bA/kjqUC61GW6UziPyCoMhk3Jf9IMQ24OBXn2Xp4JWMZ3jYp+IL1fi9YVgofvsOvlYM2XGtmgzt plan-tests-fixture"

}

# ── PostgreSQL zone ──────────────────────────────────────────────────────────

run "postgres_creates_its_zone_by_default" {
  command = plan

  variables {
    postgres_source              = "external"
    postgres_private_dns_zone_id = ""
  }

  assert {
    condition     = module.postgres[0].private_dns_zone_created
    error_message = "With no postgres_private_dns_zone_id, the postgres module did not create its zone and VNet link"
  }
}

run "a_supplied_postgres_zone_is_used_and_not_created" {
  command = plan

  variables {
    postgres_source              = "external"
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  assert {
    condition     = !module.postgres[0].private_dns_zone_created
    error_message = "A supplied postgres_private_dns_zone_id still planned a zone and VNet link in the postgres module"
  }
  assert {
    condition     = module.postgres[0].server_private_dns_zone_id == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
    error_message = "The Flexible Server is not configured with the supplied postgres_private_dns_zone_id"
  }
}

# The metastore shares LangSmith's server zone today; a supplied zone has to
# reach it on both postgres paths, or SmithDB brings back the duplicate zone.
run "smithdb_uses_a_supplied_postgres_zone_with_external_postgres" {
  command = plan

  variables {
    postgres_source              = "external"
    enable_smithdb               = true
    availability_zones           = ["1", "2", "3"]
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  assert {
    condition     = !module.smithdb[0].metastore_private_dns_zone_created && module.smithdb[0].metastore_private_dns_zone_id == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
    error_message = "With external postgres and a supplied zone, the SmithDB metastore did not use the supplied zone"
  }
}

run "smithdb_uses_a_supplied_postgres_zone_with_in_cluster_postgres" {
  command = plan

  variables {
    postgres_source              = "in-cluster"
    enable_smithdb               = true
    availability_zones           = ["1", "2", "3"]
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  assert {
    condition     = !module.smithdb[0].metastore_private_dns_zone_created && module.smithdb[0].metastore_private_dns_zone_id == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
    error_message = "With in-cluster postgres and a supplied zone, the SmithDB metastore still created a zone of its own"
  }
}

run "smithdb_creates_its_zone_with_in_cluster_postgres_and_no_supplied_zone" {
  command = plan

  variables {
    postgres_source              = "in-cluster"
    enable_smithdb               = true
    availability_zones           = ["1", "2", "3"]
    postgres_private_dns_zone_id = ""
  }

  assert {
    condition     = module.smithdb[0].metastore_private_dns_zone_created
    error_message = "With in-cluster postgres and no supplied zone, the SmithDB metastore did not create its own zone"
  }
}

run "a_postgres_zone_with_the_wrong_suffix_is_refused" {
  command = plan

  variables {
    postgres_source              = "external"
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
  }

  expect_failures = [var.postgres_private_dns_zone_id]
}

run "a_public_postgres_zone_is_refused_in_government" {
  command = plan

  variables {
    azure_environment            = "usgovernment"
    location                     = "usgovvirginia"
    redis_source                 = "in-cluster"
    postgres_source              = "external"
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  expect_failures = [var.postgres_private_dns_zone_id]
}

run "a_government_postgres_zone_is_used_in_government" {
  command = plan

  variables {
    azure_environment            = "usgovernment"
    location                     = "usgovvirginia"
    redis_source                 = "in-cluster"
    postgres_source              = "external"
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.usgovcloudapi.net"
  }

  assert {
    condition     = !module.postgres[0].private_dns_zone_created
    error_message = "A Government postgres zone in usgovernment still planned a zone of the module's own"
  }
}

run "a_postgres_zone_with_no_server_to_use_it_is_refused" {
  command = plan

  variables {
    postgres_source              = "in-cluster"
    enable_smithdb               = false
    postgres_private_dns_zone_id = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com"
  }

  expect_failures = [var.postgres_private_dns_zone_id]
}

# ── Key Vault Private Endpoint ───────────────────────────────────────────────

run "keyvault_stays_public_without_the_endpoint" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled = false
  }

  assert {
    condition     = module.keyvault.private_endpoint_id == null && module.keyvault.public_network_access_enabled
    error_message = "With keyvault_private_endpoint_enabled = false the vault lost its public endpoint or gained a private one"
  }
  assert {
    condition     = length(azurerm_private_dns_zone.keyvault) == 0 && length(azurerm_private_dns_zone_virtual_network_link.keyvault) == 0
    error_message = "With keyvault_private_endpoint_enabled = false a Key Vault zone was still planned"
  }
  assert {
    condition     = length(module.keyvault.firewall_subnet_ids) == 1
    error_message = "With keyvault_private_endpoint_enabled = false the AKS subnet is no longer allowlisted on the vault firewall"
  }
}

run "keyvault_endpoint_creates_and_links_its_zone" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled = true
    keyvault_private_dns_zone_id      = ""
  }

  assert {
    condition     = !module.keyvault.public_network_access_enabled
    error_message = "keyvault_private_endpoint_enabled = true left the vault's public network access on"
  }
  assert {
    condition     = length(azurerm_private_dns_zone.keyvault) == 1 && length(azurerm_private_dns_zone_virtual_network_link.keyvault) == 1
    error_message = "keyvault_private_endpoint_enabled = true with no zone supplied did not plan the vaultcore zone and its VNet link"
  }
  assert {
    condition     = azurerm_private_dns_zone.keyvault[0].name == "privatelink.vaultcore.azure.net"
    error_message = "The created Key Vault zone is not privatelink.vaultcore.azure.net"
  }
  assert {
    condition     = length(module.keyvault.firewall_subnet_ids) == 0
    error_message = "With the private endpoint on, the AKS subnet is still allowlisted on the vault firewall, which keeps the Microsoft.KeyVault service endpoint required"
  }
}

run "a_supplied_keyvault_zone_is_used_and_not_created" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled = true
    keyvault_private_dns_zone_id      = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  assert {
    condition     = length(azurerm_private_dns_zone.keyvault) == 0 && length(azurerm_private_dns_zone_virtual_network_link.keyvault) == 0
    error_message = "A supplied keyvault_private_dns_zone_id still planned a second vaultcore zone or a VNet link"
  }
  assert {
    condition     = module.keyvault.private_endpoint_dns_zone_id == "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
    error_message = "The vault's private endpoint does not register in the supplied keyvault_private_dns_zone_id"
  }
}

run "keyvault_endpoint_uses_the_government_zone_name" {
  command = plan

  variables {
    azure_environment                 = "usgovernment"
    location                          = "usgovvirginia"
    redis_source                      = "in-cluster"
    keyvault_private_endpoint_enabled = true
    keyvault_private_dns_zone_id      = ""
  }

  assert {
    condition     = azurerm_private_dns_zone.keyvault[0].name == "privatelink.vaultcore.usgovcloudapi.net"
    error_message = "In usgovernment the created Key Vault zone is not privatelink.vaultcore.usgovcloudapi.net"
  }
}

run "a_public_keyvault_zone_is_refused_in_government" {
  command = plan

  variables {
    azure_environment                 = "usgovernment"
    location                          = "usgovvirginia"
    redis_source                      = "in-cluster"
    keyvault_private_endpoint_enabled = true
    keyvault_private_dns_zone_id      = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  expect_failures = [var.keyvault_private_dns_zone_id]
}

run "keyvault_endpoint_on_a_supplied_vault_is_refused" {
  command = plan

  variables {
    create_keyvault                       = false
    existing_keyvault_name                = "customer-kv"
    existing_keyvault_resource_group_name = "customer-kv-rg"
    keyvault_private_endpoint_enabled     = true
  }

  expect_failures = [var.keyvault_private_endpoint_enabled]
}

run "keyvault_endpoint_with_allowed_ips_is_refused" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled = true
    keyvault_allowed_ips              = ["203.0.113.10"]
  }

  expect_failures = [var.keyvault_private_endpoint_enabled]
}

run "a_keyvault_zone_without_the_endpoint_is_refused" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled = false
    keyvault_private_dns_zone_id      = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
  }

  expect_failures = [var.keyvault_private_dns_zone_id]
}

run "a_keyvault_endpoint_subnet_without_the_endpoint_is_refused" {
  command = plan

  variables {
    keyvault_private_endpoint_enabled   = false
    keyvault_private_endpoint_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/endpoints"
  }

  expect_failures = [var.keyvault_private_endpoint_subnet_id]
}
