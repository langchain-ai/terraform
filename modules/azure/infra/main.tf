# ══════════════════════════════════════════════════════════════════════════════
# Module: langsmith (root / orchestration)
# Purpose: Wires all sub-modules together in the correct dependency order to
#          produce a full LangSmith deployment on Azure.
#
# Deployment order (Terraform resolves via implicit dependencies):
#   1. azurerm_resource_group  — must exist before everything else
#   2. module.vnet             — network must exist before compute/DB
#   3. module.aks              — cluster needed for OIDC issuer URL (blob module)
#      module.postgres         — parallel with AKS (both need VNet)
#      module.redis            — parallel with AKS and postgres
#   4. module.blob             — needs AKS OIDC issuer URL for federated creds
#   5. module.keyvault         — needs blob managed identity principal ID for RBAC
#   6. module.k8s_bootstrap    — needs cluster credentials + all connection URLs
#
# Deployment pattern:
#   Pass 1 (this module): terraform apply → Azure infra only (AKS, Postgres, Redis, Blob, KV)
#   Pass 2+: helm/scripts/ → LangSmith Helm deploy, optional feature overlays
# ══════════════════════════════════════════════════════════════════════════════

locals {
  # name_prefix may be written with or without the separator hyphen — normalize
  # once, then derive both the resource-name suffix and the environment tag from
  # it. So "prod" and "-prod" both give "langsmith-<resource>-prod", and an
  # empty name_prefix means no suffix at all, for single-deployment subscriptions.
  deployment_name = trimprefix(var.name_prefix, "-")
  name_suffix     = local.deployment_name == "" ? "" : "-${local.deployment_name}"

  # Postgres, Redis, Storage and Key Vault names live in a namespace shared with
  # every other Azure tenant, so "langsmith-postgres-dev" is one deployment
  # anywhere in the world, not one per subscription. unique_resource_names adds a
  # per-subscription hash to those four and shortens the base from "langsmith" to
  # "ls" to buy back the characters inside the 24-char Storage/Key Vault limits.
  #
  #   false — legacy "langsmith-<resource><name_suffix>". Still the default so an
  #           existing deployment plans clean; see the warning on the variable.
  #   true  — "ls-<resource><name_suffix>", plus the hash on the four global names.
  #
  # sha256 of subscription_id + name_suffix rather than the random provider: the
  # value is derived, so repeat applies are stable and nothing is kept in state.
  name_base   = var.unique_resource_names ? "ls" : "langsmith"
  uniq_suffix = var.unique_resource_names ? "-${substr(sha256("${var.subscription_id}${local.name_suffix}"), 0, 6)}" : ""

  # Regional names — unique within the subscription, so no hash needed.
  resource_group_name = "${local.name_base}-rg${local.name_suffix}"
  vnet_name           = "${local.name_base}-vnet${local.name_suffix}"

  # Cluster name: derived for new clusters, or the customer's existing cluster
  # name when attaching to one (create_cluster = false). No fallback in the
  # attach case — an unset existing_cluster_name fails on the aks module's
  # precondition instead of looking up a cluster that was never created. The
  # derived name never reaches an attached cluster, so unique_resource_names has
  # no bearing on that path.
  aks_name = var.create_cluster ? "${local.name_base}-aks${local.name_suffix}" : var.existing_cluster_name

  # Globally-unique names — hashed, and each takes an explicit override so a
  # single colliding name can be pinned without renaming the whole deployment.
  postgres_name = var.postgres_name != "" ? var.postgres_name : "${local.name_base}-postgres${local.name_suffix}${local.uniq_suffix}"
  redis_name    = var.redis_name != "" ? var.redis_name : "${local.name_base}-redis${local.name_suffix}${local.uniq_suffix}"
  blob_name     = var.storage_account_name != "" ? var.storage_account_name : "${local.name_base}-blob${local.name_suffix}${local.uniq_suffix}" # blob module strips hyphens → "lsblobdeva1b2c3"

  # Key Vault name: max 24 chars, globally unique.
  # Uses the user-supplied keyvault_name or derives from name_prefix. When
  # attaching to a customer-owned vault (create_keyvault = false) the name is
  # theirs, with no fallback — an unset existing_keyvault_name fails on the
  # keyvault module's precondition instead of deriving a name for a vault that
  # was never created. The derived name never reaches an attached vault, so
  # unique_resource_names has no bearing on that path.
  keyvault_name = var.create_keyvault ? (var.keyvault_name != "" ? var.keyvault_name : "${local.name_base}-kv${local.name_suffix}${local.uniq_suffix}") : var.existing_keyvault_name

  # Whether the keyvault module creates each of its two role assignments. Both
  # default to create_keyvault: a vault this module creates gets both grants, a
  # customer's vault gets neither, because creating them there means calling
  # Microsoft.Authorization/roleAssignments/write on a resource their platform
  # team owns. Gated one apiece rather than together because the two requests
  # carry different principal types, and a subscription that delegates
  # roleAssignments/write through an ABAC condition on principalType can reject
  # the deployer's grant while permitting the managed identity's.
  keyvault_manage_terraform_admin_assignment  = var.keyvault_manage_terraform_admin_assignment != null ? var.keyvault_manage_terraform_admin_assignment : var.create_keyvault
  keyvault_manage_managed_identity_assignment = var.keyvault_manage_managed_identity_assignment != null ? var.keyvault_manage_managed_identity_assignment : var.create_keyvault

  # ── Network resolution ──────────────────────────────────────────────────────
  # create_vnet = true  → Terraform owns the whole network; BYO IDs are rejected
  #                       by the preconditions below rather than silently ignored.
  # create_vnet = false → vnet_id is reused, and each subnet is independently
  #                       either brought (ID supplied) or carved by Terraform.
  byo_aks_subnet      = !var.create_vnet && var.aks_subnet_id != ""
  byo_postgres_subnet = !var.create_vnet && var.postgres_subnet_id != ""
  byo_redis_subnet    = !var.create_vnet && var.redis_subnet_id != ""
  byo_agic_subnet     = !var.create_vnet && var.agic_subnet_id != ""
  byo_bastion_subnet  = !var.create_vnet && var.bastion_subnet_id != ""

  # A subnet is created only when it is needed by an enabled service and the
  # operator has not supplied one.
  create_aks_subnet      = !local.byo_aks_subnet
  create_postgres_subnet = var.postgres_source == "external" && !local.byo_postgres_subnet
  create_redis_subnet    = var.redis_source == "external" && !local.byo_redis_subnet

  vnet_id            = var.create_vnet ? module.vnet.vnet_id : var.vnet_id
  aks_subnet_id      = local.byo_aks_subnet ? var.aks_subnet_id : module.vnet.subnet_main_id
  postgres_subnet_id = local.byo_postgres_subnet ? var.postgres_subnet_id : module.vnet.subnet_postgres_id
  redis_subnet_id    = local.byo_redis_subnet ? var.redis_subnet_id : module.vnet.subnet_redis_id

  # Bastion and AGIC are supply-only under bring-your-own: Terraform carves their
  # subnets out of a VNet it owns, and reuses a supplied one otherwise. There is
  # no carve path inside someone else's VNet, so the preconditions below require
  # an ID whenever create_vnet = false.
  agic_subnet_id    = local.byo_agic_subnet ? var.agic_subnet_id : module.vnet.subnet_agic_id
  bastion_subnet_id = local.byo_bastion_subnet ? var.bastion_subnet_id : module.vnet.subnet_bastion_id

  # Subnet IDs are fixed-shape, and the variable validation anchors that shape
  # before this runs, so index positionally:
  #   0:"" 1:subscriptions 2:<sub> 3:resourceGroups 4:<rg>
  #   5:providers 6:Microsoft.Network 7:virtualNetworks 8:<vnet> 9:subnets 10:<name>
  byo_aks_subnet_parts  = split("/", var.aks_subnet_id)
  byo_agic_subnet_parts = split("/", var.agic_subnet_id)

  # Every supplied subnet ID, lowercased for comparison since Azure treats
  # resource IDs case-insensitively. Used to reject the same subnet twice.
  supplied_subnet_ids = [
    for id in local.byo_subnet_ids : lower(id) if id != ""
  ]

  # Every bring-your-own subnet input, in one list so the shape checks below do
  # not have to be extended each time another is added.
  byo_subnet_ids = [
    var.aks_subnet_id,
    var.postgres_subnet_id,
    var.redis_subnet_id,
    var.agic_subnet_id,
    var.bastion_subnet_id,
  ]

  # The endpoints the storage and Key Vault firewalls need on whichever subnet
  # AKS ends up in. Terraform puts both on a subnet it carves (see the
  # networking module), so this only matters for one you supply.
  required_aks_service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault"]

  manage_aks_subnet_endpoints = local.byo_aks_subnet && var.manage_byo_subnet_service_endpoints

  # Read through azapi rather than the azurerm_subnet above, which reports the
  # service names but not the locations scoping each one. Azure replaces the
  # whole list on write, so a body rebuilt from names alone would quietly drop
  # that scoping from endpoints belonging to the subnet's other workloads.
  byo_aks_subnet_service_endpoints = try(data.azapi_resource.byo_aks_subnet_endpoints[0].output.properties.serviceEndpoints, [])

  # ── AKS ClusterIP range ─────────────────────────────────────────────────────
  # The create path gets the default here rather than on the variable, so that
  # the variable can be required under bring-your-own without breaking it.
  # dns_service_ip has to sit inside the service CIDR, so derive it from
  # whichever range is in play instead of letting a stale default outlive it.
  aks_service_cidr   = var.aks_service_cidr != "" ? var.aks_service_cidr : "10.0.64.0/20"
  aks_dns_service_ip = var.aks_dns_service_ip != "" ? var.aks_dns_service_ip : cidrhost(local.aks_service_cidr, 10)

  # ── AKS subnet capacity ─────────────────────────────────────────────────────
  # Azure CNI is a flat network here (network_plugin = "azure", no overlay mode),
  # so nodes and pods both draw IPs from this subnet. Azure's formula is
  # (nodes + surge) + ((nodes + surge) * max_pods), which factors to
  # (nodes + surge) * (max_pods + 1). One surge node per pool covers upgrades.
  # Additional pools do not set max_pods, so they get the Azure CNI default.
  aks_default_pool_max_pods = 30

  # The additional pools Terraform will actually create. Attaching to a cluster
  # whose pools the customer owns creates none, so this is the map the aks module
  # is given and the map the capacity check below counts — one definition, so the
  # requirement can never describe pools that will not exist.
  aks_managed_node_pools = var.create_cluster || var.existing_cluster_node_pools_managed ? var.additional_node_pools : {}

  # Held per pool rather than as a single total, so the number and the error
  # message that has to justify it are built from the same place.
  aks_pool_sizing = merge(
    # Only a cluster Terraform creates gets a default pool. Attaching never adds
    # one, so counting it demands addresses nothing will draw.
    var.create_cluster ? {
      default = {
        nodes              = var.default_node_pool_max_count + 1
        addresses_per_node = var.default_node_pool_max_pods + 1
      }
    } : {},
    {
      for name, pool in local.aks_managed_node_pools : name => {
        nodes              = pool.max_count + 1
        addresses_per_node = local.aks_default_pool_max_pods + 1
      }
    }
  )

  # concat([0], ...) keeps sum() off an empty list, which is what attaching to a
  # cluster with customer-owned pools leaves behind.
  aks_required_ips = sum(concat([0], [for pool in local.aks_pool_sizing : pool.nodes * pool.addresses_per_node]))

  # One row per pool, so an operator can see which pool dominates the total
  # instead of being handed a number and two variable names.
  aks_demand_rows = [
    for name, pool in local.aks_pool_sizing :
    format("  %-14s %4d x %3d = %5d", "${name}:", pool.nodes, pool.addresses_per_node, pool.nodes * pool.addresses_per_node)
  ]

  # Smallest prefix that holds the requirement plus Azure's five reserved
  # addresses. ceil(log(n, 2)) is the host-bit count that covers n.
  aks_smallest_prefix = 32 - ceil(log(local.aks_required_ips + 5, 2))

  # Whichever prefixes the AKS subnet ends up with: read back from a supplied
  # subnet, or the ones Terraform is about to carve. Both paths are checked,
  # since a hand-picked aks_subnet_address_prefix can be just as undersized.
  # one() returns null at count = 0, so neither branch needs a data source guard.
  aks_subnet_prefixes = local.byo_aks_subnet ? coalesce(one(data.azurerm_subnet.byo_aks_subnet[*].address_prefixes), []) : var.aks_subnet_address_prefix

  # Azure reserves five addresses per subnet. concat([0], ...) keeps sum() off an
  # empty list. Prefixes may be disjoint, so capacity is their total.
  aks_usable_ips = sum(concat([0], [
    for prefix in local.aks_subnet_prefixes :
    pow(2, 32 - tonumber(split("/", prefix)[1]))
  ])) - 5

  # ── Address space of a reused VNet ──────────────────────────────────────────
  # A VNet ID is one segment shorter than a subnet ID, so the same positional
  # read applies with the name at 8 instead of 10:
  #   0:"" 1:subscriptions 2:<sub> 3:resourceGroups 4:<rg>
  #   5:providers 6:Microsoft.Network 7:virtualNetworks 8:<name>
  byo_vnet_parts     = split("/", var.vnet_id)
  vnet_address_space = coalesce(one(data.azurerm_virtual_network.byo_vnet[*].address_space), [])

  # Every prefix Terraform is about to carve, tagged with the variable that set
  # it so a failure names what to change. A service running in-cluster carves
  # nothing, so its prefix is left out rather than checked pointlessly.
  carved_prefixes = flatten([
    for entry in [
      { name = "aks_subnet_address_prefix", carve = local.create_aks_subnet, prefixes = var.aks_subnet_address_prefix },
      { name = "postgres_subnet_address_prefix", carve = local.create_postgres_subnet, prefixes = var.postgres_subnet_address_prefix },
      { name = "redis_subnet_address_prefix", carve = local.create_redis_subnet, prefixes = var.redis_subnet_address_prefix },
    ] : [for prefix in entry.prefixes : { name = entry.name, prefix = prefix }] if entry.carve
  ])

  # Terraform has no CIDR containment or overlap function, so reduce every range
  # to its numeric bounds and compare those. cidrhost(x, 0) is the network
  # address, and the last address is that plus the host count.
  measured_cidrs = distinct(concat(
    local.vnet_address_space,
    [for entry in local.carved_prefixes : entry.prefix],
    [local.aks_service_cidr],
    # A single address, measured as a /32 so the bounds below cover it too.
    ["${local.aks_dns_service_ip}/32"],
  ))
  cidr_first = { for cidr in local.measured_cidrs : cidr => sum([
    for i, octet in split(".", cidrhost(cidr, 0)) : tonumber(octet) * pow(256, 3 - i)
  ]) }
  cidr_last = { for cidr in local.measured_cidrs : cidr => local.cidr_first[cidr] + pow(2, 32 - tonumber(split("/", cidr)[1])) - 1 }

  # A carved subnet has to fall inside one of the VNet's address prefixes. Azure
  # will not split a subnet across two of them, so containment is per-prefix.
  uncontained_prefixes = [
    for entry in local.carved_prefixes : "${entry.prefix} (${entry.name})" if !anytrue([
      for space in local.vnet_address_space :
      local.cidr_first[entry.prefix] >= local.cidr_first[space] &&
      local.cidr_last[entry.prefix] <= local.cidr_last[space]
    ])
  ]

  # The ClusterIP range is the opposite case: it is not carved from the VNet and
  # must stay clear of it. Two ranges overlap unless one ends before the other
  # starts.
  service_cidr_overlaps_vnet = anytrue([
    for space in local.vnet_address_space :
    local.cidr_first[local.aks_service_cidr] <= local.cidr_last[space] &&
    local.cidr_last[local.aks_service_cidr] >= local.cidr_first[space]
  ])

  # AKS takes the CoreDNS address out of the service range and rejects one that
  # sits outside it. A /32 starts and ends at the same number, so its first
  # bound is the address.
  dns_service_ip_outside_service_cidr = (
    local.cidr_first["${local.aks_dns_service_ip}/32"] < local.cidr_first[local.aks_service_cidr] ||
    local.cidr_first["${local.aks_dns_service_ip}/32"] > local.cidr_last[local.aks_service_cidr]
  )

  # ── Common tags ─────────────────────────────────────────────────────────────
  # Applied to every Azure resource in every sub-module.
  # Sub-modules merge their own { module = "..." } tag on top.
  # Customize via the environment/owner/cost_center variables.
  # environment falls back to name_prefix so the deployment name and the tag
  # stay in sync without the operator setting both.
  common_tags = merge(
    {
      environment = coalesce(var.environment, local.deployment_name, "dev")
      project     = "langsmith"
      managed_by  = "terraform"
    },
    var.owner != "" ? { owner = var.owner } : {},
    var.cost_center != "" ? { cost_center = var.cost_center } : {}
  )
}

