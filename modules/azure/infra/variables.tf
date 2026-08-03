# ── Deployment name ───────────────────────────────────────────────────────────

variable "name_prefix" {
  type        = string
  description = "Name of this deployment, appended to every resource name and used as the default 'environment' tag (e.g. \"prod\", \"staging\", \"dev-dz\"). Write it without a hyphen — Terraform inserts the separator, so \"prod\" gives langsmith-rg-prod. Empty means no suffix. Set in terraform.tfvars."
  default     = ""

  # Hyphens are allowed between alphanumerics only. A trailing or doubled hyphen
  # would pass here and then fail mid-apply: Key Vault names must end in a
  # letter or digit and reject consecutive hyphens, and AKS names must start and
  # end alphanumeric. Cheaper to reject at plan than to read an Azure name error.
  validation {
    condition     = var.name_prefix == "" || can(regex("^-?[a-z0-9](-?[a-z0-9])*$", var.name_prefix))
    error_message = "name_prefix must be empty, or lowercase letters and numbers separated by single hyphens (e.g. \"prod\", \"dev-dz\"). No trailing or doubled hyphen — Azure rejects the resulting Key Vault and AKS names. A leading hyphen is accepted and ignored."
  }
}

# Replaced by name_prefix. Kept declared purely so an un-migrated
# terraform.tfvars fails the plan with an explanation, rather than being
# ignored as an undeclared variable — which would drop name_prefix to its
# empty default and rename (destroy and recreate) every resource.
variable "identifier" {
  type        = string
  description = "Removed — use name_prefix instead."
  default     = ""

  validation {
    condition     = var.identifier == ""
    error_message = "identifier has been replaced by name_prefix — rename the variable and keep the value: identifier = \"-prod\" becomes name_prefix = \"prod\" (the leading hyphen is now optional, so \"-prod\" also works). Resource names are unchanged by this migration."
  }
}

# ── Resource tagging ──────────────────────────────────────────────────────────
# Tags are applied to every Azure resource for cost allocation, compliance,
# and incident response. Required by most enterprise Azure policies.

variable "environment" {
  type        = string
  description = "Value of the 'environment' tag on all resources. Defaults to name_prefix — set this only when the tag needs to differ from the deployment name (e.g. name_prefix = \"prod-eastus\", environment = \"prod\")."
  default     = ""
}

variable "owner" {
  type        = string
  description = "Email or team name of the resource owner. Used as the 'owner' tag on all resources."
  default     = ""
}

variable "cost_center" {
  type        = string
  description = "Cost center or billing code for charge-back. Used as the 'cost_center' tag on all resources."
  default     = ""
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

variable "keyvault_name" {
  type        = string
  description = "Name for the Azure Key Vault. Must be globally unique, 3-24 chars. Defaults to 'langsmith-kv-<name_prefix>' which you may need to customize to avoid naming conflicts."
  default     = ""
  # When empty, main.tf computes: "langsmith-kv${local.name_suffix}"
}

variable "keyvault_purge_protection" {
  type        = bool
  description = "Enable purge protection on Key Vault. Set false for dev environments where you need to destroy and recreate. Always true for production."
  default     = true
}

variable "keyvault_default_action" {
  type        = string
  description = "Default action for the Key Vault data-plane firewall. \"Allow\" (default) keeps the starter UX working — first apply creates ~10 secrets via the data plane and \"Deny\" without operator IP allowlisting blocks that. Production deployments set \"Deny\" and populate keyvault_allowed_ips."
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.keyvault_default_action)
    error_message = "keyvault_default_action must be 'Allow' or 'Deny'."
  }
}

variable "keyvault_allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the Key Vault firewall when keyvault_default_action = \"Deny\". The AKS subnet is allowlisted automatically via the Microsoft.KeyVault service endpoint."
  default     = []
}

variable "terraform_principal_type" {
  type        = string
  description = "Principal type of the identity running `terraform apply`, applied to its \"Key Vault Secrets Officer\" grant. Null (default) omits the field and lets Azure infer it, which is correct everywhere except subscriptions that delegate Microsoft.Authorization/roleAssignments/write through an ABAC condition on principalType — those reject requests that omit it with a generic 403. Set \"User\" for an interactive `az login` or \"ServicePrincipal\" for a CI pipeline. Managed-identity grants elsewhere in this module hardcode \"ServicePrincipal\" and need no toggle."
  default     = null

  validation {
    condition     = var.terraform_principal_type == null || contains(["User", "Group", "ServicePrincipal"], var.terraform_principal_type)
    error_message = "terraform_principal_type must be 'User', 'Group', or 'ServicePrincipal'. Omit it entirely (or set null) to let Azure infer the type — an empty string is not a valid opt-out."
  }
}

