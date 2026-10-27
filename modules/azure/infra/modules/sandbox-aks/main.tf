# ══════════════════════════════════════════════════════════════════════════════
# Module: sandbox-aks
# Purpose: The dedicated AKS cluster that runs the langsmith-sandbox chart when
#          sandbox_deployment_mode = "separate_cluster".
#
# A thin cluster on purpose. k8s-cluster declares a helm provider and installs
# the ingress controller and LangSmith's identities, and k8s-bootstrap declares
# its own kubernetes and helm providers, so neither can be created twice with
# count. This module declares no provider: the root gives the sandbox cluster
# its own aliased kubernetes provider from the outputs below.
#
# Two pools:
#   system      — the add-ons AKS marks critical (CoreDNS, konnectivity, the
#                 Workload Identity webhook). only_critical_addons_enabled taints
#                 it CriticalAddonsOnly, so nothing else lands there.
#   sandboxhost — sandbox-host and the JuiceFS format Job, with the label and
#                 taint the runtime chart selects and tolerates. Its VM size has
#                 to support nested virtualization so nodes expose /dev/kvm.
# The system pool is required here: AKS's own add-ons cannot be given the
# sandbox taint's toleration, so a cluster of tainted nodes alone never runs DNS.
#
# Pods take addresses from the overlay pod range, so only nodes draw from the
# sandbox subnet. sandbox-host runs on the host network and listens on its node
# address (TCP 19190), which is what the root's NSG on that subnet admits.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # Same switch as k8s-cluster: azurerm returns no client certificate for a
  # cluster with Entra integration, so the providers sign in with kubelogin.
  kube_auth = var.kube_auth == "auto" ? (var.entra_only ? "entra" : "certificate") : var.kube_auth

  # With no private DNS zone the API server resolves only through its public
  # FQDN, an A record to the private IP. Same rule as k8s-cluster.
  api_server_public_fqdn = var.private_cluster_enabled && var.private_dns_zone_id == "None"
  cluster_host           = local.api_server_public_fqdn && azurerm_kubernetes_cluster.sandbox.fqdn != "" ? "https://${azurerm_kubernetes_cluster.sandbox.fqdn}:443" : azurerm_kubernetes_cluster.sandbox.kube_config[0].host
}

resource "azurerm_kubernetes_cluster" "sandbox" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  support_plan        = var.support_plan
  tags                = merge(var.tags, { module = "sandbox-aks" })

  role_based_access_control_enabled = true

  # sandbox-host and the JuiceFS format Job reach the JuiceFS Blob container
  # through a federated credential on this issuer.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                         = "system"
    tags                         = merge(var.tags, { module = "sandbox-aks", pool = "system" })
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    only_critical_addons_enabled = true
    os_sku                       = var.os_sku
    vnet_subnet_id               = var.subnet_id
    temporary_name_for_rotation  = "systemtmp"
    zones                        = var.availability_zones
  }

  # System-assigned, which needs no grant on a subnet in the same subscription.
  identity {
    type = "SystemAssigned"
  }

  local_account_disabled = var.entra_only ? true : null

  dynamic "azure_active_directory_role_based_access_control" {
    for_each = var.entra_only ? [1] : []
    content {
      azure_rbac_enabled     = true
      admin_group_object_ids = var.entra_admin_group_object_ids
    }
  }

  private_cluster_enabled             = var.private_cluster_enabled
  private_dns_zone_id                 = var.private_cluster_enabled ? var.private_dns_zone_id : null
  private_cluster_public_fqdn_enabled = local.api_server_public_fqdn

  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  # No network policy engine: the cluster runs only sandbox-host, which is on
  # the host network, and the formatter. The subnet NSG does the filtering.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = var.outbound_type
  }

  lifecycle {
    # Same as k8s-cluster: rolling upgrades rewrite upgrade_settings, and a
    # zones edit would cycle the system pool without draining it.
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      default_node_pool[0].zones,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "sandbox_host" {
  name                  = "sandboxhost"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.sandbox.id
  mode                  = "User"
  vm_size               = var.sandbox_host_pool.vm_size
  auto_scaling_enabled  = true
  min_count             = var.sandbox_host_pool.min_count
  max_count             = var.sandbox_host_pool.max_count
  node_labels           = var.sandbox_host_pool.node_labels
  node_taints           = var.sandbox_host_pool.node_taints
  os_sku                = var.os_sku
  os_disk_size_gb       = var.sandbox_host_pool.os_disk_size_gb
  vnet_subnet_id        = var.subnet_id
  tags                  = merge(var.tags, { module = "sandbox-aks", pool = "sandboxhost" })

  # The JuiceFS cache and sandbox images live on the OS disk.
  kubelet_disk_type = "OS"

  temporary_name_for_rotation = "sandboxtmp"
  zones                       = length(var.availability_zones) > 0 ? var.availability_zones : null

  lifecycle {
    ignore_changes = [upgrade_settings, zones]
  }
}
