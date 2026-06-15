variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "cluster_name" {
  type        = string
  description = "Name of the cluster"
}

variable "location" {
  type        = string
  description = "Location of the cluster"
}

variable "subnet_id" {
  description = "The ID of the subnet where the AKS cluster will be deployed"
  type        = string
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version of the cluster"
  default     = "1.33" # 1.32 and below are LTS-only in eastus as of April 2026; use 1.33+ for standard tier
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_DS3_v2" # 4 vCPU, 14GB RAM — DSv2 family (60 free vCPUs in eastus)
}

variable "default_node_pool_min_count" {
  type        = number
  description = "Min count of the default node pool. Autoscaler never scales below this. Set to 3 for production — Pass 2 needs ~14.4 vCPU and 3× Standard_D8s_v3 provides 18,870m allocatable."
  default     = 1
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max count of the default node pool"
  default     = 10
}

variable "default_node_pool_max_pods" {
  type        = number
  description = "Max pods per node in the default node pool. AKS default is 30 (Azure CNI). LangSmith Pass 2 deploys ~17 pods; Pass 3 adds ~20 more. Set to 60 to fit a full multi-pass deployment on a single node without triggering autoscaler quota limits."
  default     = 60
}

variable "service_cidr" {
  type        = string
  description = "Service CIDR of the cluster"
  default     = "10.0.64.0/20"
}

variable "dns_service_ip" {
  type        = string
  description = "DNS service IP of the cluster"
  default     = "10.0.64.10"
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Node pools to be created"
  default = {
    large = {
      vm_size   = "Standard_DS4_v2" # 8 vCPU, 28GB RAM — DSv2 family
      min_count = 0
      max_count = 2
    }
  }
}

variable "ingress_controller" {
  type        = string
  description = "Ingress controller to install. 'nginx' = NGINX ingress via Helm. 'istio' = Istio via Helm (self-managed). 'istio-addon' = Azure managed Istio (AKS service mesh add-on, recommended on Azure). 'agic' = Application Gateway Ingress Controller (requires agic_subnet_id). 'envoy-gateway' = Envoy Gateway via Helm (Gateway API). 'none' = skip."
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "istio", "istio-addon", "agic", "envoy-gateway", "none"], var.ingress_controller)
    error_message = "ingress_controller must be 'nginx', 'istio', 'istio-addon', 'agic', 'envoy-gateway', or 'none'."
  }
}

variable "istio_version" {
  type        = string
  description = "Istio helm chart version. Only used when ingress_controller = 'istio' (self-managed Helm install)."
  default     = "1.29.1"
}

variable "istio_external_gateway_enabled" {
  type        = bool
  description = "Provision an external (public) Istio ingress gateway. Used by both 'istio' and 'istio-addon' modes."
  default     = true
}

variable "istio_internal_gateway_enabled" {
  type        = bool
  description = "Provision an internal (private VNet) Istio ingress gateway. Used only with 'istio-addon' mode."
  default     = false
}

variable "istio_addon_revision" {
  type        = string
  description = "Azure Service Mesh revision to pin. Format: 'asm-1-<minor>'. Run: az aks mesh get-upgrades -g <rg> -n <cluster> to list available revisions."
  default     = "asm-1-27"
}

variable "tags" {
  type        = map(string)
  description = "Common Azure resource tags to apply to all resources in this module"
  default     = {}
}

variable "langsmith_namespace" {
  type        = string
  description = "Kubernetes namespace where LangSmith is deployed. Used for Workload Identity federation."
  default     = "langsmith"
}

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith. Used to generate federated identity credential subjects."
  default     = "langsmith"
}

variable "workload_identity_name" {
  type        = string
  description = "Override the managed identity name. Set to the existing identity name when migrating from the storage module to avoid recreating it."
  default     = ""
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the default node pool. Use [\"1\",\"2\",\"3\"] for zone-redundant HA."
  default     = ["1"]
}

variable "dns_label" {
  type        = string
  description = "Azure Public IP DNS label for the ingress LoadBalancer service. Results in <label>.<region>.cloudapp.azure.com. Works with nginx, istio, istio-addon, envoy-gateway. Leave empty to skip."
  default     = ""
}

# ── AGIC (Application Gateway Ingress Controller) ─────────────────────────────

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID. Required for AGIC Workload Identity ARM auth and AGW resource references."
  default     = ""
}

variable "agic_subnet_id" {
  type        = string
  description = "Subnet ID for the Application Gateway. Required when ingress_controller = 'agic'. Must be a /24 or larger dedicated subnet (no other resources)."
  default     = ""
}