variable "aks_authorized_ip_ranges" {
  type        = list(string)
  description = "External CIDRs permitted to reach the AKS API server. Empty list (default) omits the api_server_access_profile block, leaving the master publicly reachable so Terraform-driven Helm/kubectl steps work from any apply host. Production deployments populate this with operator/CI egress CIDRs."
  default     = []
}

variable "location" {
  type        = string
  description = "The location of the LangSmith deployment"
  default     = "eastus"
}

variable "subscription_id" {
  type        = string
  description = "The subscription id of the LangSmith deployment"

  # A non-GUID value (e.g. the row number from `az account list -o table`) is
  # only rejected once azurerm builds its authorizer, which reports it as an
  # opaque auth failure. Catch the shape here instead.
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be a GUID, not a subscription name or list index. Get it with: az account show --query id -o tsv"
  }
}

variable "create_vnet" {
  type        = bool
  description = "Whether to create a new VNet. If false, vnet_id is required and each subnet is either supplied via its *_subnet_id variable or carved out of that VNet by Terraform."
  default     = true
}

# ── Bring-your-own AKS cluster ────────────────────────────────────────────────
# Set create_cluster = false to deploy onto a cluster the customer already runs.
# Terraform still provisions Key Vault, Storage, Managed Identities, and federated
# credentials — it just reads the cluster instead of creating it.
#
# This path also requires create_vnet = false. aks_subnet_id has to name a subnet
# the cluster already runs nodes in, which a subnet Terraform carves never is, so
# attaching while building a VNet has no working configuration and the plan rejects
# the combination outright. Supply vnet_id and the subnet IDs of the network that
# cluster already uses. Prerequisites on the existing cluster:
#   • OIDC issuer + Workload Identity enabled (az aks update --enable-oidc-issuer
#     --enable-workload-identity) — required for the federated credentials below.
#   • Reachable API server from the apply host (k8s-bootstrap installs cert-manager/KEDA).
#   • Local accounts NOT disabled — the kubernetes/helm providers authenticate via
#     the cluster's kube_config, which Azure returns empty for AAD-only clusters.

variable "create_cluster" {
  type        = bool
  description = "Whether to create a new AKS cluster. Set false to attach to a pre-existing cluster — provide existing_cluster_name and existing_cluster_resource_group_name, both required on that path."
  default     = true
}

variable "existing_cluster_name" {
  type        = string
  description = "Name of the pre-existing AKS cluster to attach to. Required when create_cluster = false, leaving it empty fails the plan rather than falling back to a derived name."
  default     = ""
}

variable "existing_cluster_resource_group_name" {
  type        = string
  description = "Resource group containing the pre-existing AKS cluster. Required when create_cluster = false. No default is derived: the only name this module could guess is langsmith-rg-<name_prefix>, the resource group it creates for Key Vault and Storage, which is not where a cluster the customer's platform team owns lives."
  default     = ""
}

variable "existing_cluster_node_pools_managed" {
  type        = bool
  description = "Whether Terraform should add and manage the additional node pools (e.g. the 'large' pool for ClickHouse) on a pre-existing cluster. Defaults to false: adding a Standard_D16s_v3 pool to a cluster someone else owns is a change worth opting into, and it is the surprising half of a module documented as one that never modifies an existing cluster. Set true to have Terraform add them, and the cluster must then have subnet capacity for the pools — the AKS subnet check counts them. Left false, the cluster needs a node that can hold ClickHouse on its own — 2 vCPU / 8 GiB under the default production sizing profile, 4 vCPU / 16 GiB under production-large — plus room for LangGraph workloads. infra/scripts/preflight.sh checks that against the live nodes before you apply. Terraform never adopts pools that already exist either way; it only ever adds new ones. Only used when create_cluster = false."
  default     = false
}

variable "vnet_id" {
  type        = string
  description = "The id of the existing VNet to use. Required when create_vnet is false. Any subnet Terraform creates is placed in this VNet's resource group."
  default     = ""

  validation {
    condition     = var.vnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.vnet_id))
    error_message = "vnet_id must be a full VNet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>"
  }
}

