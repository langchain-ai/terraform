# azure_environment: the provider cloud and every DNS name that differs between
# commercial Azure and Azure Government (#279). Mocked, so no cloud is reached;
# what is asserted is that the root picks the right name for each cloud.

# A UUID tenant, because the Key Vault schema rejects the generated string.
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
  subscription_id                  = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password          = "fixture-not-a-real-secret-Aa1"
  postgres_source                  = "external"
  storage_private_endpoint_enabled = true
  dns_label                        = "fixture"
  langsmith_domain                 = ""
}

run "public_is_the_default_and_keeps_commercial_names" {
  command = plan

  variables {
    location     = "eastus"
    redis_source = "external"
  }

  assert {
    condition     = var.azure_environment == "public"
    error_message = "azure_environment no longer defaults to public; every existing deployment would change cloud"
  }
  assert {
    condition     = module.postgres[0].private_dns_zone_name == "privatelink.postgres.database.azure.com"
    error_message = "public planned the wrong Postgres zone: ${module.postgres[0].private_dns_zone_name}"
  }
  assert {
    condition     = azurerm_private_dns_zone.blob[0].name == "privatelink.blob.core.windows.net"
    error_message = "public planned the wrong Blob zone: ${azurerm_private_dns_zone.blob[0].name}"
  }
  assert {
    condition     = output.langsmith_url == "https://fixture.eastus.cloudapp.azure.com"
    error_message = "public built the wrong URL: ${output.langsmith_url}"
  }
}

run "usgovernment_uses_government_names" {
  command = plan

  variables {
    azure_environment = "usgovernment"
    location          = "usgovvirginia"
    redis_source      = "in-cluster"
  }

  assert {
    condition     = module.postgres[0].private_dns_zone_name == "privatelink.postgres.database.usgovcloudapi.net"
    error_message = "usgovernment planned the wrong Postgres zone: ${module.postgres[0].private_dns_zone_name}"
  }
  assert {
    condition     = azurerm_private_dns_zone.blob[0].name == "privatelink.blob.core.usgovcloudapi.net"
    error_message = "usgovernment planned the wrong Blob zone: ${azurerm_private_dns_zone.blob[0].name}"
  }
  assert {
    condition     = output.langsmith_url == "https://fixture.usgovvirginia.cloudapp.usgovcloudapi.net"
    error_message = "usgovernment built the wrong URL: ${output.langsmith_url}"
  }
}

run "usgovernment_refuses_managed_redis" {
  command = plan

  variables {
    azure_environment = "usgovernment"
    location          = "usgovvirginia"
    redis_source      = "external"
  }

  expect_failures = [var.redis_source]
}

run "azure_environment_rejects_an_unlisted_cloud" {
  command = plan

  variables {
    azure_environment = "china"
    redis_source      = "in-cluster"
  }

  expect_failures = [var.azure_environment]
}

run "usgovernment_accepts_a_government_blob_zone" {
  command = plan

  variables {
    azure_environment           = "usgovernment"
    location                    = "usgovvirginia"
    redis_source                = "in-cluster"
    storage_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.usgovcloudapi.net"
  }

  assert {
    condition     = length(azurerm_private_dns_zone.blob) == 0
    error_message = "a supplied Government Blob zone still planned a new one"
  }
}

run "usgovernment_rejects_a_commercial_blob_zone" {
  command = plan

  variables {
    azure_environment           = "usgovernment"
    location                    = "usgovvirginia"
    redis_source                = "in-cluster"
    storage_private_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  }

  expect_failures = [var.storage_private_dns_zone_id]
}