# The resource group that contains all LangSmith Azure resources.
# Deleting this resource group will delete EVERYTHING inside it.
resource "azurerm_resource_group" "resource_group" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags

  # Assert the derived names fit Azure's limits before anything is created.
  # Without this, an over-long name_prefix surfaces as an Azure 400 partway
  # through the apply, after the resource group, VNet, and AKS already exist.
  # Key Vault binds first: it keeps its hyphens inside the same 24-char limit
  # Storage has, so a ~12-char name_prefix is the practical ceiling under
  # unique_resource_names.
  lifecycle {
    precondition {
      condition     = length(replace(local.blob_name, "-", "")) >= 3 && length(replace(local.blob_name, "-", "")) <= 24
      error_message = "Storage account name '${replace(local.blob_name, "-", "")}' is ${length(replace(local.blob_name, "-", ""))} chars; Azure allows 3-24. Shorten var.name_prefix or set var.storage_account_name explicitly."
    }
    precondition {
      condition     = length(local.keyvault_name) >= 3 && length(local.keyvault_name) <= 24
      error_message = "Key Vault name '${local.keyvault_name}' is ${length(local.keyvault_name)} chars; Azure allows 3-24. Shorten var.name_prefix or set var.keyvault_name explicitly."
    }
    precondition {
      condition     = length(local.postgres_name) <= 63 && length(local.redis_name) <= 60
      error_message = "Postgres name '${local.postgres_name}' must be <= 63 chars and Redis name '${local.redis_name}' <= 60. Shorten var.name_prefix or set var.postgres_name / var.redis_name explicitly."
    }
  }
}

