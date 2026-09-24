# The network-mode guard compares the mode requested with the mode recorded at
# the cluster's first apply, so it needs a cluster that already exists. Rather
# than apply the whole root against mocked providers, the cluster module is
# stubbed with the outputs it would have after creating a node-subnet cluster,
# and each run plans a change against that.

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
    created_network_mode               = "node-subnet"
    network_profile                    = { network_plugin_mode = null, pod_cidr = null, network_data_plane = "azure", network_policy = "azure" }
    sku_tier                           = "Free"
    support_plan                       = "KubernetesOfficial"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
}

run "the_recorded_mode_plans_clean" {
  command = plan

  variables {
    aks_network_mode = "node-subnet"
  }
}

run "a_mode_change_is_refused_without_the_flag" {
  command = plan

  variables {
    aks_network_mode = "overlay"
  }

  expect_failures = [terraform_data.aks_network_mode_guard]
}

run "a_mode_change_is_permitted_with_the_flag" {
  command = plan

  variables {
    aks_network_mode                 = "overlay"
    aks_allow_network_mode_migration = true
  }
}
