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
  # The wiring suite's throwaway public key, for the runs that set
  # create_bastion = true: the empty default fails inside azurerm's own schema
  # validator, which would mask the precondition a run expects.
  bastion_admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDLvAeJ8tG7HNaDGXt2T05HJmj1X1qaP+jb2MTDRBLNEPOwsvT7UrCsGp/8AB5MZIyMmRLoNOz1GTRWWBQsgQoKJD1jPUJNvSDZ16g4yFV4wX2o6nxooi53U9L6JWH6XrXn2Ozhca7tC0o26Oyd2toFrf8An8H8Gnwsdr3EOIrqvL0ZxXvjgGLZDx9auENfrlrhob8+6QLsZkEzphDWqKhbYpy46WEYtwHvKRpYX1YlDN6jbObN0wifqu98UZNsIr7FoZR3luNj1bA/kjqUC61GW6UziPyCoMhk3Jf9IMQ24OBXn2Xp4JWMZ3jYp+IL1fi9YVgofvsOvlYM2XGtmgzt plan-tests-fixture"
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
    redis_clustering_policy        = "Enterprise"
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
    var.redis_clustering_policy,
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

    storage_private_endpoint_subnet_id = "endpoints-subnet"
    storage_private_dns_zone_id        = "privatelink.blob.core.windows.net"
  }

  expect_failures = [
    var.vnet_id,
    var.aks_subnet_id,
    var.postgres_subnet_id,
    var.redis_subnet_id,
    var.agic_subnet_id,
    var.bastion_subnet_id,
    var.storage_private_endpoint_subnet_id,
    var.storage_private_dns_zone_id,
  ]
}

run "name_prefix_rejects_a_trailing_hyphen" {
  command = plan

  variables {
    name_prefix = "prod-"
  }

  expect_failures = [var.name_prefix]
}

run "name_base_and_salt_reject_a_malformed_value" {
  command = plan

  variables {
    name_base        = "Contoso"
    name_suffix_salt = "rotate-2"
  }

  expect_failures = [
    var.name_base,
    var.name_suffix_salt,
  ]
}

# Each name pair belongs to one side of its create flag: the plain name pins
# what this module creates, the existing_ name picks what it attaches to. The
# defaults create both, so only the attach-side names can be wrong here.
run "attach_names_are_rejected_on_the_create_path" {
  command = plan

  variables {
    create_cluster               = true
    existing_cluster_name        = "ls-aks-prod"
    create_keyvault              = true
    existing_keyvault_name       = "ls-kv-prod"
    create_resource_group        = true
    existing_resource_group_name = "platform-langsmith-rg"
  }

  expect_failures = [
    var.existing_cluster_name,
    var.existing_keyvault_name,
    var.existing_resource_group_name,
  ]
}

# The resource group's pair runs the other way too: a pinned create-side name
# on the attach path would be ignored, so it is refused.
run "a_resource_group_name_is_rejected_on_the_attach_path" {
  command = plan

  variables {
    create_resource_group        = false
    existing_resource_group_name = "platform-langsmith-rg"
    resource_group_name          = "langsmith-rg-prod"
  }

  expect_failures = [var.resource_group_name]
}

run "attaching_a_resource_group_requires_its_name" {
  command = plan

  variables {
    create_resource_group        = false
    existing_resource_group_name = ""
  }

  expect_failures = [var.existing_resource_group_name]
}

# preflight.sh puts this name into a request URL, so a character outside
# Azure's grammar is refused here as well as there.
run "an_existing_resource_group_name_outside_azure_grammar_is_refused" {
  command = plan

  variables {
    create_resource_group        = false
    existing_resource_group_name = "rg/../other"
  }

  expect_failures = [var.existing_resource_group_name]
}

# blob_ttl_long_days carries two validations, and the second reads
# blob_ttl_short_days, so each rule gets a run of its own with the other value
# valid.

run "blob_ttl_short_days_rejects_zero" {
  command = plan

  variables {
    blob_ttl_short_days = 0
  }

  expect_failures = [var.blob_ttl_short_days]
}