# ── Networking ────────────────────────────────────────────────────────────────
# Creates the VNet plus the dedicated subnets (AKS, PostgreSQL, Redis) that the
# enabled services need. With create_vnet = false the VNet is reused and only
# the subnets that were not supplied get created inside it — set every subnet ID
# and this module creates nothing at all.

module "vnet" {
  source              = "./modules/networking"
  network_name        = local.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  create_vnet      = var.create_vnet
  existing_vnet_id = var.vnet_id

  # A subnet is skipped when the operator supplied one, or when the service it
  # serves runs in-cluster and needs no dedicated subnet.
  create_main_subnet     = local.create_aks_subnet
  create_postgres_subnet = local.create_postgres_subnet
  create_redis_subnet    = local.create_redis_subnet

  main_subnet_address_prefix     = var.aks_subnet_address_prefix
  postgres_subnet_address_prefix = var.postgres_subnet_address_prefix
  redis_subnet_address_prefix    = var.redis_subnet_address_prefix

  # The bastion subnet is carved only out of a VNet Terraform owns. Under
  # bring-your-own the operator supplies it instead, and local.bastion_subnet_id
  # selects it.
  enable_bastion = var.create_bastion && var.create_vnet

  # AGIC subnet: provisioned only when ingress_controller = "agic"
  enable_agic                = var.ingress_controller == "agic" && var.create_vnet
  agic_subnet_address_prefix = var.agic_subnet_address_prefix

