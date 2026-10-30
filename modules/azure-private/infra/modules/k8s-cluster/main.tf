# ══════════════════════════════════════════════════════════════════════════════
# Module: aks
# Purpose: Azure Kubernetes Service cluster for running LangSmith workloads.
#
# Key design decisions (as-built — all hardcoded, not togglable):
#   • Azure CNI Overlay + Cilium eBPF data plane (hardcoded): pods draw IPs
#     from pod_cidr, not the VNet subnet — BYO subnets can be far smaller.
#     network_plugin_mode = "overlay", network_policy = "cilium",
#     network_data_plane = "cilium".
#   • Private API server (hardcoded): private_cluster_enabled = true — the
#     control-plane endpoint is a private IP only; apply must run from inside
#     the VNet or a peered network that resolves the private DNS zone.
#   • UDR egress (hardcoded): outbound_type = "userDefinedRouting" — all
#     cluster egress is routed through the caller's route table / firewall.
#   • Control-plane identity: user-assigned by default (create_cluster_identity
#     defaults to true). The module creates the identity and grants it Network
#     Contributor on the VNet before the cluster joins the subnet. Pass a BYO
#     identity via cluster_identity_id for a custom API-server private DNS zone.
#   • OIDC issuer + Workload Identity: allows Kubernetes service accounts to
#     federate with Azure AD and assume Managed Identities — used by LangSmith
#     pods to authenticate to Azure Blob Storage without static keys.
#
# Note: NGINX ingress, KEDA, and the K8s namespace/secrets are
# NOT installed by this module. They are installed by the separate bootstrap/
# root (run from the jumpbox after the cluster is up).
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # These MUST match the LangSmith chart's rendered ServiceAccount names
  # (<release>-<component.name>) for the blob-accessing components. The chart
  # derives them from each component's `name` value (e.g. fleetToolServer.name
  # = "fleet-tool-server"), so keep this list in sync with the chart version you
  # deploy — a mismatch means the pod's OIDC token has no federated credential
  # and blob/Key Vault access silently fails.
  service_accounts_for_workload_identity = [
    "${var.langsmith_release_name}-backend",
    "${var.langsmith_release_name}-platform-backend",
    "${var.langsmith_release_name}-queue",
    "${var.langsmith_release_name}-ingest-queue",
    "${var.langsmith_release_name}-host-backend",
    "${var.langsmith_release_name}-listener",
    "${var.langsmith_release_name}-fleet-tool-server",
    "${var.langsmith_release_name}-fleet-trigger-server",
  ]

  # Control-plane identity selection. Empty/false => system-assigned (default).
  # create_cluster_identity => use the module-created user-assigned identity;
  # otherwise a non-empty cluster_identity_id => use that BYO identity.
  use_user_assigned_identity = var.create_cluster_identity || var.cluster_identity_id != ""
  cluster_identity_id        = var.create_cluster_identity ? one(azurerm_user_assigned_identity.cluster[*].id) : var.cluster_identity_id

  # VNet that owns the AKS subnet — derived by stripping the /subnets/<name>
  # suffix. The module-created control-plane identity is granted Network
  # Contributor at this VNet scope so it can both join the subnet and link
  # the System private DNS zone (the zone link needs VNet-level permission
  # in custom-DNS hub-spoke topologies).
  cluster_vnet_id = join("/subnets/", slice(split("/subnets/", var.subnet_id), 0, 1))
}

# ── Control-plane (cluster) managed identity ───────────────────────────────────
# Default is system-assigned (see the identity block in the cluster resource).
# Set var.create_cluster_identity to have the module create a user-assigned
# identity and grant it Network Contributor on the VNet (the parent of
# var.subnet_id). VNet scope — not just the subnet — so the identity can both
# join the subnet (Microsoft.Network/virtualNetworks/subnets/join/action) AND
# link the System private DNS zone for a private cluster, which needs VNet-level
# permission in custom-DNS hub-spoke topologies. Azure recommends a user-assigned
# identity for BYO-VNet / UDR so the grant exists before the cluster joins the
# subnet. For a custom API-server private DNS zone, pass an existing identity via
# var.cluster_identity_id and pre-grant its roles (incl. Private DNS Zone
# Contributor on the zone) yourself.
resource "azurerm_user_assigned_identity" "cluster" {
  count               = var.create_cluster_identity ? 1 : 0
  name                = "${var.cluster_name}-cluster-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "aks" })
}

resource "azurerm_role_assignment" "cluster_identity_vnet" {
  count                = var.create_cluster_identity ? 1 : 0
  scope                = local.cluster_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.cluster[0].principal_id
}

# Give the Network Contributor grant time to propagate before the cluster tries
# to join the subnet (RBAC propagation is not instant). 60s is usually enough;
# cluster provisioning adds further buffer.
resource "time_sleep" "cluster_identity_rbac" {
  count           = var.create_cluster_identity ? 1 : 0
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.cluster_identity_vnet]
}

