# ══════════════════════════════════════════════════════════════════════════════
# Module: aks
# Purpose: Azure Kubernetes Service cluster for running LangSmith workloads.
#
# Key design decisions:
#   • Azure CNI network plugin: pods get IPs directly from the subnet, enabling
#     full VNet connectivity (pods can reach PostgreSQL/Redis by private IP).
#     Tradeoff: uses more IPs than kubenet, but required for private DB access.
#   • OIDC issuer + Workload Identity: allows Kubernetes service accounts to
#     federate with Azure AD and assume Managed Identities — used by LangSmith
#     pods to authenticate to Azure Blob Storage without static keys.
#   • System-assigned Managed Identity: AKS manages its own identity for
#     pulling images, accessing node resource group, and VMSS operations.
#   • Default node pool: Standard_D8s_v3 (8 vCPU, 32 GB RAM) — Dsv3 family,
#     the production baseline (matches the root module default). DSv2
#     (DS3_v2 / DS4_v2) is the documented fallback when Dsv3 quota is short.
#   • Additional "large" pool: Standard_D16s_v3 (16 vCPU, 64 GB) for ClickHouse
#     and other stateful/memory-intensive workloads.
#   • NGINX ingress: deployed via Helm, exposes a single Azure Load Balancer
#     IP that routes to all LangSmith services by path/host.
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # azurerm reports an unzoned default node pool as null, not [], so the drift
  # check below has to normalize before toset() and sort() ever see it. one()
  # also folds away the count, returning null when create_cluster = false.
  live_node_pool_zones = (
    one(azurerm_kubernetes_cluster.main[*].default_node_pool[0].zones) == null
    ? toset([])
    : toset(one(azurerm_kubernetes_cluster.main[*].default_node_pool[0].zones))
  )

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

  # AGIC add-on identity — extracted from the cluster resource after apply.
  # Azure creates this identity automatically in the MC_ node resource group.
  # The identity needs 3 role assignments (see below).
  # var.create_cluster is checked first so that with create_cluster = false the
  # count = 0 resource is never indexed here — otherwise an "Invalid index" error
  # would fire alongside (and obscure) the data source's precondition message.
  agic_addon_principal_id = (
    var.create_cluster &&
    var.ingress_controller == "agic" &&
    length(azurerm_kubernetes_cluster.main[0].ingress_application_gateway) > 0 &&
    length(azurerm_kubernetes_cluster.main[0].ingress_application_gateway[0].ingress_application_gateway_identity) > 0
  ) ? azurerm_kubernetes_cluster.main[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id : null

  # Derive VNet resource ID from the AGIC subnet ID by stripping the /subnets/... suffix.
  # e.g. /subscriptions/.../virtualNetworks/langsmith-vnet-dz/subnets/langsmith-vnet-dz-subnet-agic
  #   →  /subscriptions/.../virtualNetworks/langsmith-vnet-dz
  agic_vnet_id = var.ingress_controller == "agic" && var.agic_subnet_id != "" ? (
    join("/subnets/", slice(split("/subnets/", var.agic_subnet_id), 0, 1))
  ) : ""

  # Whether this module builds the AGIC stack (gateway, public IP, add-on identity
  # role grants) or only consumes one that already exists. Enabling the add-on is an
  # argument on the cluster resource, so on an attached cluster Terraform cannot turn
  # it on and the customer enables it themselves against their own gateway. That makes
  # the gateway and its RBAC grants theirs too: re-creating the grants here would
  # collide with the ones az aks enable-addons already made (RoleAssignmentExists),
  # and the gateway is not ours to manage. The postcondition below is what catches an
  # attached cluster that never had the add-on turned on.
  agic_managed = var.ingress_controller == "agic" && var.create_cluster

  # Unified accessors so the rest of this module doesn't care whether the cluster
  # was created here or already existed — resolves to the resource when
  # create_cluster = true, or the read-only data source when false.
  cluster_id              = var.create_cluster ? azurerm_kubernetes_cluster.main[0].id : data.azurerm_kubernetes_cluster.existing[0].id
  cluster_name_actual     = var.create_cluster ? azurerm_kubernetes_cluster.main[0].name : data.azurerm_kubernetes_cluster.existing[0].name
  cluster_oidc_issuer_url = var.create_cluster ? azurerm_kubernetes_cluster.main[0].oidc_issuer_url : data.azurerm_kubernetes_cluster.existing[0].oidc_issuer_url
  cluster_kube_config     = var.create_cluster ? azurerm_kubernetes_cluster.main[0].kube_config : data.azurerm_kubernetes_cluster.existing[0].kube_config
  cluster_kube_config_raw = var.create_cluster ? azurerm_kubernetes_cluster.main[0].kube_config_raw : data.azurerm_kubernetes_cluster.existing[0].kube_config_raw

  # var.location for a cluster created here, so the location check below is
  # trivially satisfied and only has something to say under create_cluster = false.
  cluster_location = var.create_cluster ? var.location : data.azurerm_kubernetes_cluster.existing[0].location
}