  tags = local.common_tags
}

# ── Input validation ──────────────────────────────────────────────────────────
# Cross-variable network checks that a single variable's validation block cannot
# express. These fire at plan time with an actionable message rather than
# surfacing as an opaque Azure API error partway through an apply.

# Both reads run at plan time, so whoever runs plan needs read access to the
# supplied subnets — they usually live in the network team's resource group.

# Reads an operator-supplied Postgres subnet to confirm the flexibleServers
# delegation is present. The azurerm_subnet data source does not expose
# delegations, so this goes through azapi.
data "azapi_resource" "byo_postgres_subnet" {
  count                  = local.byo_postgres_subnet && var.postgres_source == "external" ? 1 : 0
  type                   = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  resource_id            = var.postgres_subnet_id
  response_export_values = ["properties.delegations"]
}

# Reads a reused VNet for its address space, so the prefixes Terraform is about
# to carve inside it can be checked before apply. Gated on vnet_id being set as
# well as create_vnet, so an empty vnet_id reaches its own precondition below
# rather than failing on the positional read.
data "azurerm_virtual_network" "byo_vnet" {
  count               = !var.create_vnet && var.vnet_id != "" ? 1 : 0
  name                = local.byo_vnet_parts[8]
  resource_group_name = local.byo_vnet_parts[4]
}

# Reads an operator-supplied AKS subnet for its address prefixes, and for the
# service endpoints the storage and Key Vault firewalls depend on when Terraform
# is only checking for them.
data "azurerm_subnet" "byo_aks_subnet" {
  count                = local.byo_aks_subnet ? 1 : 0
  name                 = local.byo_aks_subnet_parts[10]
  virtual_network_name = local.byo_aks_subnet_parts[8]
  resource_group_name  = local.byo_aks_subnet_parts[4]
}

# Reads an operator-supplied Application Gateway subnet for its address prefixes.
# The gateway originates traffic from this subnet rather than from an in-cluster
# namespace, so the NetworkPolicy in k8s-bootstrap has to admit it by IP range.
data "azurerm_subnet" "byo_agic_subnet" {
  count                = local.byo_agic_subnet ? 1 : 0
  name                 = local.byo_agic_subnet_parts[10]
  virtual_network_name = local.byo_agic_subnet_parts[8]
  resource_group_name  = local.byo_agic_subnet_parts[4]
}

# ── Service endpoints on a supplied AKS subnet ────────────────────────────────
# Only when manage_byo_subnet_service_endpoints is on. Reads the endpoints
# already on the subnet so the patch below appends to them instead of replacing
# them, and so the body settles: after the apply the read returns what was
# added, the contains guard skips it, and the next plan is empty.
data "azapi_resource" "byo_aks_subnet_endpoints" {
  count                  = local.manage_aks_subnet_endpoints ? 1 : 0
  type                   = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  resource_id            = var.aks_subnet_id
  response_export_values = ["properties.serviceEndpoints"]
}

# Patches the one property. azurerm has no standalone service-endpoint resource
# (service_endpoints is an attribute of azurerm_subnet), so doing this in azurerm
# would mean importing the operator's subnet and owning its prefixes,
# delegations, NSG and route table associations along with it.
resource "azapi_update_resource" "byo_aks_subnet_endpoints" {
  count       = local.manage_aks_subnet_endpoints ? 1 : 0
  type        = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  resource_id = var.aks_subnet_id

  body = {
    properties = {
      serviceEndpoints = concat(
        local.byo_aks_subnet_service_endpoints,
        [
          for service in local.required_aks_service_endpoints : { service = service }
          if !contains([for e in local.byo_aks_subnet_service_endpoints : try(e.service, "")], service)
        ]
      )
    }
  }

  # Azure serializes writes per VNet, and azapi does not share the subnet lock
  # azurerm holds internally. Reachable whenever one subnet is supplied and
  # another is carved into the same VNet.
  depends_on = [module.vnet]
}

