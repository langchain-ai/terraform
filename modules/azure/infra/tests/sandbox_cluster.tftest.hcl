# sandbox_deployment_mode = "separate_cluster": a dedicated sandbox AKS cluster
# in the LangSmith VNet, its subnet and NSG, the identity's move to the sandbox
# cluster's issuer, the Secret written there, the LangSmith cluster without the
# same_cluster changes, and every refusal on terraform_data.sandbox_cluster_guard.
# sandboxes.tftest.hcl covers same_cluster. Mocked providers, so no credentials
# and no state.
#
# module.sandbox_aks is overridden in the root runs, so its outputs are known at
# plan and the provider built from them has values; the last runs plan the
# module on its own for the cluster and pool settings.

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
mock_provider "kubernetes" {
  alias = "sandbox"
}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

override_module {
  target = module.sandbox_aks
  outputs = {
    cluster_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg/providers/Microsoft.ContainerService/managedClusters/langsmith-sbox-aks"
    cluster_name           = "langsmith-sbox-aks"
    oidc_issuer_url        = "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/sandbox/"
    host                   = "https://langsmith-sbox-aks.hcp.eastus.azmk8s.io:443"
    client_certificate     = ""
    client_key             = ""
    cluster_ca_certificate = ""
    kube_auth              = "certificate"
    api_server_public_fqdn = false
    node_resource_group    = "MC_langsmith-rg_langsmith-sbox-aks_eastus"
  }
}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"

  enable_sandboxes             = true
  sandbox_deployment_mode      = "separate_cluster"
  langsmith_helm_chart_version = "0.18.0"
}

# ── The dedicated cluster ─────────────────────────────────────────────────────

run "separate_cluster_creates_the_sandbox_cluster" {
  command = plan

  assert {
    condition     = length(module.sandbox_aks) == 1 && length(terraform_data.sandbox_cluster_guard) == 1
    error_message = "separate_cluster did not plan the sandbox cluster"
  }
  assert {
    condition     = output.sandbox_cluster_name == "langsmith-sbox-aks" && output.sandbox_cluster_resource_group_name == output.resource_group_name
    error_message = "The sandbox cluster outputs do not name the cluster and its resource group"
  }
  assert {
    condition     = output.sandbox_deployment_mode == "separate_cluster" && output.sandbox_namespace == "langsmith-sandbox" && output.sandbox_service_account_name == "sandbox-host" && output.sandbox_runtime_secret_name == "langsmith-sandbox-runtime"
    error_message = "The outputs init-values.sh and create-k8s-secrets.sh read are not the defaults"
  }
  assert {
    condition     = output.sandbox_host_min_replicas == 1 && output.sandbox_host_max_replicas == 5
    error_message = "sandbox-host's replica bounds do not follow the sandbox pool variables"
  }
}

run "the_sandbox_cluster_takes_the_pool_and_the_cluster_settings" {
  command = plan

  variables {
    sandbox_host_vm_size         = "Standard_D16ds_v5"
    sandbox_host_min_count       = 2
    sandbox_host_max_count       = 7
    sandbox_system_node_vm_size  = "Standard_D2s_v5"
    sandbox_system_node_count    = 2
    sandbox_host_os_disk_size_gb = 300
  }

  # module.sandbox_aks's inputs are not readable through the override, so read
  # them off the locals that feed it.
  assert {
    condition     = local.sandbox_host_pool.vm_size == "Standard_D16ds_v5" && local.sandbox_host_pool.min_count == 2 && local.sandbox_host_pool.max_count == 7 && local.sandbox_host_pool.os_disk_size_gb == 300
    error_message = "The sandbox_host_* variables did not reach the sandbox pool"
  }
  assert {
    condition     = local.sandbox_host_pool.node_taints == ["sandbox.langsmith.com/host=true:NoSchedule"] && local.sandbox_host_pool.node_labels["sandbox.langsmith.com/host"] == "true"
    error_message = "The sandbox pool lost the label or taint the runtime chart selects and tolerates"
  }
  assert {
    condition     = output.sandbox_host_min_replicas == 2 && output.sandbox_host_max_replicas == 7
    error_message = "sandbox-host's replica bounds do not follow the sandbox pool"
  }
}