# ── Bring-your-own subnets (optional, only when create_vnet = false) ──────────
# Each subnet is independent. Supply an ID to reuse an existing subnet; leave it
# empty and Terraform creates that subnet inside vnet_id using the matching
# *_subnet_address_prefix, with the correct delegation applied.
#
# The IDs are matched against the full 11-segment shape, case-insensitively.
# Anchoring both ends is what lets main.tf index the segments positionally to
# locate a supplied subnet, and Azure treats resource IDs as case-insensitive.

variable "aks_subnet_id" {
  type        = string
  description = "The id of an existing subnet to use for the AKS cluster. Leave empty to have Terraform create one in vnet_id using aks_subnet_address_prefix. An existing subnet must carry the Microsoft.Storage and Microsoft.KeyVault service endpoints: the blob storage firewall is always default-deny and allowlists this subnet by ID, and Azure rejects a subnet rule when the matching endpoint is absent. Terraform checks this at plan time."
  default     = ""

  validation {
    condition     = var.aks_subnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.aks_subnet_id))
    error_message = "aks_subnet_id must be a full subnet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
  }
}

variable "postgres_subnet_id" {
  type        = string
  description = "The id of an existing subnet to use for the Postgres server. Leave empty to have Terraform create one in vnet_id using postgres_subnet_address_prefix. An existing subnet must already be delegated to Microsoft.DBforPostgreSQL/flexibleServers and hold no other resources. Terraform checks the delegation at plan time."
  default     = ""

  validation {
    condition     = var.postgres_subnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.postgres_subnet_id))
    error_message = "postgres_subnet_id must be a full subnet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
  }
}

variable "redis_subnet_id" {
  type        = string
  description = "The id of an existing subnet to use for the Redis private endpoint. Leave empty to have Terraform create one in vnet_id using redis_subnet_address_prefix. This subnet must NOT be delegated — Azure Managed Redis is reached through a private endpoint, and a delegated subnet would reject it."
  default     = ""

  validation {
    condition     = var.redis_subnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.redis_subnet_id))
    error_message = "redis_subnet_id must be a full subnet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
  }
}

variable "agic_subnet_id" {
  type        = string
  description = "The id of an existing subnet for the Application Gateway, required when ingress_controller = \"agic\" and create_vnet = false. Unlike the three above there is no carve path: Terraform will not create an Application Gateway subnet inside a VNet it does not own. Application Gateway v2 needs the subnet to itself, and Azure recommends a /24."
  default     = ""

  validation {
    condition     = var.agic_subnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.agic_subnet_id))
    error_message = "agic_subnet_id must be a full subnet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
  }
}

variable "bastion_subnet_id" {
  type        = string
  description = "The id of an existing subnet for Azure Bastion, required when create_bastion = true and create_vnet = false. Azure requires the subnet be named exactly AzureBastionSubnet and be /26 or larger; Terraform checks the name at plan time. There is no carve path, for the same reason as agic_subnet_id."
  default     = ""

  validation {
    condition     = var.bastion_subnet_id == "" || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.bastion_subnet_id))
    error_message = "bastion_subnet_id must be a full subnet resource ID: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
  }
}

variable "aks_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the AKS subnet, used when Terraform creates it. Azure CNI puts node and pod IPs in this range, so it needs (max_count + 1) * (max_pods + 1) addresses per node pool, which is 764 at the default sizing. Terraform checks this at plan time, because an undersized subnet applies cleanly and then stalls the autoscaler. The default is sized for the VNet Terraform builds; under create_vnet = false it must fall inside your VNet's address space, which plan also checks."
  default     = ["10.0.0.0/19"] # 8k IP addresses
}

variable "postgres_database_name" {
  type        = string
  description = "Name of the PostgreSQL database LangSmith connects to. Must match the database that exists on the server."
  default     = "langsmith"
}

variable "postgres_source" {
  type        = string
  description = "PostgreSQL deployment type. 'external' provisions Azure Database for PostgreSQL Flexible Server (private VNet). 'in-cluster' uses the chart-managed in-cluster Postgres pod (dev/demo only)."
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.postgres_source)
    error_message = "postgres_source must be 'external' or 'in-cluster'."
  }
}

