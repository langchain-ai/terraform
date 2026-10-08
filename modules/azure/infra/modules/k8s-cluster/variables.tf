variable "resource_group_name" {
  type        = string
  description = "Resource group name of the cluster"
}

variable "cluster_name" {
  type        = string
  description = "Name of the cluster"
}

variable "kube_auth" {
  type        = string
  description = "How the module's Kubernetes and Helm providers sign in to the cluster. 'auto' uses Entra ID through kubelogin when the cluster has an Entra profile and the kube_config client certificate otherwise; 'entra' and 'certificate' force one."
  default     = "auto"

  validation {
    condition     = contains(["auto", "entra", "certificate"], var.kube_auth)
    error_message = "kube_auth must be 'auto', 'entra', or 'certificate'."
  }
}

variable "create_cluster" {
  type        = bool
  description = "Whether to create a new AKS cluster. Set false to attach to a pre-existing cluster (BYOC) — Terraform reads it via a data source instead of managing it, while still creating the Managed Identities, federated credentials, and (optionally) additional node pools in this module. 'istio-addon' requires create_cluster = true, since service_mesh_profile is only settable on a Terraform-owned cluster resource. 'agic' works on an attached cluster only when the ingress-appgw add-on is already enabled on it, because enabling it is the same kind of resource-only argument."
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
  default     = "Standard_D8s_v5" # 8 vCPU, 32GB RAM — Dsv5 family; matches the root module's production default
}

variable "default_node_pool_min_count" {
  type        = number
  description = "Min count of the default node pool. Autoscaler never scales below this. Set to 3 for production — Pass 2 needs ~14.4 vCPU and 3× Standard_D8s_v5 provides 18,870m allocatable."
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

variable "default_node_pool_os_sku" {
  type        = string
  description = "OS SKU of the default node pool, and of every additional pool that sets no os_sku. Validated in the root module."
  default     = "Ubuntu"
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
    vm_size           = string
    min_count         = number
    max_count         = number
    node_labels       = optional(map(string), {})
    node_taints       = optional(list(string), [])
    kubelet_disk_type = optional(string, "OS")
    os_sku            = optional(string)
  }))
  description = "Node pools to be created. os_sku falls back to default_node_pool_os_sku."
  default = {
    large = {
      vm_size   = "Standard_D16s_v5" # 16 vCPU, 64GB RAM — Dsv5 family; matches the root module's production default
      min_count = 0
      max_count = 2
    }
  }
}

variable "ingress_controller" {
  type        = string
  description = "Ingress controller to install. 'envoy-gateway' = Envoy Gateway via Helm (Gateway API), the default. 'nginx' = NGINX ingress via Helm, for legacy Ingress compatibility. 'istio' = Istio via Helm (self-managed). 'istio-addon' = Azure managed Istio (AKS service mesh add-on); use for mTLS or multi-dataplane. 'agic' = Application Gateway Ingress Controller (requires agic_subnet_id). 'none' = skip."
  default     = "envoy-gateway"

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
  description = "The LangSmith chart's fullname: the release name when it contains \"langsmith\", otherwise <release>-langsmith. The chart prefixes every service account with it, so the federated identity credential subjects are built from it."
  default     = "langsmith"
}