# ── The LangSmith cluster keeps its defaults ─────────────────────────────────

run "the_langsmith_cluster_gets_no_sandbox_changes" {
  command = plan

  assert {
    condition     = !contains(keys(local.effective_node_pools), "sandboxhost")
    error_message = "separate_cluster still added the sandboxhost pool to the LangSmith cluster"
  }
  assert {
    condition     = module.k8s_bootstrap.sandbox_juicefs_secret_name == null
    error_message = "separate_cluster still planned the JuiceFS Secret in the LangSmith namespace"
  }
  assert {
    condition     = contains(module.k8s_bootstrap.resource_quota_keys, "limits.cpu") && module.k8s_bootstrap.limit_range_default_limits != null
    error_message = "separate_cluster dropped limits from the LangSmith namespace quota"
  }
  assert {
    condition     = module.k8s_bootstrap.platform_backend_node_ingress == null
    error_message = "separate_cluster still admitted the LangSmith node subnet to platform-backend"
  }
}

# ── Identity, storage and the Secret in the sandbox cluster ──────────────────

run "the_federated_credential_moves_to_the_sandbox_cluster" {
  command = plan

  assert {
    condition     = azurerm_federated_identity_credential.sandbox_host[0].issuer == "https://eastus.oic.prod-aks.azure.com/00000000-0000-0000-0000-000000000000/sandbox/"
    error_message = "The sandbox-host federated credential does not trust the sandbox cluster's issuer: ${azurerm_federated_identity_credential.sandbox_host[0].issuer}"
  }
  assert {
    condition     = azurerm_federated_identity_credential.sandbox_host[0].subject == "system:serviceaccount:langsmith-sandbox:sandbox-host"
    error_message = "The federated credential subject is not the runtime's namespace and ServiceAccount: ${azurerm_federated_identity_credential.sandbox_host[0].subject}"
  }
  assert {
    condition     = azurerm_role_assignment.sandbox_host_blob[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/ls-rg/providers/Microsoft.Storage/storageAccounts/lsblobtest/blobServices/default/containers/sandbox-juicefs"
    error_message = "sandbox-host's Blob role is not scoped to the JuiceFS container"
  }
}

run "the_federated_credential_follows_namespace_and_service_account" {
  command = plan

  variables {
    sandbox_namespace            = "sbx"
    sandbox_service_account_name = "runtime"
  }

  assert {
    condition     = azurerm_federated_identity_credential.sandbox_host[0].subject == "system:serviceaccount:sbx:runtime" && output.sandbox_service_account_name == "runtime"
    error_message = "The federated credential subject did not follow sandbox_namespace and sandbox_service_account_name"
  }
}

run "the_sandbox_cluster_gets_the_namespace_and_juicefs_secret" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.sandbox[0].metadata[0].name == "langsmith-sandbox"
    error_message = "The sandbox namespace was not planned in the sandbox cluster"
  }
  assert {
    condition     = kubernetes_secret_v1.sandbox_cluster_juicefs[0].metadata[0].name == "juicefs-csi-config" && kubernetes_secret_v1.sandbox_cluster_juicefs[0].metadata[0].namespace == "langsmith-sandbox"
    error_message = "The JuiceFS config Secret was not planned in the sandbox namespace"
  }
  assert {
    condition     = local.sandbox_juicefs_config.storage == "wasb" && local.sandbox_juicefs_config.bucket == "https://sandbox-juicefs.core.windows.net" && local.sandbox_juicefs_config["access-key"] == module.blob.storage_account_name
    error_message = "The JuiceFS config does not name the container host and the storage account"
  }
}

# ── Network ───────────────────────────────────────────────────────────────────

