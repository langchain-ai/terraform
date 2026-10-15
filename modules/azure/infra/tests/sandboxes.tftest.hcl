# enable_sandboxes, in both directions: the sandbox-host pool, the JuiceFS
# Redis and Blob container, the sandbox-host identity, and the namespace changes
# sandbox-host needs. Mocked providers, so no credentials and no state.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  # Known at plan, so the container-scoped role assignment can be asserted.
  mock_resource "azurerm_storage_account" {
    override_during = plan
    defaults = {
      id                    = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Storage/storageAccounts/lsblobtest"
      primary_blob_endpoint = "https://lsblobtest.blob.core.windows.net/"
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
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
}

run "sandboxes_absent_when_disabled" {
  command = plan

  variables {
    enable_sandboxes = false
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 0 && length(azurerm_storage_container.sandbox_juicefs) == 0 && length(azurerm_user_assigned_identity.sandbox_host) == 0
    error_message = "enable_sandboxes = false still planned sandbox infrastructure"
  }
  assert {
    condition     = !contains(keys(local.effective_node_pools), "sandboxhost")
    error_message = "enable_sandboxes = false still added the sandboxhost pool"
  }
  assert {
    condition     = module.k8s_bootstrap.sandbox_juicefs_secret_name == null
    error_message = "enable_sandboxes = false still planned the JuiceFS Secret"
  }
  assert {
    condition     = contains(module.k8s_bootstrap.resource_quota_keys, "limits.cpu") && module.k8s_bootstrap.limit_range_default_limits != null
    error_message = "enable_sandboxes = false dropped limits from the namespace quota"
  }
  assert {
    condition     = module.k8s_bootstrap.platform_backend_node_ingress == null
    error_message = "enable_sandboxes = false still admitted the node subnet to platform-backend"
  }
  assert {
    condition     = output.sandbox_host_min_replicas == null && output.sandbox_host_max_replicas == null
    error_message = "enable_sandboxes = false still output sandbox-host replica bounds"
  }
}

run "sandboxes_present_when_enabled" {
  command = plan

  variables {
    enable_sandboxes      = true
    sandbox_host_vm_size  = "Standard_D8ds_v4"
    sandbox_juicefs_name  = "sandbox-juicefs"
    unique_resource_names = true
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1 && length(azurerm_storage_container.sandbox_juicefs) == 1 && length(azurerm_user_assigned_identity.sandbox_host) == 1
    error_message = "enable_sandboxes = true did not plan the JuiceFS Redis, container and identity"
  }
  assert {
    condition     = local.effective_node_pools["sandboxhost"].vm_size == "Standard_D8ds_v4"
    error_message = "sandbox_host_vm_size did not reach the sandboxhost pool"
  }
  assert {
    condition     = local.effective_node_pools["sandboxhost"].node_taints == ["sandbox.langsmith.com/host=true:NoSchedule"]
    error_message = "sandboxhost pool lost the taint the chart's default toleration matches"
  }
  assert {
    condition     = azurerm_federated_identity_credential.sandbox_host[0].subject == "system:serviceaccount:langsmith:langsmith-sandbox-host"
    error_message = "Federated credential subject is not the chart's sandbox-host ServiceAccount: ${azurerm_federated_identity_credential.sandbox_host[0].subject}"
  }
  assert {
    condition     = azurerm_role_assignment.sandbox_host_blob[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Storage/storageAccounts/lsblobtest/blobServices/default/containers/sandbox-juicefs"
    error_message = "sandbox-host's Blob role is not scoped to the JuiceFS container"
  }
  assert {
    condition     = module.k8s_bootstrap.sandbox_juicefs_secret_name == "juicefs-csi-config"
    error_message = "enable_sandboxes = true did not plan the JuiceFS Secret"
  }
  assert {
    condition     = !contains(module.k8s_bootstrap.resource_quota_keys, "limits.cpu")
    error_message = "enable_sandboxes = true kept limits in the namespace quota"
  }
  assert {
    condition     = module.k8s_bootstrap.limit_range_default_limits == null
    error_message = "enable_sandboxes = true kept default limits in the LimitRange"
  }
  assert {
    condition     = tolist(module.k8s_bootstrap.platform_backend_node_ingress.cidrs) == tolist(var.aks_subnet_address_prefix) && tolist(module.k8s_bootstrap.platform_backend_node_ingress.ports) == tolist(["TCP/1986"])
    error_message = "enable_sandboxes = true under Azure NPM did not admit the node subnet to platform-backend :1986 alone"
  }
}

# Cilium on AKS never matches a node IP by ipBlock, so the node-subnet policy is
# left to deploy.sh's CiliumNetworkPolicy there, and kept on overlay with NPM.
run "node_subnet_policy_skipped_on_cilium" {
  command = plan

  variables {
    enable_sandboxes = true
    aks_network_mode = "overlay"
  }

  assert {
    condition     = output.network_policy_engine == "cilium" && module.k8s_bootstrap.platform_backend_node_ingress == null
    error_message = "Cilium still planned the node-subnet NetworkPolicy, or the engine output is not cilium: ${output.network_policy_engine}"
  }
}

run "node_subnet_policy_kept_on_overlay_npm" {
  command = plan

  variables {
    enable_sandboxes      = true
    aks_network_mode      = "overlay"
    aks_network_dataplane = "azure"
  }

  assert {
    condition     = output.network_policy_engine == "azure" && tolist(module.k8s_bootstrap.platform_backend_node_ingress.cidrs) == tolist(var.aks_subnet_address_prefix) && tolist(module.k8s_bootstrap.platform_backend_node_ingress.ports) == tolist(["TCP/1986"])
    error_message = "Overlay with Azure NPM did not admit the node subnet to platform-backend :1986"
  }
}

# The sandbox-host pool follows sizing_profile when sandbox_host_vm_size is null.
run "sandbox_host_vm_size_follows_sizing_profile" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_host_vm_size = null
    sizing_profile       = "production"
  }

  assert {
    condition     = local.effective_node_pools["sandboxhost"].vm_size == "Standard_D32ds_v5"
    error_message = "sizing_profile = production did not size sandboxhost at Standard_D32ds_v5"
  }
}

