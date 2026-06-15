# ══════════════════════════════════════════════════════════════════════════════
# Module: aks
# Purpose: Azure Kubernetes Service cluster for running LangSmith workloads.
#
# Key design decisions:
#   • Azure CNI: classic mode (default) gives pods VNet subnet IPs (full VNet
#     reachability to PostgreSQL/Redis). Azure CNI Overlay (network_plugin_mode
#     = "overlay") gives pods IPs from pod_cidr instead, so pod IPs do NOT
#     consume subnet space — BYO subnets can be far smaller. Overlay egress is
#     SNAT'd to the node IP. With overlay, network_policy must be calico or
#     cilium (not azure); cilium also enables the eBPF data plane.
#   • OIDC issuer + Workload Identity: allows Kubernetes service accounts to
#     federate with Azure AD and assume Managed Identities — used by LangSmith
#     pods to authenticate to Azure Blob Storage without static keys.
#   • Control-plane identity: system-assigned by default. Optionally
#     user-assigned (created by this module, or BYO) so its subnet-join
#     permission can be granted before cluster creation — recommended for
#     BYO-VNet / UDR and required for a custom API-server private DNS zone.
#   • Default node pool: Standard_DS3_v2 (4 vCPU, 14 GB RAM) — DSv2 family
#     has broad quota availability across subscriptions.
#   • Additional "large" pool: Standard_DS4_v2 (8 vCPU, 28 GB) for ClickHouse
#     and other stateful/memory-intensive workloads.
#   • NGINX ingress: deployed via Helm, exposes a single Azure Load Balancer
#     IP that routes to all LangSmith services by path/host.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  service_accounts_for_workload_identity = [
    "${var.langsmith_release_name}-backend",
    "${var.langsmith_release_name}-platform-backend",
    "${var.langsmith_release_name}-queue",
    "${var.langsmith_release_name}-ingest-queue",
    "${var.langsmith_release_name}-host-backend",
    "${var.langsmith_release_name}-listener",
    "${var.langsmith_release_name}-agent-builder-tool-server",
    "${var.langsmith_release_name}-agent-builder-trigger-server",
  ]

  # AGIC add-on identity — extracted from the cluster resource after apply.
  # Azure creates this identity automatically in the MC_ node resource group.
  # The identity needs 3 role assignments (see below).
  agic_addon_principal_id = (
    var.ingress_controller == "agic" &&
    length(azurerm_kubernetes_cluster.main.ingress_application_gateway) > 0 &&
    length(azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity) > 0
  ) ? azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id : null

  # Derive VNet resource ID from the AGIC subnet ID by stripping the /subnets/... suffix.
  # e.g. /subscriptions/.../virtualNetworks/langsmith-vnet-dz/subnets/langsmith-vnet-dz-subnet-agic
  #   →  /subscriptions/.../virtualNetworks/langsmith-vnet-dz
  agic_vnet_id = var.ingress_controller == "agic" && var.agic_subnet_id != "" ? (
    join("/subnets/", slice(split("/subnets/", var.agic_subnet_id), 0, 1))
  ) : ""

  # Control-plane identity selection. Empty/false => system-assigned (default).
  # create_cluster_identity => use the module-created user-assigned identity;
  # otherwise a non-empty cluster_identity_id => use that BYO identity.
  use_user_assigned_identity = var.create_cluster_identity || var.cluster_identity_id != ""
  cluster_identity_id        = var.create_cluster_identity ? one(azurerm_user_assigned_identity.cluster[*].id) : var.cluster_identity_id

  # VNet that owns the AKS subnet — derived by stripping the /subnets/<name>
  # suffix (same approach as agic_vnet_id). The module-created control-plane
  # identity is granted Network Contributor at this VNet scope so it can both
  # join the subnet and link the System private DNS zone (the zone link needs
  # VNet-level permission in custom-DNS hub-spoke topologies).
  cluster_vnet_id = join("/subnets/", slice(split("/subnets/", var.subnet_id), 0, 1))
}