run "the_sandbox_subnet_admits_sandbox_host_from_the_aks_subnet_only" {
  command = plan

  assert {
    condition     = local.create_sandbox_subnet && module.vnet.sandbox_nsg_rules != null
    error_message = "separate_cluster did not carve the sandbox subnet with its NSG"
  }
  assert {
    condition = length([
      for r in module.vnet.sandbox_nsg_rules : r
      if r.access == "Allow" && r.destination_port_range == "19190" && toset(r.source_address_prefixes) == toset(var.aks_subnet_address_prefix)
    ]) == 1
    error_message = "The sandbox NSG does not admit TCP 19190 from the AKS node subnet alone"
  }
  assert {
    condition = length([
      for r in module.vnet.sandbox_nsg_rules : r
      if r.access == "Allow" && r.priority == 110 && toset(r.source_address_prefixes) == toset(concat(var.sandbox_subnet_address_prefix, [var.aks_pod_cidr]))
    ]) == 1
    error_message = "The sandbox NSG does not admit the sandbox subnet and its overlay pod range"
  }
  assert {
    condition = length([
      for r in module.vnet.sandbox_nsg_rules : r
      if r.access == "Deny" && r.source_address_prefix == "VirtualNetwork" && r.priority == 4096
    ]) == 1
    error_message = "The sandbox NSG does not deny the rest of the VNet"
  }
}

run "same_cluster_plans_no_sandbox_cluster" {
  command = plan

  variables {
    sandbox_deployment_mode = "same_cluster"
  }

  assert {
    condition     = length(module.sandbox_aks) == 0 && length(kubernetes_namespace_v1.sandbox) == 0 && length(kubernetes_secret_v1.sandbox_cluster_juicefs) == 0 && length(terraform_data.sandbox_cluster_guard) == 0
    error_message = "same_cluster still planned the sandbox cluster or its objects"
  }
  assert {
    condition     = module.vnet.subnet_sandbox_id == null && module.vnet.sandbox_nsg_rules == null
    error_message = "same_cluster still carved the sandbox subnet"
  }
  assert {
    condition     = output.sandbox_cluster_name == null && output.sandbox_namespace == null && output.sandbox_deployment_mode == "same_cluster"
    error_message = "same_cluster still output the sandbox cluster"
  }
  assert {
    condition     = contains(keys(local.effective_node_pools), "sandboxhost")
    error_message = "same_cluster lost the sandboxhost pool"
  }
}

# ── Refusals ──────────────────────────────────────────────────────────────────