resource "terraform_data" "validate_network" {
  lifecycle {
    precondition {
      condition     = var.create_vnet || var.vnet_id != ""
      error_message = "vnet_id is required when create_vnet = false. Supply the VNet that LangSmith should deploy into."
    }

    # Attaching to a cluster pins the network too. The postcondition on the cluster
    # read requires aks_subnet_id to be a subnet the cluster already runs nodes in,
    # and a subnet Terraform is about to carve never is. So the combination has no
    # working configuration; say that here rather than failing later on a
    # postcondition that reads as a subnet mismatch.
    precondition {
      condition     = var.create_cluster || !var.create_vnet
      error_message = "create_cluster = false requires create_vnet = false. aks_subnet_id has to name a subnet the existing cluster already runs nodes in, and a freshly carved subnet never is, so attaching to a cluster while building a new VNet cannot succeed. Supply vnet_id and the subnet IDs of the network that cluster already uses."
    }

    # An empty aks_subnet_id otherwise falls through to the VNet module's output,
    # which is unknown until apply. That defers the cluster read and silences every
    # guard on it, on the first run — the run where the config is most likely wrong.
    precondition {
      condition     = var.create_cluster || var.aks_subnet_id != ""
      error_message = "create_cluster = false requires aks_subnet_id, set to a subnet the existing cluster already runs nodes in. Terraform checks it against the cluster's agent pools and fails with the list it accepts. It also drives the Blob and Key Vault firewall allowlists, so it is not something Terraform can pick for you."
    }

    # BYO subnet IDs are meaningless on the create path — fail loudly instead of
    # building a VNet the operator did not expect and ignoring what they set.
    precondition {
      condition     = !var.create_vnet || alltrue([for id in local.byo_subnet_ids : id == ""])
      error_message = "The aks, postgres, redis, agic and bastion subnet ID inputs only apply when create_vnet = false. Set create_vnet = false to reuse existing subnets, or clear these to let Terraform create the network."
    }

    # Every supplied subnet must belong to vnet_id. A subnet in a different VNet
    # would leave Postgres and Redis unreachable: the private DNS zones are
    # linked to vnet_id, and AKS could not route to them.
    # Compared lowercased because Azure treats resource IDs as case-insensitive
    # and will hand back "resourcegroups" in some contexts and "resourceGroups"
    # in others. Only the comparison is lowered; Azure still gets the original.
    precondition {
      condition = var.create_vnet || alltrue([
        for id in local.byo_subnet_ids :
        id == "" || startswith(lower(id), lower("${var.vnet_id}/subnets/"))
      ])
      error_message = "Every supplied subnet ID must be a subnet of vnet_id. Private DNS zones and AKS routing are wired to vnet_id, so a subnet in another VNet would be unreachable."
    }

    # Every resource is created in var.location while the subnets come from the
    # reused VNet, and Azure will not attach a resource in one region to a network
    # in another. Compared with spaces stripped and lowercased because Azure
    # accepts both "East US" and "eastus" for the same region; only the comparison
    # is normalized, Azure still gets the original string.
    precondition {
      condition     = length(data.azurerm_virtual_network.byo_vnet) == 0 || lower(replace(data.azurerm_virtual_network.byo_vnet[0].location, " ", "")) == lower(replace(var.location, " ", ""))
      error_message = "location is set to ${var.location}, but vnet_id names a VNet in ${try(data.azurerm_virtual_network.byo_vnet[0].location, "another region")}. Azure rejects a Postgres flexible server whose delegated subnet is in another region and a private endpoint whose subnet is in another region, so Postgres and Redis would fail partway through the apply. The Blob and Key Vault firewalls allowlist the AKS subnet through the regional Microsoft.Storage and Microsoft.KeyVault service endpoints, which do not reach across regions either. Set location to ${try(data.azurerm_virtual_network.byo_vnet[0].location, "the VNet's region")}."
    }

    # Both subnets are carved only out of a VNet Terraform owns, so under
    # bring-your-own the operator has to name one that already exists.
    precondition {
      condition     = !var.create_bastion || var.create_vnet || var.bastion_subnet_id != ""
      error_message = "create_bastion = true with create_vnet = false requires bastion_subnet_id. Terraform will not carve a bastion subnet inside a VNet it does not own, so supply one that already exists, named AzureBastionSubnet and /26 or larger."
    }

    # Azure rejects any other name outright, and it is the one bastion mistake
    # that a well-formed resource ID still lets through.
    precondition {
      condition     = !local.byo_bastion_subnet || lower(element(split("/", var.bastion_subnet_id), 10)) == "azurebastionsubnet"
      error_message = "bastion_subnet_id must point at a subnet named AzureBastionSubnet, and names '${element(split("/", var.bastion_subnet_id), 10)}'. Azure Bastion requires that exact name and will not deploy into a subnet called anything else."
    }

    precondition {
      condition     = var.ingress_controller != "agic" || var.create_vnet || var.agic_subnet_id != ""
      error_message = "ingress_controller = 'agic' with create_vnet = false requires agic_subnet_id. Application Gateway v2 needs a subnet to itself, Azure recommends a /24, and Terraform will not carve one inside a VNet it does not own."
    }

    # A Postgres Flexible Server can only be injected into a subnet delegated to
    # it. Without this check the failure surfaces as a generic Azure API error.
    precondition {
      condition = length(data.azapi_resource.byo_postgres_subnet) == 0 || contains([
        for d in try(data.azapi_resource.byo_postgres_subnet[0].output.properties.delegations, []) :
        try(d.properties.serviceName, "")
      ], "Microsoft.DBforPostgreSQL/flexibleServers")
      error_message = "The subnet given as postgres_subnet_id is not delegated to Microsoft.DBforPostgreSQL/flexibleServers. Add that delegation (action Microsoft.Network/virtualNetworks/subnets/join/action) to the subnet, or clear postgres_subnet_id and let Terraform create a correctly delegated subnet."
    }

    # The AKS subnet is allowlisted by ID on both the blob storage firewall
    # (hardcoded default-deny) and the Key Vault firewall. Azure rejects a subnet
    # rule whose subnet lacks the matching service endpoint, and azurerm exposes
    # no way to skip that check, so both endpoints are required regardless of
    # keyvault_default_action. Skipped when Terraform is the one adding them,
    # since checking first would fail the plan that would fix it.
    precondition {
      condition = local.manage_aks_subnet_endpoints || length(data.azurerm_subnet.byo_aks_subnet) == 0 || alltrue([
        for endpoint in local.required_aks_service_endpoints :
        contains(data.azurerm_subnet.byo_aks_subnet[0].service_endpoints, endpoint)
      ])
      error_message = "The subnet given as aks_subnet_id must carry both the Microsoft.Storage and Microsoft.KeyVault service endpoints. Without them the storage and Key Vault firewalls cannot allowlist the subnet and LangSmith pods lose access to blobs and secrets. Add both endpoints to the subnet, set manage_byo_subnet_service_endpoints = true to have Terraform add them, or clear aks_subnet_id and let Terraform create a subnet."
    }

    # Each service needs its own subnet. Postgres is the reason this is fatal
    # rather than untidy: its subnet is delegated, and Azure documents that no
    # other resource type may sit in a delegated subnet. Sharing passes the
    # delegation check above and then fails partway through a long apply.
    precondition {
      condition     = length(local.supplied_subnet_ids) == length(distinct(local.supplied_subnet_ids))
      error_message = "Every supplied subnet ID must name a different subnet. Postgres is the reason this is fatal rather than untidy: its subnet is delegated to Microsoft.DBforPostgreSQL/flexibleServers and Azure allows no other resource type inside a delegated subnet, so a shared subnet fails during apply. Application Gateway v2 and Azure Bastion each need a subnet to themselves as well."
    }

    # Undersizing is the one network mistake that survives apply: the cluster
    # comes up, and the autoscaler later stalls partway to max_count once the
    # subnet runs out of addresses. Check it here instead.
    precondition {
      condition = local.aks_usable_ips >= local.aks_required_ips
      error_message = join("\n", concat(
        [
          "The AKS subnet holds ${local.aks_usable_ips} usable addresses, short of the ${local.aks_required_ips} that Azure CNI needs for the configured node pools. Nodes and pods both draw IPs from this subnet, at (max_count + 1) nodes x (max_pods + 1) addresses per pool:",
          "",
        ],
        local.aks_demand_rows,
        [
          "",
          "Undersized, the cluster still starts and the autoscaler stalls short of max_count later, once the subnet runs dry. Widen the subnet to a /${local.aks_smallest_prefix} or larger, the smallest prefix that holds ${local.aks_required_ips} plus the 5 addresses Azure reserves.",
          # Which knobs move the number depends on which pools are counted, so the
          # advice follows the same gate the sizing does.
          var.create_cluster ? "Or lower the default pool: one off default_node_pool_max_count frees ${var.default_node_pool_max_pods + 1} addresses, and one off default_node_pool_max_pods frees ${var.default_node_pool_max_count + 1}." : "Or lower max_count on the pools listed above. The default pool is absent because attaching to an existing cluster never creates one, and setting existing_cluster_node_pools_managed = false drops the requirement to zero, leaving pool capacity to whoever owns the cluster.",
        ]
      ))
    }

    # 10.0.64.0/20 only avoids the VNet that Terraform builds. Inside someone
    # else's address space AKS can accept an overlapping ClusterIP range and
    # break later, so make the operator name one.
    #
    # Asked for only when Terraform creates the cluster. service_cidr is settable
    # once, on the cluster resource, so attaching to an existing cluster leaves
    # this value configuring nothing — and requiring one that has no effect turns
    # a plausible guess into a blocked deployment when the guess lands inside the
    # VNet.
    precondition {
      condition     = var.create_vnet || !var.create_cluster || var.aks_service_cidr != ""
      error_message = "aks_service_cidr is required when create_vnet = false and create_cluster = true. The 10.0.64.0/20 default is chosen to sit outside the Terraform-managed 10.0.0.0/17 and can fall inside your VNet. AKS requires a ClusterIP range that nothing on or connected to your VNet uses, so set one outside your VNet's address space."
    }

    # Requiring aks_service_cidr does not make it correct, and a range picked out
    # of the VNet's own space is the mistake the requirement exists to prevent.
    # AKS accepts the overlap at cluster creation and the collision surfaces
    # later, so it is worth the read. Gated on create_cluster for the reason the
    # requirement above is: an existing cluster's ClusterIP range is already set,
    # Azure would not have built it overlapping its own VNet, and nothing here
    # can change it.
    precondition {
      condition     = !var.create_cluster || length(data.azurerm_virtual_network.byo_vnet) == 0 || !local.service_cidr_overlaps_vnet
      error_message = "aks_service_cidr (${local.aks_service_cidr}) overlaps the address space of vnet_id (${join(", ", local.vnet_address_space)}). Kubernetes ClusterIPs are not carved from the VNet, and AKS requires a range nothing on or connected to it uses. This check only sees the VNet's own address space, so keep clear of peered and on-premises ranges too."
    }

    # Left empty the address is derived from the range and is always inside it.
    # Set explicitly it is a second place the range is written down, and a change
    # to aks_service_cidr strands it — the pair is exactly what an operator edits
    # while working out a range their VNet does not already use. Azure rejects
    # the mismatch partway through apply, once the resource group and Key Vault
    # exist. Gated on create_cluster because both values land on the cluster
    # resource and nowhere else.
    precondition {
      condition     = !var.create_cluster || !local.dns_service_ip_outside_service_cidr
      error_message = "aks_dns_service_ip (${local.aks_dns_service_ip}) is outside aks_service_cidr (${local.aks_service_cidr}). AKS takes the CoreDNS ClusterIP out of the service range. Leave aks_dns_service_ip empty to get ${cidrhost(local.aks_service_cidr, 10)}, the eleventh address, which is the Azure convention."
    }

    # The subnet prefix defaults describe the 10.0.0.0/17 VNet Terraform builds,
    # so on someone else's network they are wrong more often than right. Azure
    # rejects an out-of-range prefix partway through apply, once the resource
    # group and Key Vault already exist.
    precondition {
      condition     = length(data.azurerm_virtual_network.byo_vnet) == 0 || length(local.uncontained_prefixes) == 0
      error_message = "These subnet prefixes fall outside the address space of vnet_id (${join(", ", local.vnet_address_space)}): ${join(", ", local.uncontained_prefixes)}. Point each at a free range inside your VNet, or supply that subnet's ID to reuse a subnet that already exists."
    }
  }
}