run "blob_ttl_long_days_rejects_a_fraction" {
  command = plan

  variables {
    blob_ttl_short_days = 14
    blob_ttl_long_days  = 400.5
  }

  expect_failures = [var.blob_ttl_long_days]
}

run "blob_ttl_long_days_rejects_less_than_the_short_ttl" {
  command = plan

  variables {
    blob_ttl_short_days = 14
    blob_ttl_long_days  = 7
  }

  expect_failures = [var.blob_ttl_long_days]
}

run "langsmith_domain_is_required_for_dns01" {
  command = plan

  variables {
    tls_certificate_source = "dns01"
    langsmith_domain       = ""
  }

  expect_failures = [var.langsmith_domain]
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

# Presidio only serves the LLM Gateway, so asking for redaction without the
# gateway is refused, and the pair together plans.
run "gateway_pii_redaction_requires_the_gateway" {
  command = plan

  variables {
    enable_llm_gateway           = false
    enable_gateway_pii_redaction = true
  }

  expect_failures = [var.enable_gateway_pii_redaction]
}

run "gateway_pii_redaction_with_the_gateway_plans" {
  command = plan

  variables {
    enable_llm_gateway           = true
    enable_gateway_pii_redaction = true
  }
}

# ── VNet address space ───────────────────────────────────────────────────────

run "vnet_address_space_rejects_a_non_cidr" {
  command = plan

  variables {
    vnet_address_space = ["10.0.0.0"]
  }

  expect_failures = [var.vnet_address_space]
}

run "vnet_address_space_rejects_an_empty_list" {
  command = plan

  variables {
    vnet_address_space = []
  }

  expect_failures = [var.vnet_address_space]
}

run "vnet_address_space_rejects_a_host_address" {
  command = plan

  variables {
    vnet_address_space = ["10.0.0.5/17"]
  }

  expect_failures = [var.vnet_address_space]
}

# A moved VNet with every carved prefix moved inside it plans clean. The runs
# after it each leave one feature's prefix at its default, which sits inside
# 10.0.0.0/17 and so outside the moved space, and the containment precondition
# on terraform_data.validate_network has to catch it.

run "moved_vnet_address_space_plans_with_moved_prefixes" {
  command = plan

  variables {
    vnet_address_space             = ["172.16.0.0/16"]
    aks_subnet_address_prefix      = ["172.16.0.0/19"]
    postgres_subnet_address_prefix = ["172.16.32.0/20"]
    redis_subnet_address_prefix    = ["172.16.48.0/20"]
    agic_subnet_address_prefix     = ["172.16.96.0/24"]
    bastion_subnet_address_prefix  = ["172.16.80.0/27"]
    ingress_controller             = "agic"
    create_bastion                 = true
  }
}

run "moved_vnet_address_space_rejects_default_subnet_prefixes" {
  command = plan

  variables {
    vnet_address_space = ["172.16.0.0/16"]
  }

  expect_failures = [terraform_data.validate_network]
}

run "moved_vnet_address_space_rejects_a_default_agic_prefix" {
  command = plan

  variables {
    vnet_address_space             = ["172.16.0.0/16"]
    aks_subnet_address_prefix      = ["172.16.0.0/19"]
    postgres_subnet_address_prefix = ["172.16.32.0/20"]
    redis_subnet_address_prefix    = ["172.16.48.0/20"]
    ingress_controller             = "agic"
  }

  expect_failures = [terraform_data.validate_network]
}

run "moved_vnet_address_space_rejects_a_default_bastion_prefix" {
  command = plan

  variables {
    vnet_address_space             = ["172.16.0.0/16"]
    aks_subnet_address_prefix      = ["172.16.0.0/19"]
    postgres_subnet_address_prefix = ["172.16.32.0/20"]
    redis_subnet_address_prefix    = ["172.16.48.0/20"]
    create_bastion                 = true
  }

  expect_failures = [terraform_data.validate_network]
}

# The default aks_service_cidr, 10.0.64.0/20, sits inside the default VNet in
# the gap the default subnets leave. A subnet moved into that gap has to fail at
# plan, and moving aks_service_cidr out of its way has to clear it.

run "created_vnet_rejects_a_subnet_on_the_service_cidr" {
  command = plan

  variables {
    ingress_controller         = "agic"
    agic_subnet_address_prefix = ["10.0.64.0/24"]
  }

  expect_failures = [terraform_data.validate_network]
}

run "created_vnet_plans_a_subnet_beside_a_moved_service_cidr" {
  command = plan

  variables {
    ingress_controller         = "agic"
    agic_subnet_address_prefix = ["10.0.64.0/24"]
    aks_service_cidr           = "10.0.112.0/20"
  }
}

# ── Subnets already in a reused VNet ─────────────────────────────────────────
# Carving into someone else's VNet, the prefixes Terraform picks must miss the
# subnets already there. The VNet read returns only their names, so each one is
# read for its prefixes.

run "byo_vnet_plans_beside_a_clear_sibling" {
  command = plan

  variables {
    create_vnet      = false
    vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
    aks_service_cidr = "172.20.0.0/16"
  }

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = ["app-subnet"] }
  }
  override_data {
    target = data.azurerm_subnet.byo_vnet_siblings
    values = { address_prefixes = ["10.0.200.0/24"] }
  }

  assert {
    condition     = length(data.azurerm_subnet.byo_vnet_siblings) == 1
    error_message = "The sibling subnet was not read"
  }
}