# Read-only lookup of a pre-existing AKS cluster (BYOC). Never creates, modifies,
# or deletes the customer's cluster — Terraform only reads its attributes so the
# Managed Identities/federated credentials/node pools below can attach to it.
data "azurerm_kubernetes_cluster" "existing" {
  count               = var.create_cluster ? 0 : 1
  name                = var.cluster_name
  resource_group_name = var.existing_cluster_resource_group_name

  lifecycle {
    precondition {
      # Without this the lookup falls back to the derived "langsmith-aks<id>"
      # name and Azure reports a missing cluster, which reads like a permissions
      # or region problem rather than an unset variable.
      condition     = var.cluster_name != ""
      error_message = "create_cluster = false requires existing_cluster_name to be set to the name of the AKS cluster to attach to."
    }

    precondition {
      # Not derived from resource_group_name. That is the resource group this
      # module creates for Key Vault and Storage, which is not where a cluster
      # the customer's platform team owns lives, so guessing it produces a
      # "cluster not found" naming a resource group the operator never mentioned.
      condition     = var.existing_cluster_resource_group_name != ""
      error_message = "create_cluster = false requires existing_cluster_resource_group_name to be set to the resource group holding cluster '${var.cluster_name}'. Find it with: az aks list --query \"[?name=='${var.cluster_name}'].resourceGroup\" -o tsv"
    }

    precondition {
      # 'istio-addon' (Azure Service Mesh) is configured through service_mesh_profile,
      # an argument on the azurerm_kubernetes_cluster *resource* block. With
      # create_cluster = false that resource doesn't exist in this module's state, so
      # the mesh would silently never get configured rather than erroring. 'agic' is
      # no longer rejected here: it needs the same resource-only argument to be turned
      # on, but unlike the mesh it is usable on an attached cluster when the customer
      # has already enabled the add-on, which the postcondition below checks for.
      condition     = var.ingress_controller != "istio-addon"
      error_message = "ingress_controller = 'istio-addon' requires create_cluster = true — Azure Service Mesh is configured through service_mesh_profile on a Terraform-owned cluster resource, and this module cannot enable it on a cluster it only reads. Use 'istio' for the self-managed Helm install, or 'nginx', 'agic', or 'envoy-gateway'."
    }

    precondition {
      # A subnet Terraform is about to carve can never be one the cluster's nodes
      # already run in, so the postcondition below could never pass. Catching the
      # combination here names the real problem; left to the postcondition it
      # reads as a subnet mismatch instead of an impossible configuration.
      condition     = !var.create_vnet
      error_message = "create_cluster = false requires create_vnet = false. An attached cluster's nodes already run in an existing subnet, and Terraform cannot carve a new one they belong to. Set create_vnet = false and supply vnet_id plus the subnet ids."
    }

    precondition {
      # Under create_cluster = false there is nothing to derive this from, and the
      # postcondition that would catch a blank value compares it against the
      # cluster's agent pools — a comparison that reports a mismatch rather than
      # an unset variable.
      condition     = var.existing_cluster_subnet_id != ""
      error_message = "create_cluster = false requires aks_subnet_id to be set to a subnet cluster '${var.cluster_name}' already runs nodes in. It also drives the Blob and Key Vault firewall allowlists, so it cannot be left for Terraform to derive."
    }

    postcondition {
      # Federated credentials below use the cluster's OIDC issuer URL as their
      # trust anchor. Without the issuer the URL is empty and every credential is
      # created pointing at nothing — pods then fail to authenticate to Blob
      # Storage/Key Vault at runtime, long after a "successful" apply.
      condition     = self.oidc_issuer_enabled
      error_message = "Existing cluster '${var.cluster_name}' does not have the OIDC issuer enabled, which Workload Identity federation requires. Enable both on the cluster first: az aks update --name ${var.cluster_name} --resource-group ${var.existing_cluster_resource_group_name} --enable-oidc-issuer --enable-workload-identity"
    }

    postcondition {
      # The root module feeds this same subnet to the default-deny Blob firewall
      # and the Key Vault network ACLs, so it has to be a subnet the cluster's
      # nodes actually run in. Point it anywhere else and apply succeeds, pods
      # schedule, and every Blob write and Key Vault read 403s at runtime. It's
      # also the only subnet an added node pool can join, since a node pool can
      # only live in its cluster's VNet.
      condition     = contains(compact(self.agent_pool_profile[*].vnet_subnet_id), var.existing_cluster_subnet_id)
      error_message = "aks_subnet_id must be one of the subnets cluster '${var.cluster_name}' already runs nodes in, because it also drives the Blob and Key Vault firewall allowlists. Set aks_subnet_id to one of: [${join(", ", compact(self.agent_pool_profile[*].vnet_subnet_id))}]"
    }

    postcondition {
      # Enabling ingress-appgw is an argument on the cluster resource, so on an
      # attached cluster the add-on has to already be on. Without this the apply
      # succeeds having created no gateway and no IngressClass, and the failure
      # surfaces later as LangSmith Ingress objects that no controller ever picks up.
      # This only proves the add-on exists. It cannot prove the add-on identity holds
      # the three role assignments AGIC needs, because ARM has no way to list
      # assignments by principal from Terraform — an under-permissioned identity still
      # 403s at runtime, so the README documents how to verify the grants.
      condition     = var.ingress_controller != "agic" || length(self.ingress_application_gateway) > 0
      error_message = "ingress_controller = 'agic' on an attached cluster requires the ingress-appgw add-on to already be enabled on cluster '${var.cluster_name}', because Terraform can only enable it on a cluster it creates. Enable it against your Application Gateway first: az aks enable-addons --name ${var.cluster_name} --resource-group ${var.existing_cluster_resource_group_name} --addons ingress-appgw --appgw-id <application-gateway-resource-id>"
    }
  }
}