variable "workload_identity_name" {
  type        = string
  description = "Override the managed identity name. Set to the existing identity name when migrating from the storage module to avoid recreating it."
  default     = ""
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the default node pool. The default [] creates a non-zonal pool, which is required when the node VM size is not offered in every zone of the region. Use [\"1\",\"2\",\"3\"] for zone-redundant HA."
  default     = []
}

# ── Network mode, data plane and tier ────────────────────────────────────────
# The root module derives these from aks_network_mode, aks_network_dataplane,
# aks_sku_tier and aks_support_plan and validates the combinations there. This
# module passes them to the cluster and reads back the profile the cluster
# runs (live_network_profile), which the root compares against before a change
# that Azure would run as a migration or the provider as a replacement.

variable "network_plugin_mode" {
  type        = string
  description = "Azure CNI IPAM mode. null is node-subnet mode, where pods take VNet addresses from subnet_id. \"overlay\" gives pods addresses from pod_cidr and leaves the subnet to the nodes. Changing it on an existing cluster is Microsoft's one-way migration, which needs a cluster with no policy engine; the root module refuses it."
  default     = null

  validation {
    condition     = var.network_plugin_mode == null || var.network_plugin_mode == "overlay"
    error_message = "network_plugin_mode must be null (node-subnet) or \"overlay\"."
  }
}

variable "pod_cidr" {
  type        = string
  description = "Pod address range in overlay mode, private to the cluster. Must be null in node-subnet mode, where the provider rejects it."
  default     = null
}

variable "network_data_plane" {
  type        = string
  description = "\"azure\" or \"cilium\" (Azure CNI Powered by Cilium). Cilium needs overlay mode and Kubernetes 1.31 or later, and going from Cilium back to Azure recreates the cluster."
  default     = "azure"

  validation {
    condition     = contains(["azure", "cilium"], var.network_data_plane)
    error_message = "network_data_plane must be \"azure\" or \"cilium\"."
  }
}

variable "network_policy" {
  type        = string
  description = "NetworkPolicy engine: \"azure\" (Azure Network Policy Manager), \"calico\" or \"cilium\". The provider requires \"cilium\" when network_data_plane is \"cilium\"."
  default     = "azure"

  validation {
    condition     = contains(["azure", "calico", "cilium"], var.network_policy)
    error_message = "network_policy must be \"azure\", \"calico\" or \"cilium\"."
  }
}

variable "egress_dependencies" {
  type        = list(string)
  description = "IDs of resources the cluster's egress needs in place before it is created, such as the association of a NAT gateway the root module creates with the node subnet. Only orders the create; the values are not read."
  default     = []
}

variable "outbound_type" {
  type        = string
  description = "How nodes reach the internet: \"loadBalancer\" (an AKS-managed public IP on the Standard Load Balancer), \"userDefinedRouting\" (the node subnet's route table) or \"userAssignedNATGateway\" (the NAT gateway on the node subnet). The root module checks the subnet before passing either of the last two."
  default     = "loadBalancer"

  validation {
    condition     = contains(["loadBalancer", "userDefinedRouting", "userAssignedNATGateway"], var.outbound_type)
    error_message = "outbound_type must be \"loadBalancer\", \"userDefinedRouting\" or \"userAssignedNATGateway\"."
  }
}

variable "sku_tier" {
  type        = string
  description = "AKS pricing tier for the control plane: \"Free\" (no SLA), \"Standard\" (financially backed uptime SLA; 99.95% with availability zones) or \"Premium\" (Standard plus long-term support). Updated in place."
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be \"Free\", \"Standard\" or \"Premium\"."
  }
}

variable "support_plan" {
  type        = string
  description = "\"KubernetesOfficial\" or \"AKSLongTermSupport\". Long-term support requires sku_tier = \"Premium\"."
  default     = "KubernetesOfficial"

  validation {
    condition     = contains(["KubernetesOfficial", "AKSLongTermSupport"], var.support_plan)
    error_message = "support_plan must be \"KubernetesOfficial\" or \"AKSLongTermSupport\"."
  }
}

variable "dns_label" {
  type        = string
  description = "Azure Public IP DNS label for the ingress LoadBalancer service. Results in <label>.<region>.cloudapp.azure.com. Works with envoy-gateway, nginx, istio, istio-addon; for envoy-gateway, deploy.sh sets it through the EnvoyProxy. Leave empty to skip."
  default     = ""
}

variable "ingress_load_balancer" {
  type        = string
  description = "'public' or 'internal': whether the ingress controller's load balancer gets a public IP or a private one in the cluster's VNet. Validated at the root."
  default     = "public"
}

variable "ingress_load_balancer_subnet_id" {
  type        = string
  description = "Subnet for the internal load balancer's private IP. Empty uses the node subnet."
  default     = ""
}

variable "ingress_load_balancer_ip" {
  type        = string
  description = "Static private IPv4 address for the internal load balancer. Empty lets Azure pick one."
  default     = ""
}

