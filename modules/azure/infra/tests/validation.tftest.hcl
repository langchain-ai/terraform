# Every validation block in the root variables.tf, asserted to reject a bad
# value. A validation that stops firing is invisible otherwise: the variable
# still accepts its good values, and the bad value now reaches Azure, where it
# comes back as a name or SKU error partway through an apply.
#
# Runs are grouped by the kind of value being rejected rather than one per
# variable. Terraform reports every validation error in one pass, so a group
# costs one plan and still names the variable whose expected failure is missing.

mock_provider "azurerm" {}
mock_provider "azapi" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
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
