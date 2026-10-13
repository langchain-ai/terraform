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
    condition     = alltrue([for v in values(module.k8s_bootstrap.network_policy_excluded_components) : length(v) == 0])
    error_message = "enable_sandboxes = false narrowed the default-deny selector"
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
    condition     = module.k8s_bootstrap.network_policy_excluded_components == { "default-deny-ingress" = ["langsmith-platform-backend"], "allow-from-ingress" = ["langsmith-platform-backend"] }
    error_message = "enable_sandboxes = true did not leave platform-backend out of both default-deny policies"
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