variable "postgres_sku_name" {
  type        = string
  description = "SKU for the PostgreSQL Flexible Server. Exposed because LocationIsOfferRestricted is sometimes scoped to a SKU family, so switching tiers can clear it without changing region."
  default     = "GP_Standard_D2ds_v4"
}

variable "redis_source" {
  type        = string
  description = "Redis deployment type. 'external' provisions Azure Cache for Redis (private VNet). 'in-cluster' uses the chart-managed in-cluster Redis pod (dev/demo only)."
  default     = "external"

  validation {
    condition     = contains(["external", "in-cluster"], var.redis_source)
    error_message = "redis_source must be 'external' or 'in-cluster'."
  }
}

variable "clickhouse_source" {
  type        = string
  description = "ClickHouse deployment type. 'in-cluster' deploys ClickHouse as a pod via Helm (dev/POC only). 'external' for LangChain Managed ClickHouse (recommended for production) — see https://docs.langchain.com/langsmith/langsmith-managed-clickhouse"
  default     = "in-cluster"

  validation {
    condition     = contains(["in-cluster", "external"], var.clickhouse_source)
    error_message = "clickhouse_source must be 'in-cluster' or 'external'."
  }
}

variable "redis_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Redis subnet. Can be disjoint IP ranges. Under create_vnet = false it must fall inside your VNet's address space, which plan checks."
  default     = ["10.0.48.0/20"] # 4k IP addresses
}

variable "postgres_subnet_address_prefix" {
  type        = list(string)
  description = "Prefix for the Postgres subnet. Can be disjoint IP ranges. Under create_vnet = false it must fall inside your VNet's address space, which plan checks."
  default     = ["10.0.32.0/20"] # 4k IP addresses
}

variable "amr_sku" {
  type        = string
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest. Bump (Balanced_B1/B3/...) if the region reports AllocationFailed. (Replaces the classic redis_capacity.)"
  default     = "Balanced_B0"
}

variable "redis_availability_zones" {
  type        = list(string)
  description = "Availability zones for Azure Managed Redis. Independent of var.availability_zones so Redis can be placed separately from AKS/Postgres. Empty (default) lets Azure choose."
  default     = []
}

variable "blob_ttl_enabled" {
  type        = bool
  description = "Enable TTL for the blob container"
  default     = true
}

variable "blob_ttl_short_days" {
  type        = number
  description = "The number of days to keep short-lived blobs"
  default     = 14
}

variable "blob_ttl_long_days" {
  type        = number
  description = "The number of days to keep long-lived blobs"
  default     = 400
}

variable "storage_allowed_ips" {
  type        = list(string)
  description = "Public IPs / CIDRs allowed through the storage account default-deny firewall. AKS pod traffic is allowlisted automatically via the Microsoft.Storage service endpoint on the AKS subnet — only add operator workstations, CI runners, or other external clients that need to reach the blob data plane."
  default     = []
}

# ── AKS node pool sizing guidance ─────────────────────────────────────────────
# Pass 2 (core LangSmith): ~13 vCPU / 24 GiB scheduled across default pool nodes.
#   backend×3 (3 vCPU/6Gi) + platformBackend (1 vCPU/2Gi) + queue×3 (3 vCPU/6Gi)
#   + ingestQueue×3 (3 vCPU/6Gi) + frontend + playground + aceBackend + system pods
#   → Standard_D8s_v3 × 3 nodes (24 vCPU / 96 GiB) comfortably fits Pass 2.
#
# Pass 3–5 (LangGraph Platform, Agent Builder, Insights): add ~3 vCPU / 5 GiB.
#   Total with autoscale headroom: max_count = 12 (Standard_D8s_v3).
#
# ClickHouse: one pod, and its request comes from the sizing overlay in
#   helm/values/examples/ — 1 vCPU / 2 GiB (minimum), 2 vCPU / 8 GiB (dev and
#   production), 4 vCPU / 16 GiB (production-large). With no overlay the chart's
#   own default applies: 3.5 vCPU / 12 GiB.
#   Nothing pins it to the large pool: the chart emits nodeSelector and affinity
#   only when they are set, and this module sets neither. It lands on whichever
#   node has room, so a single node must hold the whole request.
#   Production recommendation from upstream: 8 vCPU / 32 GiB for heavy tracing load.
#
# Official LangSmith minimum: 16 vCPU / 64 GiB cluster-wide.
# See: https://docs.langchain.com/langsmith/kubernetes

