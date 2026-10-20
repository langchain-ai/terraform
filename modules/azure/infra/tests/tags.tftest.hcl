# The tags variable reaches every resource a tag policy checks: the resource
# group, the cluster, and each node pool, which AKS tags separately from the
# cluster and applies to the pool's scale set and VMs. The SmithDB cache
# StorageClass carries the same set as its tags parameter, the only way the
# disk CSI driver tags the disks it creates. Pools are read through the
# cluster module's node_pool_tags output, keyed by pool name with the default
# pool under "default".

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
  name_prefix             = "test"
  unique_resource_names   = false
  owner                   = "platform-team@example.com"
  tags                    = { team = "platform", product = "langsmith" }
  additional_node_pools = {
    large = { vm_size = "Standard_D16s_v5", min_count = 0, max_count = 2 }
  }
}

run "tags_reach_the_resource_group_cluster_and_every_node_pool" {
  command = plan

  assert {
    condition     = azurerm_resource_group.resource_group[0].tags["team"] == "platform" && azurerm_resource_group.resource_group[0].tags["owner"] == "platform-team@example.com" && azurerm_resource_group.resource_group[0].tags["environment"] == "test"
    error_message = "The resource group should carry tags beside owner and environment"
  }

  assert {
    condition     = module.aks.cluster_tags["team"] == "platform" && module.aks.cluster_tags["product"] == "langsmith"
    error_message = "The cluster should carry tags, which AKS copies to the node resource group and its load balancer"
  }

  assert {
    condition     = module.aks.node_pool_tags["default"]["team"] == "platform" && module.aks.node_pool_tags["default"]["owner"] == "platform-team@example.com" && module.aks.node_pool_tags["default"]["pool"] == "default"
    error_message = "The default node pool should carry tags: AKS does not copy the cluster's tags to its scale set"
  }

  assert {
    condition     = module.aks.node_pool_tags["large"]["team"] == "platform" && module.aks.node_pool_tags["large"]["pool"] == "large"
    error_message = "An additional node pool should carry tags"
  }
}

run "a_tags_key_overrides_the_built_in_tag" {
  command = plan

  variables {
    tags = { environment = "production", managed_by = "platform" }
  }

  assert {
    condition     = azurerm_resource_group.resource_group[0].tags["environment"] == "production" && azurerm_resource_group.resource_group[0].tags["managed_by"] == "platform"
    error_message = "A key in tags should override environment and managed_by of the same name"
  }

  assert {
    condition     = module.aks.node_pool_tags["default"]["environment"] == "production"
    error_message = "The override should reach the node pools too"
  }
}

# Azure tag names are case-insensitive, so a key in another case replaces the
# built-in one rather than sitting beside it.
run "a_tags_key_overrides_the_built_in_tag_in_any_case" {
  command = plan

  variables {
    tags = { Environment = "prod", OWNER = "finance@example.com" }
  }

  assert {
    condition     = azurerm_resource_group.resource_group[0].tags["Environment"] == "prod" && !contains(keys(azurerm_resource_group.resource_group[0].tags), "environment")
    error_message = "Environment in tags should replace the built-in environment tag"
  }

  assert {
    condition     = azurerm_resource_group.resource_group[0].tags["OWNER"] == "finance@example.com" && !contains(keys(azurerm_resource_group.resource_group[0].tags), "owner")
    error_message = "OWNER in tags should replace the owner variable's tag"
  }
}

run "keys_that_differ_only_in_case_fail_the_plan" {
  command = plan

  variables {
    tags = { Team = "a", team = "b" }
  }

  expect_failures = [var.tags]
}

run "a_reserved_key_fails_the_plan" {
  command = plan

  variables {
    tags = { Component = "x" }
  }

  expect_failures = [var.tags]
}

# Private DNS zones and Key Vault secrets take at most 15 tags. With owner set,
# a secret carries environment, project, managed_by, owner, module, and
# component, leaving room for 9.
run "fifteen_tags_in_total_plan" {
  command = plan

  variables {
    tags = { for i in range(9) : "tag${i}" => "x" }
  }

  assert {
    condition     = length(azurerm_resource_group.resource_group[0].tags) == 13
    error_message = "Nine extra keys should plan, leaving the resource group with 13 tags and each Key Vault secret with 15"
  }
}

run "sixteen_tags_in_total_fail_the_plan" {
  command = plan

  variables {
    tags = { for i in range(10) : "tag${i}" => "x" }
  }

  expect_failures = [var.tags]
}

run "smithdb_cache_disks_carry_the_tags" {
  command = plan

  variables {
    enable_smithdb     = true
    availability_zones = ["1", "2", "3"]
  }

  assert {
    condition     = module.k8s_bootstrap.smithdb_cache_disk_tags == "environment=test,managed_by=terraform,owner=platform-team@example.com,product=langsmith,project=langsmith,team=platform"
    error_message = "The SmithDB cache StorageClass should list every tag as key=value pairs separated by commas"
  }
}

# The driver splits on the first = in each pair, so a value may hold one.
run "an_equals_sign_in_a_value_plans_with_smithdb" {
  command = plan

  variables {
    enable_smithdb     = true
    availability_zones = ["1", "2", "3"]
    tags               = { query = "a=b" }
  }

  assert {
    condition     = strcontains(module.k8s_bootstrap.smithdb_cache_disk_tags, "query=a=b")
    error_message = "A value holding = should reach the StorageClass as written"
  }
}

run "a_comma_in_a_tag_value_fails_the_plan_with_smithdb" {
  command = plan

  variables {
    enable_smithdb     = true
    availability_zones = ["1", "2", "3"]
    cost_center        = "finance, emea"
  }

  expect_failures = [terraform_data.validate_network]
}

run "a_comma_in_a_tag_value_plans_without_smithdb" {
  command = plan

  variables {
    cost_center = "finance, emea"
  }

  assert {
    condition     = azurerm_resource_group.resource_group[0].tags["cost_center"] == "finance, emea"
    error_message = "Without SmithDB, nothing splits the tags, so a comma in a value should plan"
  }
}