# ── Kubernetes Cluster ────────────────────────────────────────────────────────
# AKS cluster with OIDC + Workload Identity enabled, NGINX ingress installed.
# The OIDC issuer URL output is consumed by module.blob for federated credentials.

module "aks" {
  source              = "./modules/k8s-cluster"
  cluster_name        = local.aks_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id           = local.aks_subnet_id
  # Both land on the cluster resource and nowhere else, so attaching to an
  # existing cluster ignores them — its ClusterIP range is whatever Azure gave it.
  service_cidr   = local.aks_service_cidr   # K8s ClusterIP range (must not overlap VNet)
  dns_service_ip = local.aks_dns_service_ip # CoreDNS IP (derived from service_cidr)

  # Bring-your-own cluster: read an existing AKS cluster instead of creating one.
  create_cluster = var.create_cluster
  create_vnet    = var.create_vnet

  # Both of these are passed straight from variables, never derived from another
  # resource. azurerm_resource_group.resource_group is pending creation on a first
  # apply, and local.aks_subnet_id reads module.vnet.subnet_main_id, whose module
  # has no count and so is pending too. A reference to either draws a dependency
  # edge that defers the cluster lookup to apply, taking the OIDC issuer, Workload
  # Identity, node subnet, and region guards with it, silent on exactly the run
  # where a misconfiguration is most likely. var.aks_subnet_id is the right value
  # to use because create_cluster = false requires create_vnet = false.
  existing_cluster_resource_group_name = var.existing_cluster_resource_group_name
  existing_cluster_subnet_id           = var.aks_subnet_id

  default_node_pool_vm_size   = var.default_node_pool_vm_size
  default_node_pool_min_count = var.default_node_pool_min_count
  default_node_pool_max_count = var.default_node_pool_max_count
  default_node_pool_max_pods  = var.default_node_pool_max_pods

  # Additional pools (e.g. "large" for ClickHouse / memory-heavy workloads).
  # On a pre-existing cluster whose node pools the customer owns this is empty,
  # so Terraform doesn't attach pools to a cluster it doesn't manage. The subnet
  # capacity check counts this same map.
  additional_node_pools = local.aks_managed_node_pools

  # Ingress controller: 'nginx' (Helm), 'istio' (Helm), 'istio-addon' (Azure managed), 'agic', 'envoy-gateway', 'none'
  ingress_controller   = var.ingress_controller
  dns_label            = var.dns_label
  istio_version        = var.istio_version
  istio_addon_revision = var.istio_addon_revision

  # AGIC — wired from vnet module output
  subscription_id = var.subscription_id
  agic_subnet_id  = local.agic_subnet_id

  # A WAF policy can only be associated with the WAF_v2 tier, so create_waf
  # decides the tier rather than leaving the two to be set into a combination
  # that fails at apply. agw_sku_tier still governs the no-WAF case, which keeps
  # the tier of anyone who set it explicitly to run the gateway without a policy.
  agw_sku_tier       = var.create_waf ? "WAF_v2" : var.agw_sku_tier
  firewall_policy_id = one(module.waf[*].waf_policy_id)

  agic_network_contributor_scope = var.agic_network_contributor_scope

  # Envoy Gateway
  envoy_gateway_version = var.envoy_gateway_version

  langsmith_namespace    = var.langsmith_namespace
  langsmith_release_name = var.langsmith_release_name

  # Preserve existing identity name when migrating from storage module.
  # New deployments leave this unset and get "${cluster_name}-app-identity".
  workload_identity_name = "k8s-app-identity"

  availability_zones = var.availability_zones

  # API server access — empty list keeps the master publicly reachable for
  # Terraform-driven Helm/kubectl steps. Populate var.aks_authorized_ip_ranges
  # in terraform.tfvars to restrict to operator/CI CIDRs.
  authorized_ip_ranges = var.aks_authorized_ip_ranges