variable "ingress_load_balancer_needs_subnet_grant" {
  type        = bool
  description = "Whether the internal load balancer takes its IP from a subnet other than the node subnet, so the cluster identity needs a grant there. Computed by the root from inputs known at plan."
  default     = false
}

variable "ingress_load_balancer_manage_subnet_assignment" {
  type        = bool
  description = "Whether Terraform grants the cluster identity Network Contributor on ingress_load_balancer_subnet_id when it is not the node subnet."
  default     = true
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

variable "envoy_gateway_image_registry" {
  type        = string
  description = "Registry that mirrors Docker Hub for Envoy Gateway's controller and proxy images, with docker.io as the first path segment under it. Empty pulls from docker.io."
  default     = ""
}

variable "envoy_proxy_default_image" {
  type        = string
  description = "Envoy proxy image the controller uses by default for envoy_gateway_version, without a registry (e.g. 'envoyproxy/envoy:distroless-v1.32.1'). Mirrored with envoy_gateway_image_registry."
  default     = ""
}

variable "envoy_gateway_image_pull_secret_name" {
  type        = string
  description = "Pull Secret in envoy-gateway-system for the controller and proxy pods. Empty pulls without credentials."
  default     = ""
}

# ── API server access ─────────────────────────────────────────────────────────

variable "authorized_ip_ranges" {
  type        = list(string)
  description = "External CIDRs permitted to reach the AKS API server. Empty list (default) omits the api_server_access_profile block, leaving the master publicly reachable so the apply host's Helm/kubectl steps work from any operator. Production deployments populate this with operator/CI egress CIDRs."
  default     = []
}

variable "private_cluster_enabled" {
  type        = bool
  description = "Give the API server a private endpoint in the cluster's VNet and no public address. The apply host then needs a network path to that endpoint."
  default     = false
}

variable "private_dns_zone_id" {
  type        = string
  description = "Private DNS zone for the API server: empty or \"System\" (AKS creates the zone in the node resource group), \"None\", or the resource ID of an existing zone. Only read when private_cluster_enabled = true."
  default     = ""
}

# ── Identity and authentication ───────────────────────────────────────────────

variable "entra_only" {
  type        = bool
  description = "Authenticate to the cluster with Entra ID only: Entra integration with Azure RBAC for Kubernetes authorization, and local accounts disabled. The Helm and Kubernetes providers then fetch tokens through kubelogin instead of a client certificate."
  default     = false
}

variable "entra_admin_group_object_ids" {
  type        = list(string)
  description = "Object IDs of Entra groups granted cluster-admin when entra_only = true."
  default     = []
}

variable "control_plane_identity" {
  type        = string
  description = "Identity the control plane runs as: \"system\" (default) or \"user\"."
  default     = "system"
}

variable "control_plane_identity_id" {
  type        = string
  description = "Resource ID of an existing user-assigned identity for the control plane. Empty (default) with control_plane_identity = \"user\": the module creates <cluster_name>-control-plane."
  default     = ""
}

variable "control_plane_identity_manage_grants" {
  type        = bool
  description = "With control_plane_identity = \"user\": true grants the identity Network Contributor on subnet_id, or on vnet_id with a custom private_dns_zone_id, and Private DNS Zone Contributor on that zone; false checks the identity holds a role on subnet_id, on subnet_route_table_id when set, and on that zone, and stops before the cluster is created when it does not. The check skips the VNet, which a zone its owner already linked does not need."
  default     = true
}

variable "control_plane_grant_check" {
  type        = bool
  description = "With control_plane_identity_manage_grants = false: whether plan checks the identity's direct role assignments before the cluster is created. False skips the check, for an owner who grants through group membership, which the check cannot see."
  default     = true
}

variable "vnet_id" {
  type        = string
  description = "Resource ID of the cluster VNet. Read only with control_plane_identity = \"user\" and a custom private_dns_zone_id, as the scope of its Network Contributor grant."
  default     = ""
}

variable "subnet_route_table_id" {
  type        = string
  description = "Resource ID of the route table on subnet_id, empty when it has none. Read only with control_plane_identity = \"user\" and control_plane_identity_manage_grants = false, as a scope the identity must hold a role on."
  default     = ""
}