# Helm provider uses the AKS cluster credentials to deploy charts
# (NGINX ingress, and later cert-manager/KEDA via k8s-bootstrap).
# Credentials come from the AKS resource itself — no external kubeconfig needed.
provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.main.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate)
  }
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
# All LangSmith application pods, supporting tools (cert-manager, KEDA),
# and the ingress controller run here.
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = merge(var.tags, { module = "aks" })

  role_based_access_control_enabled = true

  # Private API server: the control-plane endpoint gets a private IP reachable
  # only from the VNet (or peered networks). The apply host must be able to
  # REACH that private IP (DNS resolution alone is not enough) — run terraform
  # from a bastion / self-hosted runner with VNet connectivity that can also
  # resolve the private DNS zone. public_fqdn defaults to false (no public name).
  private_cluster_enabled             = var.private_cluster_enabled
  private_cluster_public_fqdn_enabled = var.private_cluster_enabled ? var.private_cluster_public_fqdn_enabled : null
  private_dns_zone_id                 = var.private_cluster_enabled ? (var.private_dns_zone_id != "" ? var.private_dns_zone_id : "System") : null

  # OIDC issuer: exposes a discovery document at a well-known URL so Azure AD
  # can verify tokens issued by this cluster. Required for Workload Identity.
  oidc_issuer_enabled = true

  # Workload Identity: enables the mutating webhook that injects the OIDC
  # token into pods annotated with azure.workload.identity/use: "true".
  workload_identity_enabled = true

  # Default system node pool — runs kube-system, cert-manager, KEDA, NGINX,
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
    # Pass 2 alone deploys 17 pods; system pods (kube-system, cert-manager, KEDA) add ~15 more.
    # Setting to 60 fits all passes on 1 node, avoiding autoscaler scale-out and vCPU quota pressure.
    max_pods = var.default_node_pool_max_pods

    # Nodes live in the main subnet; Azure CNI assigns pod IPs from this range.
    vnet_subnet_id = var.subnet_id

    # Temporary node pool name used during node pool upgrades/rotations.
    # Required when auto_scaling_enabled = true and the pool is being replaced.
    temporary_name_for_rotation = "defaulttmp"

    # max_surge = "0" prevents AKS from creating a temporary surge node during
    # node pool updates (e.g. max_pods change). Instead it drains the existing
    # node in-place. Required when vCPU quota is tight (surge needs quota for
    # a full extra node of the same VM size).
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

  # API server authorized IP ranges. Empty list (default) omits the block so
  # the master endpoint stays publicly reachable — required for the apply
  # host's Helm/kubectl steps that install cert-manager / KEDA / ESO and for
  # operators running ad-hoc kubectl from anywhere. Production deployments
  # populate var.authorized_ip_ranges with their CI runner / jumpbox CIDRs.
  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 && !var.private_cluster_enabled ? [1] : []
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  # Azure CNI. Two IPAM modes via network_plugin_mode:
  #   • classic (default, network_plugin_mode = ""): pods get IPs directly from
  #     the VNet subnet, giving full network reachability to PostgreSQL/Redis
  #     without NAT. Pods consume subnet IPs.
  #   • overlay (network_plugin_mode = "overlay"): pods get IPs from pod_cidr
  #     instead of the subnet (so pods do NOT consume subnet space); egress is
  #     SNAT'd to the node IP.
  # service_cidr (and pod_cidr in overlay) must NOT overlap the VNet or any
  # peered network.
  # network_policy selects the policy engine that makes NetworkPolicy resources
  # actually deny traffic (without one, NetworkPolicy objects are accepted but
  # never enforced): "azure" (NPM, classic default), "calico", or "cilium".
  # "cilium" requires overlay and auto-enables the eBPF data plane
  # (network_data_plane = "cilium"); it is the recommended engine for overlay.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = var.network_plugin_mode != "" ? var.network_plugin_mode : null
    network_policy      = var.network_policy
    network_data_plane  = var.network_policy == "cilium" ? "cilium" : null
    pod_cidr            = var.network_plugin_mode == "overlay" ? var.pod_cidr : null
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = var.outbound_type
  }

  # Key Vault CSI Secrets Store driver — enables pods to mount secrets from
  # Azure Key Vault as files or environment variables via SecretProviderClass.
  # secret_rotation_enabled: the driver periodically re-reads secrets from KV
  # and updates mounted volumes so pods see rotated values without a restart.
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Azure managed Istio add-on (Azure Service Mesh).
  # Enabled when ingress_controller = "istio-addon". Azure manages the Istio
  # control plane — no separate Helm install needed. Supports external and
  # internal ingress gateways backed by Azure Load Balancers.
  dynamic "service_mesh_profile" {
    for_each = var.ingress_controller == "istio-addon" ? [1] : []
    content {
      mode                             = "Istio"
      revisions                        = [var.istio_addon_revision]
      external_ingress_gateway_enabled = var.istio_external_gateway_enabled
      internal_ingress_gateway_enabled = var.istio_internal_gateway_enabled
    }
  }

  # AGIC add-on — Azure Application Gateway Ingress Controller (AKS managed).
  # Microsoft deprecated the AGIC Helm chart repo (appgwingress.blob.core.windows.net).
  # The AKS ingress_application_gateway add-on is the supported path going forward.
  # Azure manages the AGIC pod lifecycle; no separate Helm install required.
  dynamic "ingress_application_gateway" {
    for_each = var.ingress_controller == "agic" ? [1] : []
    content {
      gateway_id = azurerm_application_gateway.agw[0].id
    }
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

# cert-manager Managed Identity — used exclusively for DNS-01 ACME challenges.
# Separate from the LangSmith app identity so cert-manager only gets DNS Zone
# Contributor (not Storage Blob Contributor) and vice versa.
# The dns module grants DNS Zone Contributor to this identity's principal_id.
resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "${var.cluster_name}-cert-manager-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "aks" })
}

