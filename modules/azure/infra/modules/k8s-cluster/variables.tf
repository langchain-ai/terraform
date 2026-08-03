variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "cluster_name" {
  type        = string
  description = "Name of the cluster"
}

variable "create_cluster" {
  type        = bool
  description = "Whether to create a new AKS cluster. Set false to attach to a pre-existing cluster (BYOC) — Terraform reads it via a data source instead of managing it, while still creating the Managed Identities, federated credentials, and (optionally) additional node pools in this module. 'agic' and 'istio-addon' ingress modes require create_cluster = true (they configure AKS-managed add-ons only settable on a Terraform-owned cluster resource)."
  default     = true
}

variable "create_vnet" {
  type        = bool
  description = "Whether the root module is creating the VNet. Only read to reject create_cluster = false with create_vnet = true: an attached cluster's nodes already run in an existing subnet, so a subnet Terraform carves could never be one of them."
  default     = true
}

variable "existing_cluster_subnet_id" {
  type        = string
  description = "The subnet the pre-existing cluster's nodes run in. Only used when create_cluster = false, where it equals subnet_id because that path requires create_vnet = false. Exists as its own input so the guards below never reference a subnet id derived from the VNet module, whose outputs are pending on a first apply and would defer the cluster lookup to apply time."
  default     = ""
}

variable "existing_cluster_resource_group_name" {
  type        = string
  description = "Resource group of the pre-existing cluster. Only used when create_cluster = false. Resolved by the caller, which must pass a value that does not reference a resource pending creation — reading it from azurerm_resource_group would make Terraform defer the cluster lookup, and every existing-cluster guard in this module with it."
  default     = ""
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
  default     = "1.35" # 1.33 and below are LTS-only in eastus as of Jul 2026; standard tier = 1.34/1.35/1.36 (1.35 is region default)
}

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size of the default node pool"
  default     = "Standard_D8s_v3" # 8 vCPU, 32GB RAM — Dsv3 family; matches the root module's production default
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
      vm_size   = "Standard_D16s_v3" # 16 vCPU, 64GB RAM — Dsv3 family; matches the root module's production default
      min_count = 0
      max_count = 2
    }
  }
}

variable "ingress_controller" {
  type        = string
  description = "Ingress controller to install. 'nginx' = NGINX ingress via Helm, the current default and the only option with every TLS path validated. 'istio' = Istio via Helm (self-managed). 'istio-addon' = Azure managed Istio (AKS service mesh add-on); use for mTLS or multi-dataplane. 'agic' = Application Gateway Ingress Controller (requires agic_subnet_id). 'envoy-gateway' = Envoy Gateway via Helm (Gateway API). 'none' = skip."
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
  description = "Application Gateway SKU tier. 'Standard_v2' for standard deployments, 'WAF_v2' to enable WAF on the gateway. The caller forces 'WAF_v2' whenever a firewall policy is attached."
  default     = "Standard_v2"

  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.agw_sku_tier)
    error_message = "agw_sku_tier must be 'Standard_v2' or 'WAF_v2'."
  }
}

variable "agic_network_contributor_scope" {
  type        = string
  description = "Where to grant the AGIC identity Network Contributor: 'vnet' (the whole VNet, the default), 'subnet' (only the Application Gateway's subnet, which is all AGIC needs), or 'none' (skip it, for an operator who creates the assignment out of band)."
  default     = "vnet"

  validation {
    condition     = contains(["vnet", "subnet", "none"], var.agic_network_contributor_scope)
    error_message = "agic_network_contributor_scope must be vnet, subnet or none."
  }
}

variable "firewall_policy_id" {
  type        = string
  description = "Resource ID of a WAF policy to attach to the Application Gateway. Requires agw_sku_tier = 'WAF_v2' — Azure supports policy associations on no other tier. Null leaves the gateway without a policy."
  default     = null
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