# The AKS cluster — the Kubernetes control plane + node pools.
# All LangSmith application pods, supporting tools (KEDA),
# and the ingress controller run here.
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = merge(var.tags, { module = "aks" })

  role_based_access_control_enabled = true

  # Private API server: always enabled — the control-plane endpoint is a private
  # IP reachable only from the VNet (or peered networks). The apply host must be
  # able to REACH that private IP (DNS resolution alone is not enough) — run
  # terraform from a bastion / self-hosted runner with VNet connectivity that
  # can also resolve the private DNS zone.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = var.private_cluster_public_fqdn_enabled
  private_dns_zone_id                 = var.private_dns_zone_id != "" ? var.private_dns_zone_id : "System"

  # OIDC issuer: exposes a discovery document at a well-known URL so Azure AD
  # can verify tokens issued by this cluster. Required for Workload Identity.
  oidc_issuer_enabled = true

  # Workload Identity: enables the mutating webhook that injects the OIDC
  # token into pods annotated with azure.workload.identity/use: "true".
  workload_identity_enabled = true

  # Default system node pool — runs kube-system, KEDA, NGINX,
  # and LangSmith services that don't require extra resources.
  default_node_pool {
    name = "default"

    # Standard_DS3_v2: 4 vCPU, 14 GB RAM — DSv2 family has broad quota availability.
    # LangSmith backend requests 100m CPU / 500Mi; all pods use lightweight mode.
    vm_size = var.default_node_pool_vm_size

    # Cluster autoscaler scales between min_count and max_count based on pending pods.
    auto_scaling_enabled = true
    min_count            = var.default_node_pool_min_count
    max_count            = var.default_node_pool_max_count

    # Azure CNI default is 30 pods/node — too low for a full LangSmith deployment.
    # Pass 2 alone deploys 17 pods; system pods (kube-system, KEDA) add ~15 more.
    # Setting to 60 fits all passes on 1 node, avoiding autoscaler scale-out and vCPU quota pressure.
    max_pods = var.default_node_pool_max_pods

    # Nodes live in the main subnet; Azure CNI assigns pod IPs from this range.
    vnet_subnet_id = var.subnet_id

    # Temporary node pool name used during node pool upgrades/rotations.
    # Required when auto_scaling_enabled = true and the pool is being replaced.
    temporary_name_for_rotation = "defaulttmp"

    zones = var.availability_zones
  }

  # Control-plane identity. Default: system-assigned (AKS manages its own
  # identity for node VMs, ACR pulls, and node resource group operations).
  # Opt-in user-assigned (var.create_cluster_identity or var.cluster_identity_id)
  # for BYO-VNet / UDR / a custom API-server private DNS zone.
  identity {
    type         = local.use_user_assigned_identity ? "UserAssigned" : "SystemAssigned"
    identity_ids = local.use_user_assigned_identity ? [local.cluster_identity_id] : null
  }

  # When the module creates the control-plane identity, wait for its Network
  # Contributor grant on the subnet to propagate before joining the subnet.
  # No-op (empty list) when using system-assigned or a BYO identity.
  depends_on = [time_sleep.cluster_identity_rbac]

  # Azure CNI Overlay + Cilium eBPF data plane + UDR egress — hardcoded.
  # Overlay: pods get IPs from pod_cidr (not from the VNet subnet), so pod IPs
  # do NOT consume subnet space — BYO subnets can be far smaller.
  # Cilium: eBPF-native network policy (stronger than Azure NPM); requires overlay.
  # UDR: all cluster egress is routed through the caller's route table / firewall.
  # service_cidr and pod_cidr must NOT overlap the VNet or any peered network.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "userDefinedRouting"
  }

  # Key Vault CSI Secrets Store driver — enables pods to mount secrets from
  # Azure Key Vault as files or environment variables via SecretProviderClass.
  # secret_rotation_enabled: the driver periodically re-reads secrets from KV
  # and updates mounted volumes so pods see rotated values without a restart.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  lifecycle {
    # upgrade_settings change during rolling node upgrades; ignore to prevent
    # drift between Terraform state and live cluster configuration.
    # zones: AKS does not support changing zones on an existing node pool —
    # it is only applied at creation time. Ignoring prevents forced recreation
    # when availability_zones is set on an existing cluster.
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      default_node_pool[0].zones,
    ]
  }
}

# Additional node pools for workloads that need different compute profiles.
# Default: one "large" pool (Standard_DS4_v2, 8 vCPU / 28 GB) for ClickHouse
# and other memory-intensive services. Scales 0→2 (scales to zero when idle).
resource "azurerm_kubernetes_cluster_node_pool" "node_pool" {
  for_each = var.additional_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = each.value.vm_size
  auto_scaling_enabled  = true
  vnet_subnet_id        = var.subnet_id
  min_count             = each.value.min_count
  max_count             = each.value.max_count
  tags                  = merge(var.tags, { module = "aks", pool = each.key })

  # "User" mode: these pools run application workloads.
  # "System" mode pools are reserved for system pods (kube-system).
  mode = "User"

  temporary_name_for_rotation = "${each.key}tmp"

  lifecycle {
    ignore_changes = [upgrade_settings]
  }
}

# ── Workload Identity ─────────────────────────────────────────────────────────
# User-Assigned Managed Identity for LangSmith pods.
# Centralised here because the AKS OIDC issuer URL (needed for federated
# credentials) is produced by this module. Having identity creation and
# federation in the same place avoids circular dependency.
resource "azurerm_user_assigned_identity" "k8s_app" {
  name                = var.workload_identity_name != "" ? var.workload_identity_name : "${var.cluster_name}-app-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "aks" })
}

# Federated Identity Credentials — bind each LangSmith K8s service account to
# the Managed Identity via OIDC. One credential per service account.
resource "azurerm_federated_identity_credential" "k8s_app" {
  for_each = toset(local.service_accounts_for_workload_identity)

  name                      = "langsmith-federated-${each.value}"
  user_assigned_identity_id = azurerm_user_assigned_identity.k8s_app.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:${var.langsmith_namespace}:${each.value}"
}