variable "agw_sku_tier" {
  type        = string
  description = "Application Gateway SKU tier. 'Standard_v2' for standard deployments, 'WAF_v2' to enable WAF on the gateway."
  default     = "Standard_v2"

  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.agw_sku_tier)
    error_message = "agw_sku_tier must be 'Standard_v2' or 'WAF_v2'."
  }
}

# ── Envoy Gateway ─────────────────────────────────────────────────────────────

variable "envoy_gateway_version" {
  type        = string
  description = "Envoy Gateway Helm chart version (e.g. 'v1.2.0'). See: https://gateway.envoyproxy.io/releases"
  default     = "v1.2.0"
}

# ── API server access ─────────────────────────────────────────────────────────

variable "authorized_ip_ranges" {
  type        = list(string)
  description = "External CIDRs permitted to reach the AKS API server. Empty list (default) omits the api_server_access_profile block, leaving the master publicly reachable so the apply host's Helm/kubectl steps work from any operator. Production deployments populate this with operator/CI egress CIDRs."
  default     = []
}

# ── Network plugin mode / policy (Azure CNI Overlay) ──────────────────────────

variable "network_plugin_mode" {
  type        = string
  description = "Azure CNI mode. \"\" = classic Azure CNI (pods get VNet subnet IPs). \"overlay\" = Azure CNI Overlay (pods get IPs from pod_cidr). Immutable — changing forces cluster recreation."
  default     = ""

  validation {
    condition     = contains(["", "overlay"], var.network_plugin_mode)
    error_message = "network_plugin_mode must be \"\" (classic) or \"overlay\"."
  }
}

variable "pod_cidr" {
  type        = string
  description = "Pod CIDR for Azure CNI Overlay (network_plugin_mode = overlay). Must not overlap the VNet, service_cidr, or peered/on-prem ranges. Ignored in classic mode."
  default     = "10.244.0.0/16"
}

variable "network_policy" {
  type        = string
  description = "Network policy engine. \"azure\" (NPM, classic default), \"calico\", or \"cilium\". \"cilium\" auto-enables the eBPF data plane and requires overlay. Azure NPM is deprecating; Cilium is recommended for overlay."
  default     = "azure"

  validation {
    condition     = contains(["azure", "calico", "cilium"], var.network_policy)
    error_message = "network_policy must be \"azure\", \"calico\", or \"cilium\"."
  }
}

# ── Egress / outbound ─────────────────────────────────────────────────────────

variable "outbound_type" {
  type        = string
  description = "Cluster egress routing. \"loadBalancer\" (default) or \"userDefinedRouting\" (egress via a route table on an existing subnet → firewall/NVA). Immutable — changing forces cluster recreation. userDefinedRouting requires a BYO subnet with a pre-associated route table."
  default     = "loadBalancer"

  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting"], var.outbound_type)
    error_message = "outbound_type must be \"loadBalancer\" or \"userDefinedRouting\"."
  }
}

# ── Private API server ────────────────────────────────────────────────────────

variable "private_cluster_enabled" {
  type        = bool
  description = "Deploy the AKS API server as a private endpoint (no public IP). Requires the terraform apply host to reach the API server over the VNet (bastion/peered/self-hosted runner)."
  default     = false
}

variable "private_cluster_public_fqdn_enabled" {
  type        = bool
  description = "When private_cluster_enabled, also expose a public FQDN resolving to the private IP. Default false (public FQDN disabled). Ignored when the cluster is public."
  default     = false
}

variable "private_dns_zone_id" {
  type        = string
  description = "Private DNS zone for the private API server. \"\" => \"System\" (AKS-managed zone). \"None\" => bring-your-own DNS. Or a private DNS zone resource ID (requires Private DNS Zone Contributor for the cluster identity + VNet link). Only used when private_cluster_enabled."
  default     = ""
}

# ── Control-plane (cluster) managed identity ───────────────────────────────────

variable "create_cluster_identity" {
  type        = bool
  description = "Create a user-assigned managed identity for the AKS control plane and grant it Network Contributor on the VNet (the parent of subnet_id) — VNet scope so it can both join the subnet and link the System private DNS zone for a private cluster. When false (default), the cluster uses a system-assigned identity. Mutually exclusive with cluster_identity_id."
  default     = false
}

variable "cluster_identity_id" {
  type        = string
  description = "Resource ID of an existing user-assigned managed identity to use as the AKS control-plane identity. You manage its role assignments (Network Contributor on the VNet/subnet, Private DNS Zone Contributor on a custom private DNS zone). Mutually exclusive with create_cluster_identity. Empty => system-assigned."
  default     = ""
}