  tags = local.common_tags
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
# Managed PostgreSQL Flexible Server in a private subnet.
# Only provisioned when postgres_source = "external".
# When postgres_source = "in-cluster", the Helm chart manages its own Postgres pod.

module "postgres" {
  count               = var.postgres_source == "external" ? 1 : 0
  source              = "./modules/postgres"
  name                = local.postgres_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  vnet_id             = local.vnet_id # needed to link the private DNS zone
  subnet_id           = local.postgres_subnet_id

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
  database_name  = var.postgres_database_name
  sku_name       = var.postgres_sku_name

  availability_zone            = var.availability_zones[0]
  standby_availability_zone    = var.postgres_standby_availability_zone
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  # Create the dedicated langsmith_fleet database when standalone Fleet is enabled.
  enable_fleet = var.enable_fleet

  tags = local.common_tags
}

# ── Redis ─────────────────────────────────────────────────────────────────────
# Managed Redis Cache (Premium) in a private subnet.
# Only provisioned when redis_source = "external".
# When redis_source = "in-cluster", the Helm chart manages its own Redis pod.

module "redis" {
  count               = var.redis_source == "external" ? 1 : 0
  source              = "./modules/redis"
  name                = local.redis_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  resource_group_id   = azurerm_resource_group.resource_group.id # azapi parent_id for AMR
  subnet_id           = local.redis_subnet_id                    # private endpoint goes here
  vnet_id             = local.vnet_id                            # private DNS zone link
  amr_sku             = var.amr_sku
  high_availability   = var.redis_high_availability

  tags = local.common_tags
}

# ── Blob Storage ──────────────────────────────────────────────────────────────
# Azure Blob Storage for trace objects.
# The Workload Identity (Managed Identity + Federated Credentials) is created
# in the k8s-cluster module and passed in here for the RBAC role assignment.

module "blob" {
  source               = "./modules/storage"
  storage_account_name = local.blob_name
  container_name       = "${local.blob_name}-container"
  location             = var.location
  resource_group_name  = azurerm_resource_group.resource_group.name

  ttl_enabled    = var.blob_ttl_enabled
  ttl_short_days = var.blob_ttl_short_days
  ttl_long_days  = var.blob_ttl_long_days

  # Workload Identity from k8s-cluster module — implicit dep on module.aks.
  workload_identity_principal_id = module.aks.workload_identity_principal_id
  workload_identity_client_id    = module.aks.workload_identity_client_id

  # Default-deny on the storage data plane. AKS pods reach blobs via the
  # Microsoft.Storage service endpoint on the AKS subnet (see networking module).
  # Operators with extra clients (CI runners, jumpboxes) add their public IPs
  # via var.storage_allowed_ips.
  allowed_subnet_ids = [local.aks_subnet_id]
  allowed_ips        = var.storage_allowed_ips

  tags = local.common_tags

  # A subnet ID is a plain string and creates no dependency, so the firewall rule
  # has to be told to wait for the endpoint that makes it valid.
  depends_on = [azapi_update_resource.byo_aks_subnet_endpoints]
}

# ── Key Vault ─────────────────────────────────────────────────────────────────
# Centralized secret storage for all LangSmith sensitive values.
# Depends on blob module (needs the managed identity principal ID for RBAC).
# Secrets stored here: postgres password, admin password, license key, JWT
# secret, API key salt, and all Fernet encryption keys.
#
# First-apply: Key Vault is created and all current TF_VAR_* values are stored.
# Subsequent applies: setup-env.sh reads from Key Vault instead of local files.

module "keyvault" {
  source              = "./modules/keyvault"
  name                = local.keyvault_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  # Bring-your-own Key Vault: attach to a customer-owned vault instead of
  # creating one. The module writes its secrets into that vault and changes
  # nothing else about it, so the network ACL and retention settings below are
  # ignored on this path.
  create_keyvault                       = var.create_keyvault
  existing_keyvault_name                = var.existing_keyvault_name
  existing_keyvault_resource_group_name = var.existing_keyvault_resource_group_name
  manage_terraform_admin_assignment     = local.keyvault_manage_terraform_admin_assignment
  manage_managed_identity_assignment    = local.keyvault_manage_managed_identity_assignment

  # The managed identity used by LangSmith pods gets read-only access to
  # all secrets so future CSI-driver integration requires no RBAC changes.
  managed_identity_principal_id = module.blob.k8s_managed_identity_principal_id

  # Principal type of the apply identity for its Secrets Officer grant. Only
  # needed where the subscription gates roleAssignments/write on principalType.
  terraform_principal_type = var.terraform_principal_type

  # Network ACLs — default Allow keeps first-apply secret creation working.
  # Production deployments override keyvault_default_action = "Deny" and
  # populate keyvault_allowed_ips. The AKS subnet is always allowlisted so
  # pods can read secrets via the Microsoft.KeyVault service endpoint.
  network_default_action = var.keyvault_default_action
  allowed_ips            = var.keyvault_allowed_ips
  allowed_subnet_ids     = [local.aks_subnet_id]

  # ── Secrets ─────────────────────────────────────────────────────────────────
  # Values come from TF_VAR_* on first apply. setup-env.sh reads from Key Vault
  # on subsequent applies, eliminating local .secret files.
  postgres_admin_password  = var.postgres_admin_password
  langsmith_admin_password = var.langsmith_admin_password
  langsmith_license_key    = var.langsmith_license_key
  langsmith_api_key_salt   = var.langsmith_api_key_salt
  langsmith_jwt_secret     = var.langsmith_jwt_secret

  langsmith_deployments_encryption_key   = var.langsmith_deployments_encryption_key
  langsmith_agent_builder_encryption_key = var.langsmith_agent_builder_encryption_key
  langsmith_insights_encryption_key      = var.langsmith_insights_encryption_key
  langsmith_polly_encryption_key         = var.langsmith_polly_encryption_key

  purge_protection_enabled = var.keyvault_purge_protection

  tags = local.common_tags

  depends_on = [module.blob, azapi_update_resource.byo_aks_subnet_endpoints]
}

# ── Kubernetes Bootstrap ───────────────────────────────────────────────────────
# Connects to the AKS cluster and:
#   1. Creates the langsmith namespace, service account, resource quota, network policies
#   2. Installs cert-manager (TLS automation) and KEDA (autoscaling)
#   3. Creates K8s secrets for PostgreSQL and Redis connection URLs
#
# LangSmith application deployment is handled outside Terraform:
#   Pass 1.5: bash helm/scripts/get-kubeconfig.sh <cluster> <rg>
#   Pass 1.6: ACME_EMAIL=... bash helm/scripts/apply-cluster-issuers.sh
#   Pass 2:   bash helm/scripts/generate-secrets.sh && bash helm/scripts/deploy.sh
#   Pass 3+:  bash helm/scripts/deploy.sh --overlay overlays/<feature>.yaml
#
# Note: This module configures its own kubernetes/helm providers internally,
# so depends_on cannot be used here. Implicit deps via input variables ensure
# correct ordering (AKS/postgres/redis/blob must be ready before this runs).

module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"