# Workload Identity has to be enabled on top of the OIDC issuer — they're
# separate AKS flags, so "issuer on, Workload Identity off" is a reachable state
# that passes the check above, applies cleanly, and then leaves pods without a
# projected service account token. The azurerm data source doesn't expose the
# flag, so read the cluster's ARM properties directly. Read-only GET, no writes.
data "azapi_resource" "existing_security_profile" {
  count                  = var.create_cluster ? 0 : 1
  type                   = "Microsoft.ContainerService/managedClusters@2024-09-01"
  resource_id            = data.azurerm_kubernetes_cluster.existing[0].id
  response_export_values = ["properties.securityProfile.workloadIdentity.enabled"]

  lifecycle {
    postcondition {
      condition     = try(self.output.properties.securityProfile.workloadIdentity.enabled, false)
      error_message = "Existing cluster '${var.cluster_name}' has the OIDC issuer enabled but not Workload Identity, so the federated credentials this module creates would never mint a token. Enable it: az aks update --name ${var.cluster_name} --resource-group ${var.existing_cluster_resource_group_name} --enable-oidc-issuer --enable-workload-identity"
    }
  }
}

# Key Vault, Blob, PostgreSQL, and Redis are all created in var.location, which
# nothing ties to the region the existing cluster runs in. A mismatch works, at
# the cost of cross-region latency and egress on every trace write, so warn
# rather than fail — a deliberate split-region deployment stays possible.
check "existing_cluster_location" {
  assert {
    # Azure accepts both "East US" and "eastus" for the same region.
    condition     = lower(replace(local.cluster_location, " ", "")) == lower(replace(var.location, " ", ""))
    error_message = "Cluster '${var.cluster_name}' runs in ${local.cluster_location} but location is set to ${var.location}. Key Vault, Blob, PostgreSQL, and Redis will be created in ${var.location}, so pod traffic to them crosses regions."
  }
}