variable "default_node_pool_vm_size" {
  type        = string
  description = "VM size for the default AKS node pool. Standard_D8s_v3 (8 vCPU / 32 GiB) is the recommended baseline for Pass 2+ (external Postgres + Redis). Use Standard_D4s_v3 (4 vCPU / 16 GiB) only for light/demo deployments (in-cluster DBs). See sizing comment above."
  default     = "Standard_D8s_v3" # 8 vCPU, 32 GiB
}

variable "default_node_pool_min_count" {
  type        = number
  description = "Min node count for the default pool. Autoscaler never scales below this floor. Set to 3 for production — Pass 2 needs ~14.4 vCPU and 3× Standard_D8s_v3 provides 18,870m allocatable (76% CPU). Set to 1 for minimum/dev deployments."
  default     = 1
}

variable "default_node_pool_max_count" {
  type        = number
  description = "Max node count for the default pool. Pass 2: 4–6 nodes. Pass 3 (LangGraph Platform): 6. Pass 4 (Agent Builder): 8. Pass 5 (Insights): 10–12. Autoscaler scales within this limit — increasing max_count takes effect immediately with no node restarts."
  default     = 10
}

variable "default_node_pool_max_pods" {
  type        = number
  description = "Max pods per node in the default pool. AKS Azure CNI default is 30 — too low for LangSmith. Pass 2 alone needs ~32 pods (17 LangSmith + 15 system). Set to 60 to fit full multi-pass deployments on a single node. Immutable — changing requires node pool recreation."
  default     = 60
}

# Both of these are empty by default rather than carrying the create-path value,
# because 10.0.64.0/20 is only safe against the VNet Terraform builds. main.tf
# fills them in for create_vnet = true and requires aks_service_cidr under
# bring-your-own, where the operator's address space is unknown here.
variable "aks_service_cidr" {
  type        = string
  description = "Kubernetes ClusterIP range for the AKS cluster. Defaults to 10.0.64.0/20, which is chosen to sit outside the Terraform-managed 10.0.0.0/17 VNet. Required when create_vnet = false and Terraform creates the cluster: AKS needs a range that nothing on or connected to your VNet uses, and an overlap can be accepted at create time and break later. Plan rejects a range that overlaps your VNet's address space, but cannot see peered or on-premises networks. Size it /20: the range is virtual, so a large one costs no address space, and /24 (Azure's floor) caps the cluster at 251 Services, which a Pass 4 deployment can reach because LangGraph Platform adds Services per deployment. Fixed on the cluster at creation — outgrowing it means rebuilding the cluster. Ignored when create_cluster = false — the range is fixed on the cluster resource at creation, so an existing cluster keeps whatever Azure gave it and this value configures nothing."
  default     = ""

  # Empty is the not-set sentinel main.tf falls back on, so it has to pass. Any
  # other value is parsed here rather than in the locals: cidrhost() derives the
  # CoreDNS address and the overlap bounds from it, and locals evaluate before
  # preconditions, so a bad value fails as a function error that names neither
  # the variable nor the fix.
  #
  # cidrnetmask() rather than cidrhost() because it is the CIDR function that
  # rejects IPv6, which cidrhost() accepts and the overlap math cannot use — it
  # splits the network address on "." and subtracts the prefix from 32, so an
  # IPv6 range reaches tonumber() whole and fails as the same unattributable
  # function error. Every other verdict is identical between the two.
  validation {
    condition     = var.aks_service_cidr == "" || can(cidrnetmask(var.aks_service_cidr))
    error_message = "aks_service_cidr must be an IPv4 CIDR range such as 10.128.0.0/20, not a subnet resource ID. No subnet is created for this range — Kubernetes allocates ClusterIPs from it, so it must sit outside your VNet's address space."
  }
}

variable "aks_dns_service_ip" {
  type        = string
  description = "CoreDNS ClusterIP. Must sit inside aks_service_cidr, which plan checks. Defaults to the eleventh address of aks_service_cidr, which is the Azure convention (10.0.64.10 for the default range). Ignored when create_cluster = false, for the same reason aks_service_cidr is."
  default     = ""

  # Shape only, for the ordering reason aks_service_cidr is checked here: the
  # containment precondition reduces this to a number in the locals, locals
  # evaluate first, and anything that is not four dotted octets fails there as a
  # tonumber() error naming neither the variable nor the fix. Appending /32 is
  # what makes cidrnetmask() a bare-address check — a value that already carries
  # a prefix produces two and fails to parse. Containment itself needs
  # aks_service_cidr, which a validation block cannot reach under this module's
  # >= 1.5 floor, so it lives on validate_network instead.
  validation {
    condition     = var.aks_dns_service_ip == "" || can(cidrnetmask("${var.aks_dns_service_ip}/32"))
    error_message = "aks_dns_service_ip must be a bare IPv4 address such as 10.128.0.10, with no prefix length. It is one ClusterIP taken out of aks_service_cidr, not a range."
  }
}

