# postgres_high_availability_mode: ZoneRedundant (the default) or SameZone on the
# Flexible Server's high_availability block when HA is on. SameZone is for a
# region with no zone-redundant capacity for the SKU; it takes no standby zone,
# because the standby shares the primary's. HA off leaves no block and no mode.

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
  postgres_source         = "external"
}

run "ha_on_defaults_to_zone_redundant" {
  command = plan

  variables {
    postgres_high_availability = true
  }

  assert {
    condition     = output.postgres_high_availability_mode == "ZoneRedundant"
    error_message = "HA on with no mode set should configure ZoneRedundant, got ${coalesce(output.postgres_high_availability_mode, "null")}"
  }
}

run "ha_on_takes_same_zone" {
  command = plan

  variables {
    postgres_high_availability      = true
    postgres_high_availability_mode = "SameZone"
  }

  assert {
    condition     = output.postgres_high_availability_mode == "SameZone"
    error_message = "postgres_high_availability_mode = SameZone should reach the server, got ${coalesce(output.postgres_high_availability_mode, "null")}"
  }
}

run "a_standby_zone_alone_still_turns_ha_on_with_the_mode" {
  command = plan

  variables {
    postgres_standby_availability_zone = "2"
    availability_zones                 = ["1", "2", "3"]
  }

  assert {
    condition     = output.postgres_high_availability_mode == "ZoneRedundant"
    error_message = "A pinned standby zone should keep enabling ZoneRedundant HA, got ${coalesce(output.postgres_high_availability_mode, "null")}"
  }
}

run "ha_off_configures_no_mode" {
  command = plan

  assert {
    condition     = output.postgres_high_availability_mode == null
    error_message = "With HA off there should be no high_availability block and no mode"
  }
}

run "refuses_same_zone_with_a_standby_zone" {
  command = plan

  variables {
    postgres_high_availability         = true
    postgres_high_availability_mode    = "SameZone"
    postgres_standby_availability_zone = "2"
    availability_zones                 = ["1", "2", "3"]
  }

  expect_failures = [var.postgres_high_availability_mode]
}

run "refuses_an_unknown_mode" {
  command = plan

  variables {
    postgres_high_availability      = true
    postgres_high_availability_mode = "Zonal"
  }

  expect_failures = [var.postgres_high_availability_mode]
}