# Helm provider uses the AKS cluster credentials to deploy charts
# (NGINX ingress, and later cert-manager/KEDA via k8s-bootstrap).
# Credentials come from the AKS cluster (created here or pre-existing) —
# no external kubeconfig needed.
provider "helm" {
  kubernetes {
    host                   = local.cluster_kube_config[0].host
    client_certificate     = base64decode(local.cluster_kube_config[0].client_certificate)
    client_key             = base64decode(local.cluster_kube_config[0].client_key)
    cluster_ca_certificate = base64decode(local.cluster_kube_config[0].cluster_ca_certificate)
  }
}

# The AKS cluster — the Kubernetes control plane + node pools.
# All LangSmith application pods, supporting tools (cert-manager, KEDA),
# and the ingress controller run here.
# count = 0 when attaching to a pre-existing cluster (create_cluster = false);
# see data.azurerm_kubernetes_cluster.existing above for that path.
resource "azurerm_kubernetes_cluster" "main" {
  count               = var.create_cluster ? 1 : 0
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = merge(var.tags, { module = "aks" })

  role_based_access_control_enabled = true

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

    # Default Standard_D8s_v3: 8 vCPU, 32 GB RAM — Dsv3 family, the production baseline.
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

  # System-assigned Managed Identity: AKS uses this to manage node VMs,
  # pull from ACR (if configured), and interact with the node resource group.
  identity {
    type = "SystemAssigned"
  }

  # API server authorized IP ranges. Empty list (default) omits the block so
  # the master endpoint stays publicly reachable — required for the apply
  # host's Helm/kubectl steps that install cert-manager / KEDA / ESO and for
  # operators running ad-hoc kubectl from anywhere. Production deployments
  # populate var.authorized_ip_ranges with their CI runner / jumpbox CIDRs.
  dynamic "api_server_access_profile" {
    for_each = length(var.authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.authorized_ip_ranges
    }
  }

  # Azure CNI: pods get IPs directly from the VNet subnet, giving them full
  # network reachability to PostgreSQL/Redis without any NAT.
  # service_cidr must NOT overlap with the VNet or any peered network.
  # network_policy = "azure" enables the Azure NetworkPolicy engine so
  # NetworkPolicy resources actually deny traffic — without it, NetworkPolicy
  # objects are accepted by the API but never enforced.
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
    service_cidr   = var.service_cidr   # default: 10.0.64.0/20 (K8s ClusterIP range)
    dns_service_ip = var.dns_service_ip # default: 10.0.64.10  (CoreDNS ClusterIP)
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
    #
    # zones: azurerm ~> 4.0 does support re-zoning an existing default node
    # pool. It is one of the cycleNodePoolProperties, so a change is applied by
    # cycling the system node pool through temporary_name_for_rotation (set to
    # "defaulttmp" above) rather than by recreating the cluster. We suppress it
    # deliberately: the provider's cycle does not cordon and drain, so it hard-
    # disrupts every pod on the system pool. Editing one tfvars line should not
    # do that unannounced. The check block below reports the resulting drift.
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      default_node_pool[0].zones,
    ]
  }
}