# An additional_node_pools entry named sandboxhost replaces the generated pool.
run "additional_node_pools_overrides_sandboxhost" {
  command = plan

  variables {
    enable_sandboxes = true
    additional_node_pools = {
      sandboxhost = {
        vm_size     = "Standard_D16ds_v6"
        min_count   = 1
        max_count   = 2
        node_labels = { "sandbox.langsmith.com/host" = "true" }
        node_taints = ["sandbox.langsmith.com/host=true:NoSchedule"]
      }
    }
  }

  assert {
    condition     = local.effective_node_pools["sandboxhost"].vm_size == "Standard_D16ds_v6"
    error_message = "additional_node_pools.sandboxhost did not replace the generated pool"
  }
  assert {
    condition     = output.sandbox_host_min_replicas == 1 && output.sandbox_host_max_replicas == 2
    error_message = "Replica bounds did not follow the additional_node_pools.sandboxhost counts"
  }
}

# The chart's sandbox-host autoscaler follows the pool: minReplicas is min_count
# raised to the chart minimum of 1, and maxReplicas is max_count.
run "sandbox_host_replicas_follow_the_pool_defaults" {
  command = plan

  variables {
    enable_sandboxes = true
  }

  assert {
    condition     = output.sandbox_host_min_replicas == 1 && output.sandbox_host_max_replicas == 5
    error_message = "Default pool (0 to 5) did not give replicas 1 to 5: ${output.sandbox_host_min_replicas} to ${output.sandbox_host_max_replicas}"
  }
}

run "sandbox_host_replicas_follow_the_pool_counts" {
  command = plan

  variables {
    enable_sandboxes       = true
    sandbox_host_min_count = 2
    sandbox_host_max_count = 8
  }

  assert {
    condition     = output.sandbox_host_min_replicas == 2 && output.sandbox_host_max_replicas == 8
    error_message = "Pool 2 to 8 did not give replicas 2 to 8: ${output.sandbox_host_min_replicas} to ${output.sandbox_host_max_replicas}"
  }
}

# The sandbox-host pool takes availability_zones like any other pool, so
# SmithDB's rule against regional pools on a zoned cluster accepts it.
run "sandboxhost_follows_availability_zones" {
  command = plan

  variables {
    enable_sandboxes   = true
    enable_smithdb     = true
    availability_zones = ["1", "2", "3"]
  }

  assert {
    condition     = toset(module.aks.node_pool_zones["sandboxhost"]) == toset(["1", "2", "3"])
    error_message = "The sandboxhost pool did not follow availability_zones"
  }
}

run "sandboxhost_os_disk_defaults_to_200_gb" {
  command = plan

  variables {
    enable_sandboxes = true
  }

  assert {
    condition     = local.aks_managed_node_pools["sandboxhost"].os_disk_size_gb == 200
    error_message = "The sandboxhost pool did not default to a 200 GB OS disk"
  }
}

run "sandboxhost_os_disk_follows_the_variable" {
  command = plan

  variables {
    enable_sandboxes             = true
    sandbox_host_os_disk_size_gb = 512
  }

  assert {
    condition     = local.aks_managed_node_pools["sandboxhost"].os_disk_size_gb == 512
    error_message = "The sandboxhost pool did not take sandbox_host_os_disk_size_gb"
  }
}

run "sandbox_host_os_disk_below_30_gb_is_rejected" {
  command = plan

  variables {
    enable_sandboxes             = true
    sandbox_host_os_disk_size_gb = 20
  }

  expect_failures = [var.sandbox_host_os_disk_size_gb]
}

run "sandboxhost_is_regional_without_availability_zones" {
  command = plan

  variables {
    enable_sandboxes   = true
    availability_zones = []
  }

  assert {
    condition     = module.aks.node_pool_zones["sandboxhost"] == null
    error_message = "The sandboxhost pool planned zones on a nonzonal cluster"
  }
}