run "byo_vnet_rejects_a_prefix_on_a_sibling" {
  command = plan

  variables {
    create_vnet      = false
    vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
    aks_service_cidr = "172.20.0.0/16"
  }

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = ["app-subnet"] }
  }
  # Inside the default aks_subnet_address_prefix, 10.0.0.0/19.
  override_data {
    target = data.azurerm_subnet.byo_vnet_siblings
    values = { address_prefixes = ["10.0.4.0/24"] }
  }

  expect_failures = [terraform_data.validate_network]
}

# After the first apply the carved subnets are in the VNet's list as well, and
# they overlap their own prefixes by definition.
run "byo_vnet_skips_the_subnets_terraform_carved" {
  command = plan

  variables {
    create_vnet      = false
    vnet_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
    aks_service_cidr = "172.20.0.0/16"
  }

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = { address_space = ["10.0.0.0/16"], location = "eastus", subnets = ["langsmith-vnet-subnet-0", "langsmith-vnet-subnet-postgres"] }
  }
  override_data {
    target = data.azurerm_subnet.byo_vnet_siblings
    values = { address_prefixes = ["10.0.0.0/19"] }
  }

  assert {
    condition     = length(data.azurerm_subnet.byo_vnet_siblings) == 0
    error_message = "A subnet Terraform carves was read as a sibling"
  }
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

# ── SmithDB gates ────────────────────────────────────────────────────────────
# Cross-variable, so preconditions on terraform_data.validate_network.

run "smithdb_gates_require_smithdb" {
  command = plan

  variables {
    enable_smithdb            = false
    smithdb_ingestion_enabled = true
  }

  expect_failures = [terraform_data.validate_network]
}

run "smithdb_migration_requires_ingestion" {
  command = plan

  variables {
    enable_smithdb            = true
    availability_zones        = ["1", "2", "3"]
    smithdb_ingestion_enabled = false
    smithdb_migration_enabled = true
  }

  expect_failures = [terraform_data.validate_network]
}

# ── Storage and ClusterIP rules ──────────────────────────────────────────────

# A private endpoint removes the public listener the allowlist writes rules for.
run "storage_allowlist_is_refused_with_private_endpoints" {
  command = plan

  variables {
    storage_private_endpoint_enabled = true
    storage_allowed_ips              = ["203.0.113.10"]
  }

  expect_failures = [terraform_data.validate_network]
}