variable "additional_node_pools" {
  type = map(object({
    vm_size   = string
    min_count = number
    max_count = number
  }))
  description = "Additional node pools. The 'large' pool (Standard_D16s_v3, 16 vCPU / 64 GiB) carries ClickHouse (2 vCPU / 8 GiB at the default production sizing profile) and LangGraph Platform agent pods. min_count = 0 means it scales to zero when idle. Increase max_count to 3+ for Pass 4 (Agent Builder) with multiple simultaneous deployments."
  default = {
    large = {
      vm_size   = "Standard_D16s_v3" # 16 vCPU, 64 GiB — ClickHouse (2 vCPU/8Gi at production sizing) + dataplane agent pods
      min_count = 0
      max_count = 2
    }
  }
}

variable "langsmith_namespace" {
  type        = string
  description = "Namespace of the LangSmith deployment. Used to set up workload identity in a specific namespace for blob storage."
  default     = "langsmith"
}

variable "ingress_controller" {
  type        = string
  description = "Ingress controller to install. 'nginx' = NGINX via Helm, the current default and the only option with every TLS path validated. 'istio' = Istio via Helm (self-managed). 'istio-addon' = Azure managed Istio (AKS service mesh add-on); use for mTLS or multi-dataplane. 'agic' = Application Gateway Ingress Controller. 'envoy-gateway' = Envoy Gateway via Helm (Gateway API). 'none' = skip. See INGRESS_CONTROLLERS.md for the TLS compatibility matrix."
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "istio", "istio-addon", "agic", "envoy-gateway", "none"], var.ingress_controller)
    error_message = "ingress_controller must be 'nginx', 'istio', 'istio-addon', 'agic', 'envoy-gateway', or 'none'."
  }
}

variable "istio_version" {
  type        = string
  description = "Istio helm chart version. Only used when ingress_controller = 'istio'."
  default     = "1.29.1"
}

variable "istio_addon_revision" {
  type        = string
  description = "Azure Service Mesh revision. Format: 'asm-1-<minor>'. To list available revisions after cluster exists: az aks mesh get-upgrades -g <rg> -n <cluster>"
  default     = "asm-1-27"
}

variable "letsencrypt_email" {
  type        = string
  description = "Email address for Let's Encrypt certificate notifications. Required when tls_certificate_source = 'letsencrypt'."
  default     = ""
}

variable "langsmith_domain" {
  type        = string
  description = "Hostname for the LangSmith deployment (e.g. langsmith.example.com). Used in Helm values and ingress TLS configuration."
  default     = ""
}

variable "langsmith_helm_chart_version" {
  type        = string
  description = "Pin a specific LangSmith Helm chart version for reproducible deploys. Empty string = use latest available."
  default     = ""
}