# With redis_source = external the JuiceFS Redis registers in the LangSmith
# Redis's private DNS zone: Azure rejects a second privatelink.redis.azure.net
# link in the same VNet. With in-cluster Redis it creates the zone itself. Each
# run pins the one zone that should exist, so a zone created in the wrong
# module leaves the asserted ID unknown or different.
run "juicefs_redis_shares_the_dns_zone_with_external_redis" {
  command = plan

  variables {
    enable_sandboxes = true
    redis_source     = "external"
  }

  override_resource {
    target          = module.redis[0].azurerm_private_dns_zone.redis[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net"
    }
  }

  assert {
    condition     = module.sandbox_juicefs_redis[0].private_dns_zone_id == module.redis[0].private_dns_zone_id
    error_message = "The JuiceFS Redis did not register in the LangSmith Redis's private DNS zone"
  }
}

run "juicefs_redis_owns_the_dns_zone_with_in_cluster_redis" {
  command = plan

  variables {
    enable_sandboxes = true
    redis_source     = "in-cluster"
  }

  override_resource {
    target          = module.sandbox_juicefs_redis[0].azurerm_private_dns_zone.redis[0]
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net"
    }
  }

  assert {
    condition     = length(module.redis) == 0 && module.sandbox_juicefs_redis[0].private_dns_zone_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/privateDnsZones/privatelink.redis.azure.net"
    error_message = "With no LangSmith AMR, the JuiceFS Redis did not create its own private DNS zone"
  }
}

run "sandbox_host_max_below_min_is_rejected" {
  command = plan

  variables {
    enable_sandboxes       = true
    sandbox_host_min_count = 3
    sandbox_host_max_count = 2
  }

  expect_failures = [terraform_data.validate_network]
}

run "sandboxes_rejected_in_azure_government" {
  command = plan

  variables {
    enable_sandboxes  = true
    azure_environment = "usgovernment"
    redis_source      = "in-cluster"
  }

  expect_failures = [terraform_data.validate_network]
}

run "disabling_sandboxes_is_refused_under_the_redis_guard" {
  command = plan

  variables {
    enable_sandboxes                      = false
    sandbox_juicefs_redis_prevent_destroy = true
  }

  expect_failures = [terraform_data.validate_network]
}

run "the_redis_guard_allows_sandboxes_on" {
  command = plan

  variables {
    enable_sandboxes                      = true
    sandbox_juicefs_redis_prevent_destroy = true
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "The Redis guard blocked a plan with sandboxes on"
  }
}

# The bucket is https://<container>.<blob suffix>, which JuiceFS splits into
# the container name and the endpoint. A wrong suffix fails only at mount time.
run "juicefs_bucket_is_the_container_host" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_juicefs_name = "sandbox-juicefs"
  }

  assert {
    condition     = local.sandbox_juicefs_bucket == "https://sandbox-juicefs.core.windows.net"
    error_message = "JuiceFS bucket is not https://<container>.core.windows.net: ${local.sandbox_juicefs_bucket}"
  }
}

# The chart names the ServiceAccount after the release fullname, which appends
# -langsmith to a release name without it.
run "sandbox_host_subject_follows_the_release_name" {
  command = plan

  variables {
    enable_sandboxes       = true
    langsmith_release_name = "ls"
  }

  assert {
    condition     = azurerm_federated_identity_credential.sandbox_host[0].subject == "system:serviceaccount:langsmith:ls-langsmith-sandbox-host"
    error_message = "Federated credential subject did not follow langsmith_release_name: ${azurerm_federated_identity_credential.sandbox_host[0].subject}"
  }
}

# The regex alone admits up to 125 characters, because each -x group counts once.
run "sandbox_juicefs_name_over_63_characters_is_rejected" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_juicefs_name = "ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-ab-a"
  }

  expect_failures = [var.sandbox_juicefs_name]
}

# Azure persists an AMR database only with HA on, so AOF follows HA.
run "juicefs_redis_writes_aof_with_ha" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name                = "ls-juicefs-test"
    location            = "eastus"
    resource_group_name = "ls-rg"
    resource_group_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/virtualNetworks/ls-vnet/subnets/aks"
    vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/virtualNetworks/ls-vnet"
    amr_sku             = "Balanced_B1"
    clustering_policy   = "NoCluster"
    eviction_policy     = "NoEviction"
    high_availability   = true
    aof_persistence     = true
  }

  assert {
    condition     = azapi_resource.amr_db.body.properties.persistence == { aofEnabled = true, aofFrequency = "1s" }
    error_message = "aof_persistence = true did not send AOF persistence"
  }
}

run "juicefs_redis_sends_no_persistence_without_it" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name                = "ls-juicefs-test"
    location            = "eastus"
    resource_group_name = "ls-rg"
    resource_group_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/virtualNetworks/ls-vnet/subnets/aks"
    vnet_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Network/virtualNetworks/ls-vnet"
    amr_sku             = "Balanced_B0"
    clustering_policy   = "NoCluster"
    eviction_policy     = "NoEviction"
    high_availability   = false
    aof_persistence     = false
  }

  assert {
    condition     = !contains(keys(azapi_resource.amr_db.body.properties), "persistence")
    error_message = "aof_persistence = false still sent a persistence block"
  }
}