# Both values are well formed on their own; the address is outside the range.
run "aks_dns_service_ip_outside_the_service_cidr_is_refused" {
  command = plan

  variables {
    aks_service_cidr   = "10.100.0.0/16"
    aks_dns_service_ip = "10.101.0.10"
  }

  expect_failures = [terraform_data.validate_network]
}

# ── Derived name lengths ─────────────────────────────────────────────────────
# Azure's per-service name limits are a precondition on the resource group, the
# first resource created, so an overlong name fails the plan instead of the
# apply partway through. One run per name, since the one precondition covers
# every name and expect_failures cannot tell them apart.

run "a_storage_account_name_over_24_characters_is_refused" {
  command = plan

  variables {
    storage_account_name = "lsblobprodeastus2contoso01"
  }

  expect_failures = [azurerm_resource_group.resource_group]
}

# Attaching creates no resource group, so the same check sits on the read of
# the existing one.
run "a_long_name_is_refused_when_attaching_a_resource_group" {
  command = plan

  variables {
    create_resource_group        = false
    existing_resource_group_name = "platform-langsmith-rg"
    storage_account_name         = "lsblobprodeastus2contoso01"
  }

  expect_failures = [data.azurerm_resource_group.existing]
}

run "a_keyvault_name_over_24_characters_is_refused" {
  command = plan

  variables {
    create_keyvault = true
    keyvault_name   = "ls-kv-prod-eastus2-contoso"
  }

  expect_failures = [azurerm_resource_group.resource_group]
}

run "a_postgres_name_over_63_characters_is_refused" {
  command = plan

  variables {
    postgres_source = "external"
    postgres_name   = "ls-postgres-production-eastus2-contoso-langsmith-self-hosted-001"
  }

  expect_failures = [azurerm_resource_group.resource_group]
}

run "a_redis_name_over_60_characters_is_refused" {
  command = plan

  variables {
    redis_source = "external"
    redis_name   = "ls-redis-production-eastus2-contoso-langsmith-self-hosted-001"
  }

  expect_failures = [azurerm_resource_group.resource_group]
}

run "a_cluster_name_over_63_characters_is_refused" {
  command = plan

  variables {
    create_cluster = true
    cluster_name   = "ls-aks-production-eastus2-contoso-langsmith-self-hosted-cluster1"
  }

  expect_failures = [azurerm_resource_group.resource_group]
}

# Every pool the module creates is Linux, so a Windows SKU is refused at the
# variable rather than failing inside the provider for want of os_type.
run "aks_os_sku_rejects_windows" {
  command = plan

  variables {
    aks_os_sku = "Windows2022"
  }

  expect_failures = [var.aks_os_sku]
}

run "additional_pool_os_sku_rejects_an_unknown_value" {
  command = plan

  variables {
    additional_node_pools = {
      large = { vm_size = "Standard_D16s_v3", min_count = 0, max_count = 2, os_sku = "Mariner" }
    }
  }

  expect_failures = [var.additional_node_pools]
}

# Ubuntu2404 arrived in azurerm 4.67.0 and versions.tf allows 4.65.0, where the
# provider rejects it; refused here until the floor moves.
run "aks_os_sku_rejects_ubuntu2404_below_the_provider_floor" {
  command = plan

  variables {
    aks_os_sku = "Ubuntu2404"
  }

  expect_failures = [var.aks_os_sku]
}

# install_cert_manager = false rules out DNS-01. The solver reaches the Azure DNS
# API as a Managed Identity bound to the pod by a workload-identity annotation
# Terraform adds only to the service account of a release it installs itself, so
# the pair applies cleanly and then fails every ACME challenge on an Azure auth
# error. The guard is a second validation block on tls_certificate_source, which
# is where it lives now that #133 removed the ClusterIssuer it used to hang on.
run "dns01_rejects_a_cert_manager_this_module_did_not_install" {
  command = plan

  variables {
    tls_certificate_source = "dns01"
    install_cert_manager   = false
    langsmith_domain       = "langsmith.example.com"
    letsencrypt_email      = "fixture@example.com"
  }

  expect_failures = [var.tls_certificate_source]
}
