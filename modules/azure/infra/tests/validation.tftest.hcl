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

# ── AKS network mode, data plane and tier ────────────────────────────────────

run "aks_network_enums_reject_an_unlisted_value" {
  command = plan

  variables {
    aks_network_mode      = "kubenet"
    aks_network_dataplane = "calico"
    aks_sku_tier          = "Basic"
    aks_support_plan      = "Extended"
  }

  expect_failures = [
    var.aks_network_mode,
    var.aks_network_dataplane,
    var.aks_sku_tier,
    var.aks_support_plan,
  ]
}

run "aks_pod_cidr_rejects_a_non_cidr" {
  command = plan

  variables {
    aks_pod_cidr = "10.244.0.0"
  }

  expect_failures = [var.aks_pod_cidr]
}

run "aks_pod_cidr_rejects_a_host_address" {
  command = plan

  variables {
    aks_pod_cidr = "10.244.0.5/16"
  }

  expect_failures = [var.aks_pod_cidr]
}

run "aks_pod_cidr_rejects_a_range_smaller_than_a_24" {
  command = plan

  variables {
    aks_pod_cidr = "10.244.0.0/26"
  }

  expect_failures = [var.aks_pod_cidr]
}

# Cross-variable rules are preconditions on terraform_data.validate_network, so
# that is the object expected to fail.

run "cilium_requires_overlay_mode" {
  command = plan

  variables {
    aks_network_mode      = "node-subnet"
    aks_network_dataplane = "cilium"
  }

  expect_failures = [terraform_data.validate_network]
}

run "long_term_support_requires_the_premium_tier" {
  command = plan

  variables {
    aks_sku_tier     = "Standard"
    aks_support_plan = "AKSLongTermSupport"
  }

  expect_failures = [terraform_data.validate_network]
}

# The three overlay preconditions live on terraform_data.validate_network with
# the subnet capacity check, so that is the object expected to fail.

run "overlay_pod_cidr_rejects_an_overlap_with_the_vnet" {
  command = plan

  variables {
    aks_network_mode = "overlay"
    aks_pod_cidr     = "10.0.0.0/16" # the created VNet is 10.0.0.0/17
  }

  expect_failures = [terraform_data.validate_network]
}

run "overlay_pod_cidr_rejects_an_aks_reserved_range" {
  command = plan

  variables {
    aks_network_mode = "overlay"
    aks_pod_cidr     = "172.30.0.0/16" # clear of the VNet and the ClusterIP range; reserved by AKS
  }

  expect_failures = [terraform_data.validate_network]
}

run "overlay_pod_cidr_rejects_too_small_a_range_for_the_pools" {
  command = plan

  variables {
    aks_network_mode = "overlay"
    aks_pod_cidr     = "10.244.0.0/22" # four /24s; the pools below reach 11 + 3 nodes with surge
    # Pinned rather than inherited: terraform test auto-loads a terraform.tfvars
    # from this directory when one exists, and the capacity arithmetic below
    # assumes these pools.
    default_node_pool_max_count = 10
    default_node_pool_max_pods  = 60
    additional_node_pools = {
      large = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2 }
    }
  }

  expect_failures = [terraform_data.validate_network]
}

# The same /27 AKS subnet (27 usable addresses) is enough for the pinned pools'
# 14 nodes in overlay mode and nowhere near the 11 x 61 + 3 x 31 addresses
# node-subnet mode needs. Both runs together show the capacity check switches
# with the mode.

run "overlay_subnet_capacity_counts_nodes_only" {
  command = plan

  variables {
    aks_network_mode          = "overlay"
    aks_subnet_address_prefix = ["10.0.0.0/27"]
    # Pinned rather than inherited: terraform test auto-loads a terraform.tfvars
    # from this directory when one exists, and the capacity arithmetic below
    # assumes these pools.
    default_node_pool_max_count = 10
    default_node_pool_max_pods  = 60
    additional_node_pools = {
      large = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2 }
    }
  }
}

run "node_subnet_capacity_counts_pods_too" {
  command = plan

  variables {
    aks_network_mode          = "node-subnet"
    aks_subnet_address_prefix = ["10.0.0.0/27"]
    # Pinned rather than inherited: terraform test auto-loads a terraform.tfvars
    # from this directory when one exists, and the capacity arithmetic below
    # assumes these pools.
    default_node_pool_max_count = 10
    default_node_pool_max_pods  = 60
    additional_node_pools = {
      large = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2 }
    }
  }

  expect_failures = [terraform_data.validate_network]
}