# Federated credential for cert-manager controller service account.
# Allows cert-manager pod to exchange its K8s OIDC token for an Azure AD token
# so it can call the Azure DNS API without a static service principal secret.
resource "azurerm_federated_identity_credential" "cert_manager" {
  name                      = "${var.cluster_name}-cert-manager-federated"
  user_assigned_identity_id = azurerm_user_assigned_identity.cert_manager.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject  = "system:serviceaccount:cert-manager:cert-manager"
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

# NGINX Ingress Controller — the single entry point for all HTTP(S) traffic.
# Creates an Azure Standard Load Balancer with a public IP.
# Routes traffic to LangSmith services by host/path via Ingress rules.
# cert-manager integrates with NGINX to automate TLS certificate provisioning.
resource "helm_release" "nginx_ingress" {
  count      = var.ingress_controller == "nginx" ? 1 : 0
  name       = "ingress-nginx"
  namespace  = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"

  create_namespace = true

  values = [
    yamlencode({
      controller = {
        replicaCount = 2

        # Dedicated health-check endpoint that always returns 200.
        # Azure LB HTTP probes hit /nginx-health on the NodePort — this returns 200
        # so backends are never marked unhealthy. More reliable than TCP probes because
        # the AKS cloud controller manager respects the request-path annotation on every
        # reconcile cycle (e.g. after autoscaler node add/remove), whereas the protocol
        # annotation is only applied at service creation time.
        config = {
          server-snippet = <<-EOT
            location /nginx-health {
              access_log off;
              return 200 "healthy\n";
              add_header Content-Type text/plain;
            }
          EOT
        }

        service = {
          type = "LoadBalancer"
          annotations = merge(
            {
              # Keep HTTP probes (default) but point them at /nginx-health which always 200s.
              # This survives every CCM reconcile: protocol stays Http, path stays /nginx-health.
              "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/nginx-health"
            },
            var.dns_label != "" ? {
              # Public IP DNS label → <label>.<region>.cloudapp.azure.com (free, no extra resource)
              "service.beta.kubernetes.io/azure-dns-label-name" = var.dns_label
            } : {}
          )
        }
      }
    })
  ]
}

# ── Istio (self-managed Helm) ──────────────────────────────────────────────────
# Used when ingress_controller = "istio". Installs istio-base (CRDs), istiod
# (control plane), and istio-ingressgateway (external LB) into istio-system.
# For Azure-managed Istio, use ingress_controller = "istio-addon" instead —
# it enables the AKS service mesh add-on via service_mesh_profile on the cluster.

# istio-base: installs the Istio CRDs (VirtualService, Gateway, DestinationRule, etc.)
# into the cluster. Must be applied first — istiod and the gateway depend on these CRDs.
resource "helm_release" "istio_base" {
  count      = var.ingress_controller == "istio" ? 1 : 0
  name       = "istio-base"
  namespace  = "istio-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_version

  create_namespace = true
}

# istiod: the Istio control plane — manages service mesh policy, certificate
# rotation, and injects Envoy sidecars into pods in mesh-enabled namespaces.
resource "helm_release" "istiod" {
  count      = var.ingress_controller == "istio" ? 1 : 0
  name       = "istiod"
  namespace  = "istio-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version

  # Enable Kubernetes Ingress support in istiod.
  # Without meshConfig.ingressControllerMode, istiod ignores Ingress resources
  # and the istio-ingressgateway has no routes — site returns connection refused.
  # ingressClass must match the ingressClassName used in LangSmith Helm values.
  set {
    name  = "meshConfig.ingressControllerMode"
    value = "STRICT"
  }
  set {
    name  = "meshConfig.ingressClass"
    value = "istio"
  }

  depends_on = [helm_release.istio_base]
}

# Istio ingress gateway: the external-facing Load Balancer for all LangSmith traffic.
# Replaces NGINX when Istio is in use. Gateway + VirtualService resources
# (in use-cases/istio/) route traffic to LangSmith services.
resource "helm_release" "istio_gateway" {
  count      = var.ingress_controller == "istio" && var.istio_external_gateway_enabled ? 1 : 0
  name       = "istio-ingressgateway"
  namespace  = "istio-system"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.istio_version

  depends_on = [helm_release.istiod]
}

# ── AGIC (Application Gateway Ingress Controller) ─────────────────────────────
# Provisions an Azure Application Gateway v2 and installs the AGIC Helm chart.
# AGIC watches Kubernetes Ingress resources with ingressClassName: azure/application-gateway
# and programs AGW routing rules dynamically. Auth uses Workload Identity (ARM auth).
#
# Prerequisites: agic_subnet_id must point to a dedicated /24+ subnet in the same VNet.
# The AGW itself has a placeholder backend/listener/rule — AGIC overwrites these.
# ignore_changes lifecycle prevents Terraform from reverting AGIC-managed state.

# Public IP for the Application Gateway frontend.
# dns_label sets a DNS name: <dns_label>.<region>.cloudapp.azure.com on the AGW public IP.
# For AGIC, the DNS label is set directly on the Azure public IP resource (not via K8s annotation).
resource "azurerm_public_ip" "agw" {
  count               = var.ingress_controller == "agic" ? 1 : 0
  name                = "${var.cluster_name}-agw-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.dns_label != "" ? var.dns_label : null
  tags                = merge(var.tags, { module = "aks", component = "agic" })
}

# Application Gateway v2 — AGIC manages all routing rules after initial creation.
# The placeholder backend/listener/rule below satisfies the required AGW schema;
# AGIC replaces them with actual LangSmith routing on first reconcile.
resource "azurerm_application_gateway" "agw" {
  count               = var.ingress_controller == "agic" ? 1 : 0
  name                = "${var.cluster_name}-agw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "aks", component = "agic" })

  sku {
    name     = var.agw_sku_tier
    tier     = var.agw_sku_tier
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "agw-ip-config"
    subnet_id = var.agic_subnet_id
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_port {
    name = "https"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "agw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.agw[0].id
  }

  # Placeholder backend pool — AGIC replaces this with actual pod endpoints.
  backend_address_pool {
    name = "placeholder-backend"
  }

  backend_http_settings {
    name                  = "placeholder-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "placeholder-listener"
    frontend_ip_configuration_name = "agw-frontend-ip"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "placeholder-rule"
    rule_type                  = "Basic"
    http_listener_name         = "placeholder-listener"
    backend_address_pool_name  = "placeholder-backend"
    backend_http_settings_name = "placeholder-http-settings"
    priority                   = 1
  }

  lifecycle {
    # AGIC manages these resources after initial creation.
    # Ignoring prevents Terraform from overwriting AGIC-programmed routing rules
    # on every subsequent apply.
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      frontend_port,
      http_listener,
      probe,
      request_routing_rule,
      redirect_configuration,
      ssl_certificate,
      url_path_map,
      tags,
    ]
  }

  depends_on = [azurerm_public_ip.agw]
}

# ── AGIC add-on identity role assignments ─────────────────────────────────────
# The AKS ingress_application_gateway add-on creates its own managed identity
# (ingressapplicationgateway-<cluster> in the MC_ resource group).
# Azure does NOT automatically grant the required permissions — they must be
# assigned explicitly. Three permissions are required:
#   1. Reader on the resource group (discover AGW and related resources)
#   2. Contributor on the Application Gateway (update routing rules)
#   3. Network Contributor on the VNet (subnet join action for AGW subnet)
#
# The add-on identity object_id is exposed via:
#   azurerm_kubernetes_cluster.main.ingress_application_gateway[0]
#     .ingress_application_gateway_identity[0].object_id
# Both agic_addon_principal_id and agic_vnet_id are defined in the locals block at the top of this file.
#
# Root cause: AKS creates the AGIC managed identity during cluster provisioning, but the identity
# is not immediately usable for RBAC evaluation. Role assignments created too soon result in
# persistent 403 errors from the AGIC controller even though the assignments exist in ARM.
# A 5-minute wait after cluster creation allows Azure AD to fully register the identity.
resource "time_sleep" "agic_identity_propagation" {
  count           = var.ingress_controller == "agic" ? 1 : 0
  create_duration = "300s"
  depends_on      = [azurerm_kubernetes_cluster.main]
}

resource "azurerm_role_assignment" "agic_rg_reader" {
  count                = var.ingress_controller == "agic" ? 1 : 0
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Reader"
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  depends_on           = [time_sleep.agic_identity_propagation]
}

resource "azurerm_role_assignment" "agic_agw_contributor" {
  count                = var.ingress_controller == "agic" ? 1 : 0
  scope                = azurerm_application_gateway.agw[0].id
  role_definition_name = "Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  depends_on           = [azurerm_application_gateway.agw, time_sleep.agic_identity_propagation]
}

resource "azurerm_role_assignment" "agic_vnet_network_contributor" {
  count                = var.ingress_controller == "agic" ? 1 : 0
  scope                = local.agic_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
  depends_on           = [time_sleep.agic_identity_propagation]
}

# ── Envoy Gateway ─────────────────────────────────────────────────────────────
# CNCF Gateway API implementation. Uses Gateway/HTTPRoute resources (not classic Ingress).
# Published via OCI registry — no separate Helm repository needed.
# After install: create a GatewayClass + Gateway + HTTPRoute to expose LangSmith.
# See: helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml

resource "helm_release" "envoy_gateway" {
  count     = var.ingress_controller == "envoy-gateway" ? 1 : 0
  name      = "envoy-gateway"
  namespace = "envoy-gateway-system"
  chart     = "oci://docker.io/envoyproxy/gateway-helm"
  version   = var.envoy_gateway_version

  create_namespace = true

  values = [
    yamlencode({
      deployment = {
        envoyGateway = {
          resources = {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
          }
        }
      }
    })
  ]
}
