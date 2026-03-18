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
#   • Default node pool: Standard_DS3_v2 (4 vCPU, 14 GB RAM) — DSv2 family
#     has broad quota availability across subscriptions.
#   • Additional "large" pool: Standard_DS4_v2 (8 vCPU, 28 GB) for ClickHouse
#     and other stateful/memory-intensive workloads.
#   • NGINX ingress: deployed via Helm, exposes a single Azure Load Balancer
#     IP that routes to all LangSmith services by path/host.
# ══════════════════════════════════════════════════════════════════════════════

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

    # Cluster autoscaler scales between 1 and max_count based on pending pods.
    auto_scaling_enabled = true
    min_count            = 1
    max_count            = var.default_node_pool_max_count

    # Nodes live in the main subnet; Azure CNI assigns pod IPs from this range.
    vnet_subnet_id = var.subnet_id

    # Temporary node pool name used during node pool upgrades/rotations.
    # Required when auto_scaling_enabled = true and the pool is being replaced.
    temporary_name_for_rotation = "defaulttmp"
  }

  # System-assigned Managed Identity: AKS uses this to manage node VMs,
  # pull from ACR (if configured), and interact with the node resource group.
  identity {
    type = "SystemAssigned"
  }

  # Azure CNI: pods get IPs directly from the VNet subnet, giving them full
  # network reachability to PostgreSQL/Redis without any NAT.
  # service_cidr must NOT overlap with the VNet or any peered network.
  network_profile {
    network_plugin = "azure"
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

  lifecycle {
    # upgrade_settings change during rolling node upgrades; ignore to prevent
    # drift between Terraform state and live cluster configuration.
    ignore_changes = [
      default_node_pool[0].upgrade_settings
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

# NGINX Ingress Controller — the single entry point for all HTTP(S) traffic.
# Creates an Azure Standard Load Balancer with a public IP.
# Routes traffic to LangSmith frontend/backend services via Ingress rules.
# cert-manager integrates with NGINX to automate TLS certificate provisioning.
#
# 2 replicas for basic availability (both on different nodes via pod anti-affinity).
resource "helm_release" "nginx_ingress" {
  count      = var.nginx_ingress_enabled ? 1 : 0
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
          annotations = {
            # Keep HTTP probes (default) but point them at /nginx-health which always 200s.
            # This survives every CCM reconcile: protocol stays Http, path stays /nginx-health.
            "service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path" = "/nginx-health"
          }
        }
      }
    })
  ]
}