# ignore_changes on default_node_pool[0].zones makes an availability_zones edit
# a silent no-op: the plan comes back clean and the node pool stays put. Surface
# that as a warning on every plan so a requested zone change is never mistaken
# for an applied one.
#
# A check block rather than a postcondition on purpose. A failing postcondition
# aborts planning even when the cluster has no planned changes, so a deployment
# already sitting in this state cannot apply anything at all until it is
# resolved. The drift is worth reporting, not worth blocking unrelated work.
#
# An empty availability_zones is exempt. [] is the default and asks Azure to
# place the pool, so whatever zones a pool already reports are not drift from a
# request nobody made. Without the exemption every cluster created under the
# earlier ["1"] default would warn on every plan.
#
# create_cluster = false is exempt too. local.live_node_pool_zones folds the
# count away to an empty set there, which would otherwise read as drift against
# any requested zones on a cluster this module does not manage.
check "aks_node_pool_zone_drift" {
  assert {
    condition = length(var.availability_zones) == 0 || length(azurerm_kubernetes_cluster.main) == 0 ? true : local.live_node_pool_zones == toset(var.availability_zones)
    error_message = join("", [
      "AKS node pool zones are [",
      join(",", sort(tolist(local.live_node_pool_zones))),
      "] but availability_zones requests [",
      join(",", sort(var.availability_zones)),
      "]. This module ignores zone changes on an existing node pool, so the ",
      "request was discarded and the live zones above are what you have. To ",
      "make it take effect, either revert availability_zones to the live value, ",
      "or drop default_node_pool[0].zones from the ignore_changes block in ",
      "modules/k8s-cluster/main.tf and apply during a maintenance window. That ",
      "cycles the system node pool, which does not cordon and drain and will ",
      "disrupt every pod running on it.",
    ])
  }
}

# Additional node pools for workloads that need different compute profiles.
# Default: one "large" pool (Standard_D16s_v3, 16 vCPU / 64 GB) for ClickHouse
# and other memory-intensive services. Scales 0→2 (scales to zero when idle).
resource "azurerm_kubernetes_cluster_node_pool" "node_pool" {
  for_each = var.additional_node_pools

  name                  = each.key
  kubernetes_cluster_id = local.cluster_id
  vm_size               = each.value.vm_size
  auto_scaling_enabled  = true
  vnet_subnet_id        = var.subnet_id
  min_count             = each.value.min_count
  max_count             = each.value.max_count
  node_labels           = each.value.node_labels
  node_taints           = each.value.node_taints
  kubelet_disk_type     = each.value.kubelet_disk_type
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
  issuer   = local.cluster_oidc_issuer_url
  subject  = "system:serviceaccount:cert-manager:cert-manager"
}