run "an_unpinned_chart_is_refused" {
  command = plan

  variables {
    langsmith_helm_chart_version = ""
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "a_chart_range_is_refused" {
  command = plan

  variables {
    langsmith_helm_chart_version = "~0.18.0"
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "a_0_17_chart_is_refused" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.17.4"
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "a_release_candidate_chart_is_accepted" {
  command = plan

  variables {
    langsmith_helm_chart_version = "0.18.0-rc.47"
  }

  assert {
    condition     = length(terraform_data.sandbox_cluster_guard) == 1
    error_message = "A 0.18 release candidate was refused"
  }
}

run "a_public_ingress_without_tls_is_refused" {
  command = plan

  variables {
    tls_certificate_source = "none"
    ingress_load_balancer  = "public"
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "an_internal_ingress_without_tls_is_accepted" {
  command = plan

  variables {
    tls_certificate_source = "none"
    ingress_load_balancer  = "internal"
    langsmith_domain       = "langsmith.internal.example.com"
  }

  assert {
    condition     = length(module.sandbox_aks) == 1
    error_message = "An internal ingress without TLS was refused"
  }
}

run "a_supplied_private_dns_zone_is_refused" {
  command = plan

  variables {
    aks_private_cluster_enabled   = true
    aks_private_dns_zone_id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/dns-rg/providers/Microsoft.Network/privateDnsZones/privatelink.eastus.azmk8s.io"
    aks_control_plane_identity    = "user"
    aks_control_plane_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/id-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/aks-cp"
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "an_additional_sandboxhost_pool_is_refused" {
  command = plan

  variables {
    additional_node_pools = {
      sandboxhost = {
        vm_size     = "Standard_D16ds_v5"
        min_count   = 0
        max_count   = 3
        node_labels = { "sandbox.langsmith.com/host" = "true" }
        node_taints = ["sandbox.langsmith.com/host=true:NoSchedule"]
      }
    }
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "an_undersized_sandbox_subnet_is_refused" {
  command = plan

  variables {
    sandbox_subnet_address_prefix = ["10.0.112.0/29"]
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

run "a_pod_range_inside_the_vnet_is_refused_on_a_node_subnet_cluster" {
  command = plan

  variables {
    aks_network_mode = "node-subnet"
    aks_pod_cidr     = "10.0.0.0/16"
  }

  expect_failures = [terraform_data.validate_network]
}

run "a_sandbox_subnet_overlapping_the_service_range_is_refused" {
  command = plan

  variables {
    sandbox_subnet_address_prefix = ["10.0.64.0/24"]
  }

  expect_failures = [terraform_data.validate_network]
}

run "a_sandbox_subnet_id_with_a_created_vnet_is_refused" {
  command = plan

  variables {
    sandbox_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/sandbox"
  }

  expect_failures = [terraform_data.validate_network]
}

# ── A supplied sandbox subnet ────────────────────────────────────────────────

run "a_supplied_sandbox_subnet_is_used_as_is" {
  command = plan

  variables {
    create_vnet       = false
    vnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
    aks_service_cidr  = "10.100.0.0/16"
    sandbox_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/sandbox"
  }

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = {
      address_space = ["10.0.0.0/16"]
      location      = "eastus"
      subnets       = []
    }
  }
  override_data {
    target = data.azurerm_subnet.byo_sandbox_subnet
    values = {
      address_prefixes  = ["10.0.200.0/24"]
      service_endpoints = ["Microsoft.Storage"]
    }
  }

  assert {
    condition     = output.sandbox_subnet_id == var.sandbox_subnet_id && module.vnet.subnet_sandbox_id == null
    error_message = "A supplied sandbox subnet was not used, or a subnet was still carved"
  }
}

run "a_supplied_sandbox_subnet_without_the_storage_endpoint_is_refused" {
  command = plan

  variables {
    create_vnet       = false
    vnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet"
    aks_service_cidr  = "10.100.0.0/16"
    sandbox_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/network-rg/providers/Microsoft.Network/virtualNetworks/shared-vnet/subnets/sandbox"
  }

  override_data {
    target = data.azurerm_virtual_network.byo_vnet
    values = {
      address_space = ["10.0.0.0/16"]
      location      = "eastus"
      subnets       = []
    }
  }
  override_data {
    target = data.azurerm_subnet.byo_sandbox_subnet
    values = {
      address_prefixes  = ["10.0.200.0/24"]
      service_endpoints = []
    }
  }

  expect_failures = [terraform_data.sandbox_cluster_guard]
}

# ── The sandbox-aks module on its own ────────────────────────────────────────

run "sandbox_aks_runs_overlay_with_a_critical_addons_system_pool" {
  command = plan

  module {
    source = "./modules/sandbox-aks"
  }

  variables {
    cluster_name        = "langsmith-sbox-aks"
    location            = "eastus"
    resource_group_name = "langsmith-rg"
    kubernetes_version  = "1.35"
    sku_tier            = "Standard"
    support_plan        = "KubernetesOfficial"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg/providers/Microsoft.Network/virtualNetworks/langsmith-vnet/subnets/langsmith-vnet-subnet-sandbox"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.64.0/20"
    dns_service_ip      = "10.0.64.10"
    system_node_vm_size = "Standard_D4s_v5"
    system_node_count   = 1
    sandbox_host_pool = {
      vm_size         = "Standard_D8ds_v5"
      min_count       = 0
      max_count       = 5
      node_labels     = { "sandbox.langsmith.com/host" = "true", "sandbox.langsmith.com/node-pool" = "host" }
      node_taints     = ["sandbox.langsmith.com/host=true:NoSchedule"]
      os_disk_size_gb = 200
    }
  }

  assert {
    condition     = azurerm_kubernetes_cluster.sandbox.network_profile[0].network_plugin_mode == "overlay" && azurerm_kubernetes_cluster.sandbox.network_profile[0].pod_cidr == "10.244.0.0/16"
    error_message = "The sandbox cluster does not run Azure CNI overlay on the pod range"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.sandbox.oidc_issuer_enabled && azurerm_kubernetes_cluster.sandbox.workload_identity_enabled
    error_message = "The sandbox cluster has no OIDC issuer or Workload Identity"
  }
  assert {
    condition     = azurerm_kubernetes_cluster.sandbox.default_node_pool[0].only_critical_addons_enabled && azurerm_kubernetes_cluster.sandbox.default_node_pool[0].node_count == 1
    error_message = "The system pool is not reserved for critical add-ons"
  }
  assert {
    condition     = tolist(azurerm_kubernetes_cluster_node_pool.sandbox_host.node_taints) == tolist(["sandbox.langsmith.com/host=true:NoSchedule"]) && azurerm_kubernetes_cluster_node_pool.sandbox_host.mode == "User" && azurerm_kubernetes_cluster_node_pool.sandbox_host.kubelet_disk_type == "OS"
    error_message = "The sandboxhost pool lost its taint, mode or kubelet disk"
  }
  assert {
    condition     = azurerm_kubernetes_cluster_node_pool.sandbox_host.vnet_subnet_id == var.subnet_id && azurerm_kubernetes_cluster.sandbox.default_node_pool[0].vnet_subnet_id == var.subnet_id
    error_message = "A sandbox pool is not in the sandbox subnet"
  }
  assert {
    condition     = output.kube_auth == "certificate" && output.api_server_public_fqdn == false
    error_message = "A public cluster without Entra should sign in by certificate"
  }
}

run "sandbox_aks_follows_entra_and_a_private_api_server" {
  command = plan

  module {
    source = "./modules/sandbox-aks"
  }

  variables {
    cluster_name            = "langsmith-sbox-aks"
    location                = "eastus"
    resource_group_name     = "langsmith-rg"
    kubernetes_version      = "1.35"
    sku_tier                = "Standard"
    support_plan            = "KubernetesOfficial"
    subnet_id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/langsmith-rg/providers/Microsoft.Network/virtualNetworks/langsmith-vnet/subnets/langsmith-vnet-subnet-sandbox"
    pod_cidr                = "10.244.0.0/16"
    service_cidr            = "10.0.64.0/20"
    dns_service_ip          = "10.0.64.10"
    system_node_vm_size     = "Standard_D4s_v5"
    system_node_count       = 1
    entra_only              = true
    private_cluster_enabled = true
    private_dns_zone_id     = "None"
    sandbox_host_pool = {
      vm_size         = "Standard_D8ds_v5"
      min_count       = 0
      max_count       = 5
      node_labels     = { "sandbox.langsmith.com/host" = "true" }
      node_taints     = ["sandbox.langsmith.com/host=true:NoSchedule"]
      os_disk_size_gb = 200
    }
  }

  assert {
    condition     = output.kube_auth == "entra" && azurerm_kubernetes_cluster.sandbox.local_account_disabled == true
    error_message = "An Entra-only sandbox cluster should disable local accounts and sign in with kubelogin"
  }
  assert {
    condition     = output.api_server_public_fqdn == true && azurerm_kubernetes_cluster.sandbox.private_cluster_public_fqdn_enabled == true && azurerm_kubernetes_cluster.sandbox.private_dns_zone_id == "None"
    error_message = "A private cluster with no zone needs its public FQDN"
  }
}