variable "tls_certificate_source" {
  type        = string
  description = "TLS certificate source. 'letsencrypt' = HTTP-01 via cert-manager. 'dns01' = DNS-01 via cert-manager. 'existing' = bring your own cert. 'none' = HTTP only (demo/dev)."
  default     = "letsencrypt"

  validation {
    condition     = contains(["none", "letsencrypt", "dns01", "existing"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be 'none', 'letsencrypt', 'dns01', or 'existing'."
  }
}

# Both default true, which is what this module did before the flags existed. Set
# them false when attaching to a cluster (create_cluster = false) that already
# runs either component: Helm will not adopt a release it does not own, so the
# install fails on the CRDs that are already there.
variable "install_cert_manager" {
  type        = bool
  description = "Install cert-manager into the cluster. Set false when the cluster already runs it. tls_certificate_source = 'dns01' requires this to be true — the DNS-01 solver needs a workload-identity annotation Terraform only adds to a cert-manager it installs itself."
  default     = true
}

variable "install_keda" {
  type        = bool
  description = "Install KEDA into the cluster. Set false when the cluster already runs it. KEDA scales the LangSmith queue workers on Redis queue depth, so something has to provide it."
  default     = true
}

variable "postgres_admin_username" {
  type        = string
  description = "The username of the Postgres administrator"
  default     = "langsmith"
}

variable "postgres_admin_password" {
  type        = string
  description = "The password of the Postgres administrator. Set via: source setup-env.sh"
  sensitive   = true
  default     = ""
}

# ── LangSmith secrets (stored in Key Vault by the keyvault module) ────────────
# These are written to Azure Key Vault on first apply. On subsequent runs,
# setup-env.sh reads them back from Key Vault so they stay stable.
# Application deployment uses helm/scripts/generate-secrets.sh to pull from KV.

variable "langsmith_release_name" {
  type        = string
  description = "Helm release name for LangSmith (used for Workload Identity federated credential subjects in the blob module)"
  default     = "langsmith"
}

variable "langsmith_license_key" {
  type        = string
  description = "LangSmith enterprise license key. Stored in Key Vault and in K8s secret langsmith-license."
  sensitive   = true
  default     = ""
}

variable "langsmith_admin_password" {
  type        = string
  description = "Initial LangSmith organization admin password. Stored in Key Vault: langsmith-admin-password."
  sensitive   = true
  default     = ""
}

variable "langsmith_admin_email" {
  type        = string
  description = "Initial LangSmith organization admin email. Set via setup-env.sh — used as initialOrgAdminEmail in Helm values."
  default     = ""
}

variable "langsmith_api_key_salt" {
  type        = string
  description = "Salt used to hash LangSmith API keys. Generate once: openssl rand -base64 32. Keep stable — changing invalidates all API keys. Stored in Key Vault: langsmith-api-key-salt. Set via setup-env.sh (TF_VAR_langsmith_api_key_salt)."
  sensitive   = true
  default     = ""
}

variable "langsmith_jwt_secret" {
  type        = string
  description = "JWT secret for LangSmith Basic Auth sessions. Generate once: openssl rand -base64 32. Keep stable. Stored in Key Vault: langsmith-jwt-secret. Set via setup-env.sh (TF_VAR_langsmith_jwt_secret)."
  sensitive   = true
  default     = ""
}

# ── LangGraph Platform encryption keys ───────────────────────────────────────
# Stored in Key Vault by Terraform. Read by generate-secrets.sh when enabling
# optional features via Helm overlays. Generate once and never change.

variable "langsmith_deployments_encryption_key" {
  type        = string
  description = "Fernet key for LangSmith Deployments. Stored in Key Vault: langsmith-deployments-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_agent_builder_encryption_key" {
  type        = string
  description = "Fernet key for Agent Builder. Stored in Key Vault: langsmith-agent-builder-encryption-key."
  sensitive   = true
  default     = ""
}

variable "langsmith_insights_encryption_key" {
  type        = string
  description = "Fernet key for Insights (Clio). Stored in Key Vault: langsmith-insights-encryption-key. Must stay stable — changing breaks existing insights data."
  sensitive   = true
  default     = ""
}

variable "langsmith_polly_encryption_key" {
  type        = string
  description = "Fernet key for Polly agent. Stored in Key Vault: langsmith-polly-encryption-key. Must stay stable — changing breaks existing Polly data."
  sensitive   = true
  default     = ""
}

# ── WAF ───────────────────────────────────────────────────────────────────────

variable "create_waf" {
  type        = bool
  description = "Deploy an Azure WAF policy (OWASP 3.2 + bot protection). Attach to Application Gateway or Front Door manually after creation."
  default     = false
}

variable "waf_mode" {
  type        = string
  description = "WAF enforcement mode: Detection (log only) or Prevention (block)"
  default     = "Prevention"
}

# ── Diagnostics ───────────────────────────────────────────────────────────────

variable "create_diagnostics" {
  type        = bool
  description = "Deploy Azure Monitor Log Analytics workspace and diagnostic settings for AKS, Key Vault, and PostgreSQL."
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "Log Analytics workspace retention in days."
  default     = 90
}

# ── Bastion ───────────────────────────────────────────────────────────────────

variable "create_bastion" {
  type        = bool
  description = "Deploy a jump VM for private AKS cluster access via az ssh vm."
  default     = false
}

variable "bastion_vm_size" {
  type        = string
  description = "VM SKU for the bastion host."
  default     = "Standard_B2s"
}

variable "bastion_admin_ssh_public_key" {
  type        = string
  description = "SSH public key for emergency admin access to the bastion VM."
  default     = ""
}

variable "bastion_allowed_ssh_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed inbound SSH to the bastion. Restrict to VPN/corporate ranges in production."
  default     = ["0.0.0.0/0"]
}

# ── DNS ───────────────────────────────────────────────────────────────────────

variable "create_dns_zone" {
  type        = bool
  description = "Create an Azure DNS zone and A record for the LangSmith domain."
  default     = false
}

variable "ingress_ip" {
  type        = string
  description = "Public IP of the NGINX ingress Load Balancer. Used by the DNS module for the A record. Get from: kubectl get svc -n ingress-nginx."
  default     = ""
}

# ── Multi-AZ ─────────────────────────────────────────────────────────────────

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to deploy into. Use [\"1\",\"2\",\"3\"] for zone-redundant HA. Default [\"1\"] for single-zone."
  default     = ["1"]
}

variable "postgres_standby_availability_zone" {
  type        = string
  description = "Standby AZ for Postgres HA (ZoneRedundant mode). Leave empty to disable HA standby."
  default     = ""
}

variable "postgres_geo_redundant_backup" {
  type        = bool
  description = "Enable geo-redundant backups for PostgreSQL."
  default     = false
}

# ── Helm / deployment flags (read by bash scripts, not by Terraform) ──────────
# These variables are declared here only to prevent Terraform from warning
# about undeclared variables in terraform.tfvars. They are read by
# helm/scripts/init-values.sh and helm/scripts/deploy.sh.

variable "sizing_profile" {
  type        = string
  description = "Helm sizing overlay. One of: minimum | dev | production | production-large. Read by helm/scripts/init-values.sh and deploy.sh — Terraform ignores this value."
  default     = "production"
}

variable "enable_deployments" {
  type        = bool
  description = "Pass 3 — enable LangGraph Platform (hostBackend, listener, operator). Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_agent_builder" {
  type        = bool
  description = "Pass 4 — enable Agent Builder UI. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_insights" {
  type        = bool
  description = "Pass 5 — enable Insights / Clio. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_polly" {
  type        = bool
  description = "Pass 5 — enable Polly AI eval agent. Read by deploy.sh — Terraform ignores this value."
  default     = false
}

variable "enable_fleet" {
  type        = bool
  description = <<-EOT
    Pass 4 — enable standalone Fleet (chart v0.15+), the re-architected successor to
    Agent Builder. Unlike the other enable_* flags, this one BOTH drives Terraform
    resources (a dedicated langsmith_fleet Postgres database and the langsmith-fleet-postgres
    K8s secret) AND is read by deploy.sh/init-values.sh. Requires enable_deployments = true
    (host-backend serves Fleet's OAuth provider/token endpoints) and postgres_source = "external".
    Reuses langsmith_agent_builder_encryption_key. Mutually exclusive with enable_agent_builder
    (the legacy config.agentBuilder path). Fleet's Redis is the chart's in-cluster bundled pod.
  EOT
  default     = false
}

variable "dns_label" {
  type        = string
  description = "Azure Public IP DNS label for the ingress LoadBalancer. Results in <label>.<region>.cloudapp.azure.com. Works with nginx, istio, istio-addon, envoy-gateway. Leave empty to skip."
  default     = ""
}

# ── AGIC (Application Gateway Ingress Controller) ─────────────────────────────

variable "agic_subnet_address_prefix" {
  type        = list(string)
  description = "CIDR prefix for the Application Gateway dedicated subnet. Must be /24 or larger. Only used when ingress_controller = 'agic'."
  default     = ["10.0.96.0/24"]
}

variable "agw_sku_tier" {
  type        = string
  description = "Application Gateway SKU tier. 'Standard_v2' or 'WAF_v2' (enables WAF). Only used when ingress_controller = 'agic'."
  default     = "Standard_v2"

  validation {
    condition     = contains(["Standard_v2", "WAF_v2"], var.agw_sku_tier)
    error_message = "agw_sku_tier must be 'Standard_v2' or 'WAF_v2'."
  }
}

# ── Envoy Gateway ─────────────────────────────────────────────────────────────

variable "envoy_gateway_version" {
  type        = string
  description = "Envoy Gateway Helm chart version. Only used when ingress_controller = 'envoy-gateway'."
  default     = "v1.2.0"
}
