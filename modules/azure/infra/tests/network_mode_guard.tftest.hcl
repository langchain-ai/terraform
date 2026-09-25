# The network guard compares the profile requested in tfvars with the one Azure
# reports for the cluster at plan time, so it needs a cluster that already
# exists. Rather than apply the whole root against mocked providers, the
# cluster module is stubbed with the outputs it would have for a cluster in a
# given state (live_network_profile is what the guard reads), and each run
# plans a change against that. The guard compares mode, data plane, policy
# engine and pod range; with aks_allow_network_upgrade only the two in-place
# updates pass (azure to cilium; a policy engine installed where none runs). The file-level stub is a node-subnet cluster
# with Azure Network Policy Manager installed, which is what every cluster this
# module created before the mode became a choice looks like; runs that need a
# different cluster stub the module again for that run.

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

override_module {
  target = module.aks
  outputs = {
    cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
    cluster_name                       = "ls-aks-test"
    oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
    host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
    kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
    client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
    client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
    cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
    workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
    workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
    cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
    cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
    agw_public_ip_address              = ""
    agw_public_ip_fqdn                 = ""
    agw_name                           = ""
    agw_id                             = null
    live_network_profile               = { mode = "node-subnet", dataplane = "azure", policy = "azure", pod_cidr = null }
    network_profile                    = { network_plugin_mode = null, pod_cidr = null, network_data_plane = "azure", network_policy = "azure" }
    sku_tier                           = "Free"
    support_plan                       = "KubernetesOfficial"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
}

# ── The cluster as it is ─────────────────────────────────────────────────────

run "the_live_profile_plans_clean" {
  command = plan

  variables {
    aks_network_mode = "node-subnet"
  }
}

run "no_cluster_yet_plans_clean_in_either_mode" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = null
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "cilium", network_policy = "cilium" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  variables {
    aks_network_mode = "overlay"
  }
}

# ── Mode changes ─────────────────────────────────────────────────────────────

run "a_mode_change_is_refused_without_the_flag" {
  command = plan

  variables {
    aks_network_mode      = "overlay"
    aks_network_dataplane = "azure"
  }

  expect_failures = [terraform_data.aks_network_guard]
}

run "a_mode_change_is_refused_even_with_the_flag" {
  command = plan

  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

run "a_cluster_without_a_policy_engine_does_not_migrate_either" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "node-subnet", dataplane = "azure", policy = "none", pod_cidr = null }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "azure", network_policy = "azure" }
      sku_tier                           = "Free"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # The module would install the azure policy engine in the same apply as the
  # migration, which Azure does not support, so this is refused too.
  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

run "installing_a_policy_engine_where_none_runs_passes_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "node-subnet", dataplane = "azure", policy = "none", pod_cidr = null }
      network_profile                    = { network_plugin_mode = null, pod_cidr = null, network_data_plane = "azure", network_policy = "azure" }
      sku_tier                           = "Free"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # Only the policy engine changes, none to azure: the provider applies that in
  # place, so the flag lets it through.
  variables {
    aks_network_mode          = "node-subnet"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }
}

run "overlay_does_not_go_back_to_node_subnet_even_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "azure", policy = "azure", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = null, pod_cidr = null, network_data_plane = "azure", network_policy = "azure" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # The data plane is held at azure so that only the mode is changing here.
  variables {
    aks_network_mode          = "node-subnet"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

# ── Data plane changes ───────────────────────────────────────────────────────

run "a_data_plane_change_is_refused_without_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "azure", policy = "azure", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "cilium", network_policy = "cilium" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # Overlay with the data plane left to its default asks for cilium, which is
  # the edit an operator makes without noticing.
  variables {
    aks_network_mode = "overlay"
  }

  expect_failures = [terraform_data.aks_network_guard]
}

run "the_azure_data_plane_moves_to_cilium_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "azure", policy = "azure", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "cilium", network_policy = "cilium" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "cilium"
    aks_allow_network_upgrade = true
  }
}

run "cilium_does_not_go_back_to_azure_even_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "cilium", policy = "cilium", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "azure", network_policy = "azure" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

# ── Pod range ────────────────────────────────────────────────────────────────

run "a_pod_range_change_on_an_overlay_cluster_is_refused" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "cilium", policy = "cilium", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.250.0.0/16", network_data_plane = "cilium", network_policy = "cilium" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # No flag permits this one: Azure has no pod-range change, so it is always a
  # replacement.
  variables {
    aks_network_mode          = "overlay"
    aks_pod_cidr              = "10.250.0.0/16"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

# ── Policy engine ────────────────────────────────────────────────────────────

run "an_imported_calico_cluster_does_not_move_to_azure_even_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "azure", policy = "calico", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "azure", network_policy = "azure" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # calico to azure is a replacement in the provider, so the flag does not cover it.
  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "azure"
    aks_allow_network_upgrade = true
  }

  expect_failures = [terraform_data.aks_network_guard]
}

run "a_cluster_without_a_policy_engine_moves_to_cilium_with_the_flag" {
  command = plan

  override_module {
    target = module.aks
    outputs = {
      cluster_id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg-test/providers/Microsoft.ContainerService/managedClusters/ls-aks-test"
      cluster_name                       = "ls-aks-test"
      oidc_issuer_url                    = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/00000000-0000-0000-0000-000000000000/"
      host                               = "https://ls-aks-test-00000000.hcp.eastus.azmk8s.io:443"
      kube_config_raw                    = "apiVersion: v1\nkind: Config\n"
      client_certificate                 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      client_key                         = "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ=="
      cluster_ca_certificate             = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"
      workload_identity_client_id        = "11111111-1111-1111-1111-111111111111"
      workload_identity_principal_id     = "22222222-2222-2222-2222-222222222222"
      cert_manager_identity_client_id    = "33333333-3333-3333-3333-333333333333"
      cert_manager_identity_principal_id = "44444444-4444-4444-4444-444444444444"
      agw_public_ip_address              = ""
      agw_public_ip_fqdn                 = ""
      agw_name                           = ""
      agw_id                             = null
      live_network_profile               = { mode = "overlay", dataplane = "azure", policy = "none", pod_cidr = "10.244.0.0/16" }
      network_profile                    = { network_plugin_mode = "overlay", pod_cidr = "10.244.0.0/16", network_data_plane = "cilium", network_policy = "cilium" }
      sku_tier                           = "Standard"
      support_plan                       = "KubernetesOfficial"
    }
  }

  # Data plane azure to cilium and the engine none to cilium: both in place.
  variables {
    aks_network_mode          = "overlay"
    aks_network_dataplane     = "cilium"
    aks_allow_network_upgrade = true
  }
}