# Federated Identity Credentials — bind each LangSmith K8s service account to
# the Managed Identity via OIDC. One credential per service account.
resource "azurerm_federated_identity_credential" "k8s_app" {
  for_each = toset(local.service_accounts_for_workload_identity)

  name                      = "langsmith-federated-${each.value}"
  user_assigned_identity_id = azurerm_user_assigned_identity.k8s_app.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = local.cluster_oidc_issuer_url
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
# Provisions an Azure Application Gateway v2 and enables the AKS ingress-appgw add-on.
# AGIC watches Kubernetes Ingress resources with ingressClassName: azure-application-gateway
# and programs AGW routing rules dynamically. Auth uses Workload Identity (ARM auth).
#
# Prerequisites: agic_subnet_id must point to a dedicated /24+ subnet in the same VNet.
# The AGW itself has a placeholder backend/listener/rule — AGIC overwrites these.
# ignore_changes lifecycle prevents Terraform from reverting AGIC-managed state.

# Public IP for the Application Gateway frontend.
# dns_label sets a DNS name: <dns_label>.<region>.cloudapp.azure.com on the AGW public IP.
# For AGIC, the DNS label is set directly on the Azure public IP resource (not via K8s annotation).
resource "azurerm_public_ip" "agw" {
  count               = local.agic_managed ? 1 : 0
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
  count               = local.agic_managed ? 1 : 0
  name                = "${var.cluster_name}-agw"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(var.tags, { module = "aks", component = "agic" })

  # Attached only when the caller passes a policy, which it does with the
  # WAF_v2 tier. Azure supports policy associations on no other tier, and the
  # provider does not check the pair, so a Standard_v2 gateway with a policy
  # plans clean and fails at apply.
  firewall_policy_id = var.firewall_policy_id

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
    # Azure rejects a WAF_v2 gateway that has no policy attached, with
    # ApplicationGatewayFirewallNotConfiguredForSelectedSku. There is no mode
    # where the tier runs without one, so catch the pair here rather than 15
    # minutes into an apply. Deliberately not a silent downgrade to Standard_v2:
    # an operator who asked for WAF should not end up with no firewall.
    precondition {
      condition     = var.agw_sku_tier != "WAF_v2" || var.firewall_policy_id != null
      error_message = "agw_sku_tier is WAF_v2 but no WAF policy was supplied. Set create_waf = true, which creates the policy and selects the WAF_v2 tier for you, or set agw_sku_tier = \"Standard_v2\"."
    }

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
#   3. Network Contributor for the subnet join action on the AGW subnet, at VNet
#      scope by default and narrowed by agic_network_contributor_scope
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
  count           = local.agic_managed ? 1 : 0
  create_duration = "300s"
  depends_on      = [azurerm_kubernetes_cluster.main]
}

# principal_type is set explicitly on each AGIC assignment: subscriptions that
# delegate roleAssignments/write with an ABAC condition on principalType return 403
# when the request omits it.
resource "azurerm_role_assignment" "agic_rg_reader" {
  count                = local.agic_managed ? 1 : 0
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "Reader"
  principal_id         = local.agic_addon_principal_id
  principal_type       = "ServicePrincipal"
  depends_on           = [time_sleep.agic_identity_propagation]
}

resource "azurerm_role_assignment" "agic_agw_contributor" {
  count                = local.agic_managed ? 1 : 0
  scope                = azurerm_application_gateway.agw[0].id
  role_definition_name = "Contributor"
  principal_id         = local.agic_addon_principal_id
  principal_type       = "ServicePrincipal"
  depends_on           = [azurerm_application_gateway.agw, time_sleep.agic_identity_propagation]
}

# Network Contributor is Microsoft.Network/* with no NotActions, so at VNet scope
# this identity can write to every subnet in the VNet, including which NSG or
# route table each one carries. AGIC needs subnets/join/action and subnets/read on
# one subnet, and Azure documents those as assignable "on the virtual network or
# subnet", so 'subnet' is sufficient and is what a VNet you do not own should get.
#
# The default stays 'vnet' because scope is ForceNew: narrowing it destroys and
# recreates the assignment, which is a non-empty plan and a window of 403s for
# every deployment already running. 'none' leaves the grant to an operator whose
# network team will not delegate roleAssignments/write on their VNet.
resource "azurerm_role_assignment" "agic_vnet_network_contributor" {
  count                = local.agic_managed && var.agic_network_contributor_scope != "none" ? 1 : 0
  scope                = var.agic_network_contributor_scope == "subnet" ? var.agic_subnet_id : local.agic_vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = local.agic_addon_principal_id
  principal_type       = "ServicePrincipal"
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