  # Cluster connection — passed directly to the kubernetes/helm providers
  # inside the k8s-bootstrap module.
  host                   = module.aks.host
  client_certificate     = module.aks.client_certificate
  client_key             = module.aks.client_key
  cluster_ca_certificate = module.aks.cluster_ca_certificate

  # K8s namespace for LangSmith workloads
  langsmith_namespace = var.langsmith_namespace

  # Ingress controller — drives the NetworkPolicy's allowed source namespace.
  ingress_controller = var.ingress_controller

  # Application Gateway has no in-cluster namespace to allow, so the same policy
  # admits it by the address range of its dedicated subnet. Read from a supplied
  # subnet, otherwise the prefix the vnet module carved it from. Ignored unless
  # ingress_controller = "agic".
  agic_subnet_cidrs = local.byo_agic_subnet ? data.azurerm_subnet.byo_agic_subnet[0].address_prefixes : var.agic_subnet_address_prefix

  # Backing services — connection URLs are injected as K8s secrets.
  # generate-secrets.sh also writes these secrets with the full URL from KV.
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? module.postgres[0].connection_url : ""
  postgres_admin_password = var.postgres_source == "external" ? var.postgres_admin_password : ""
  use_external_redis      = var.redis_source == "external"
  redis_connection_url    = var.redis_source == "external" ? module.redis[0].connection_url : ""

  # Standalone Fleet — creates the langsmith-fleet-postgres secret pointing at the
  # dedicated langsmith_fleet database. No fleet Redis secret: Fleet uses the chart's
  # in-cluster bundled Redis (Azure Managed Redis can't do the logical-DB isolation
  # the AWS/GCP Fleet relies on).
  enable_fleet                  = var.enable_fleet
  fleet_postgres_connection_url = var.postgres_source == "external" && var.enable_fleet ? module.postgres[0].fleet_connection_url : ""

  # Blob storage — Workload Identity client ID is added as a pod annotation
  # so the OIDC token exchange can bind the pod to the Managed Identity.
  blob_managed_identity_client_id = module.blob.k8s_managed_identity_client_id

  # License key — stored in K8s secret langsmith-license.
  # App secrets (api_key_salt, jwt_secret, admin_password) are written by
  # helm/scripts/generate-secrets.sh from Azure Key Vault.
  langsmith_license_key = var.langsmith_license_key

  # Cluster components — off when the cluster already runs them, which is only
  # possible on the attach path. Helm cannot adopt a release it does not own.
  install_cert_manager = var.install_cert_manager
  install_keda         = var.install_keda

  # TLS / cert-manager
  tls_certificate_source          = var.tls_certificate_source
  letsencrypt_email               = var.letsencrypt_email
  cert_manager_identity_client_id = module.aks.cert_manager_identity_client_id
  subscription_id                 = var.subscription_id
  dns_zone_name                   = var.create_dns_zone ? var.langsmith_domain : ""
  dns_resource_group_name         = azurerm_resource_group.resource_group.name
}

# ── WAF (optional) ────────────────────────────────────────────────────────────
# Deploy Azure WAF policy with OWASP 3.2 + bot protection.
# Attach to Application Gateway or Azure Front Door after creation.
# Enable with: create_waf = true in terraform.tfvars

module "waf" {
  count               = var.create_waf ? 1 : 0
  source              = "./modules/waf"
  name                = "langsmith-waf${local.name_suffix}"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.location
  waf_mode            = var.waf_mode
  tags                = local.common_tags
}

# ── Diagnostics (optional) ────────────────────────────────────────────────────
# Azure Monitor Log Analytics + diagnostic settings for AKS, Key Vault, Postgres.
# Enable with: create_diagnostics = true in terraform.tfvars

module "diagnostics" {
  count               = var.create_diagnostics ? 1 : 0
  source              = "./modules/diagnostics"
  name                = "langsmith-logs${local.name_suffix}"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = var.location
  retention_days      = var.log_retention_days

  aks_id      = module.aks.cluster_id
  keyvault_id = module.keyvault.vault_id
  postgres_id = var.postgres_source == "external" ? module.postgres[0].postgres_id : ""

  # Null when no gateway exists, which falls back to the variable's default.
  agw_id = module.aks.agw_id

  # Boolean flags known at plan time — count cannot depend on computed resource IDs.
  # Key Vault diagnostics only when this module owns the vault: writing a
  # diagnostic setting onto a customer's vault changes their resource, and a
  # platform-owned vault usually already has one collecting AuditEvent.
  enable_aks_diag      = true
  enable_keyvault_diag = var.create_keyvault
  enable_postgres_diag = var.postgres_source == "external"
  enable_agw_diag      = var.ingress_controller == "agic"

  tags = local.common_tags
}

# ── Bastion (optional) ────────────────────────────────────────────────────────
# Jump VM for private AKS cluster access. Uses Azure AD SSH login.
# Enable with: create_bastion = true in terraform.tfvars

module "bastion" {
  count                = var.create_bastion ? 1 : 0
  source               = "./modules/bastion"
  name                 = "langsmith-bastion${local.name_suffix}"
  resource_group_name  = azurerm_resource_group.resource_group.name
  location             = var.location
  subnet_id            = local.bastion_subnet_id
  vm_size              = var.bastion_vm_size
  admin_ssh_public_key = var.bastion_admin_ssh_public_key
  allowed_ssh_cidrs    = var.bastion_allowed_ssh_cidrs
  tags                 = local.common_tags

  depends_on = [module.vnet]
}

# ── DNS (optional) ────────────────────────────────────────────────────────────
# Azure DNS zone + A record. Delegates DNS-01 to cert-manager for TLS.
# Enable with: create_dns_zone = true and set langsmith_domain + ingress_ip.

module "dns" {
  count               = var.create_dns_zone ? 1 : 0
  source              = "./modules/dns"
  domain              = var.langsmith_domain
  resource_group_name = azurerm_resource_group.resource_group.name
  ingress_ip          = var.ingress_ip
  tags                = local.common_tags

  # Grant cert-manager DNS Zone Contributor so it can create TXT records
  # for DNS-01 ACME challenges. Only needed when tls_certificate_source = "dns01".
  cert_manager_principal_id = var.tls_certificate_source == "dns01" ? module.aks.cert_manager_identity_principal_id : ""
}
