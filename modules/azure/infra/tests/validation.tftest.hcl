# Every validation block in the root variables.tf, asserted to reject a bad
# value. A validation that stops firing is invisible otherwise: the variable
# still accepts its good values, and the bad value now reaches Azure, where it
# comes back as a name or SKU error partway through an apply.
#
# Runs are grouped by the kind of value being rejected rather than one per
# variable. Terraform reports every validation error in one pass, so a group
# costs one plan and still names the variable whose expected failure is missing.

# azurerm_client_config feeds the metastore's Entra administrator tenant_id, and
# the provider validates it as a UUID. The generated mock is a random string, so
# planning the SmithDB path fails on the fixture rather than on the module.
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
mock_provider "azapi" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  # Every printable ASCII punctuation character that survives raw HCL string
  # serialization. Double quotes and backslashes are covered by rejection runs.
  postgres_admin_password = "Aa1 !$#%&'()*+,-./:;<=>?@[]^_`{|}~"
  enable_smithdb          = false
}

run "enums_reject_an_unlisted_value" {
  command = plan

  variables {
    postgres_source                = "rds"
    redis_source                   = "elasticache"
    clickhouse_source              = "clickhouse-cloud"
    ingress_controller             = "traefik"
    tls_certificate_source         = "acm"
    keyvault_default_action        = "allow"
    agw_sku_tier                   = "Standard"
    agic_network_contributor_scope = "resourcegroup"
    terraform_principal_type       = "user"
  }

  expect_failures = [
    var.postgres_source,
    var.redis_source,
    var.clickhouse_source,
    var.ingress_controller,
    var.tls_certificate_source,
    var.keyvault_default_action,
    var.agw_sku_tier,
    var.agic_network_contributor_scope,
    var.terraform_principal_type,
  ]
}

run "postgres_password_rejects_a_double_quote" {
  command = plan

  variables {
    postgres_admin_password = "fixture-\"-not-a-real-secret-Aa1"
  }

  expect_failures = [var.postgres_admin_password]
}

run "postgres_password_rejects_a_backslash" {
  command = plan

  variables {
    postgres_admin_password = "fixture-\\-not-a-real-secret-Aa1"
  }

  expect_failures = [var.postgres_admin_password]
}

run "postgres_password_rejects_a_newline" {
  command = plan

  variables {
    postgres_admin_password = "fixture-\n-not-a-real-secret-Aa1"
  }

  expect_failures = [var.postgres_admin_password]
}

run "postgres_password_rejects_an_hcl_interpolation_opener" {
  command = plan

  variables {
    postgres_admin_password = "fixture-$${template}-not-a-real-secret-Aa1"
  }

  expect_failures = [var.postgres_admin_password]
}

run "postgres_password_rejects_an_hcl_directive_opener" {
  command = plan

  variables {
    postgres_admin_password = "fixture-%%{template}-not-a-real-secret-Aa1"
  }

  expect_failures = [var.postgres_admin_password]
}

run "resource_ids_reject_a_bare_name" {
  command = plan

  variables {
    vnet_id            = "langsmith-vnet"
    aks_subnet_id      = "aks-subnet"
    postgres_subnet_id = "postgres-subnet"
    redis_subnet_id    = "redis-subnet"
    agic_subnet_id     = "agic-subnet"
    bastion_subnet_id  = "AzureBastionSubnet"
  }

  expect_failures = [
    var.vnet_id,
    var.aks_subnet_id,
    var.postgres_subnet_id,
    var.redis_subnet_id,
    var.agic_subnet_id,
    var.bastion_subnet_id,
  ]
}

run "name_prefix_rejects_a_trailing_hyphen" {
  command = plan

  variables {
    name_prefix = "prod-"
  }

  expect_failures = [var.name_prefix]
}

run "smithdb_cache_performance_rejects_out_of_range_values" {
  command = plan

  variables {
    smithdb_cache_disk_iops            = 2999
    smithdb_cache_disk_throughput_mbps = 1201
  }

  expect_failures = [
    var.smithdb_cache_disk_iops,
    var.smithdb_cache_disk_throughput_mbps,
  ]
}

# Both values are inside their own range here, and Azure still refuses the pair:
# 3000 IOPS caps throughput at 750 MB/s. The ratio rule lives on
# terraform_data.validate_network, so the failure is reported there rather than
# against either variable. Every other precondition in that block passes with
# these inputs, so the failure can only be the ratio.
run "smithdb_cache_throughput_rejects_more_than_a_quarter_mbps_per_iops" {
  command = plan

  variables {
    smithdb_cache_disk_iops            = 3000
    smithdb_cache_disk_throughput_mbps = 1200
  }

  expect_failures = [terraform_data.validate_network]
}

# Not a variable validation: the rule couples enable_smithdb to
# availability_zones, so it lives on terraform_data.validate_network with the
# other SmithDB cross-variable rules. Every other precondition in that block
# passes with these inputs, so a failure here can only be the zone rule.
run "smithdb_requires_zonal_nodes_for_premium_ssd_v2" {
  command = plan

  variables {
    enable_smithdb     = true
    availability_zones = []
  }

  expect_failures = [terraform_data.validate_network]
}

run "identifier_is_rejected_outright" {
  command = plan

  variables {
    identifier = "-prod"
  }

  expect_failures = [var.identifier]
}

run "subscription_id_rejects_a_non_guid" {
  command = plan

  variables {
    subscription_id = "my-subscription"
  }

  expect_failures = [var.subscription_id]
}

# aks_service_cidr carries two validations. One run per validation, because
# expect_failures names the variable and cannot distinguish them.

run "aks_service_cidr_rejects_a_non_cidr" {
  command = plan

  variables {
    aks_service_cidr = "10.100.0.0"
  }

  expect_failures = [var.aks_service_cidr]
}

run "aks_service_cidr_rejects_a_host_address" {
  command = plan

  variables {
    aks_service_cidr = "10.100.0.5/16"
  }

  expect_failures = [var.aks_service_cidr]
}

run "aks_dns_service_ip_rejects_a_non_address" {
  command = plan

  variables {
    aks_dns_service_ip = "10.100.0"
  }

  expect_failures = [var.aks_dns_service_ip]
}
