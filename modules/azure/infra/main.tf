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
  #
  # Both hash inputs are fixed for a deployment, so name_suffix_salt is the only
  # way out of a burned name. Bumping it rotates all four at once.
  # var.name_base overrides the switch outright, for a corporate naming standard.
  name_base   = var.name_base != "" ? var.name_base : (var.unique_resource_names ? "ls" : "langsmith")
  uniq_suffix = var.unique_resource_names ? "-${substr(sha256("${var.subscription_id}${local.name_suffix}${var.name_suffix_salt}"), 0, 6)}" : ""

  # Regional names — unique within the subscription, so no hash needed. Changing
  # an override after an apply is a destroy and recreate.
  resource_group_name = var.create_resource_group ? (var.resource_group_name != "" ? var.resource_group_name : "${local.name_base}-rg${local.name_suffix}") : var.existing_resource_group_name
  vnet_name           = var.vnet_name != "" ? var.vnet_name : "${local.name_base}-vnet${local.name_suffix}"

  # Attaching (create_cluster = false) takes the customer's name with no
  # fallback: an unset existing_cluster_name fails on the aks module's
  # precondition rather than deriving a name for a cluster nothing created.
  aks_name = var.create_cluster ? (var.cluster_name != "" ? var.cluster_name : "${local.name_base}-aks${local.name_suffix}") : var.existing_cluster_name

  # Globally-unique names — hashed, and each takes an explicit override so a
  # single colliding name can be pinned without renaming the whole deployment.
  postgres_name              = var.postgres_name != "" ? var.postgres_name : "${local.name_base}-postgres${local.name_suffix}${local.uniq_suffix}"
  redis_name                 = var.redis_name != "" ? var.redis_name : "${local.name_base}-redis${local.name_suffix}${local.uniq_suffix}"
  blob_name                  = var.storage_account_name != "" ? var.storage_account_name : "${local.name_base}-blob${local.name_suffix}${local.uniq_suffix}" # blob module strips hyphens → "lsblobdeva1b2c3"
  smithdb_name               = "${local.name_base}-smithdb${local.name_suffix}"
  smithdb_storage_name       = var.smithdb_storage_account_name != "" ? var.smithdb_storage_account_name : substr(replace("${local.name_base}smithdb${local.deployment_name}${replace(local.uniq_suffix, "-", "")}", "-", ""), 0, 24)
  langsmith_release_fullname = strcontains(var.langsmith_release_name, "langsmith") ? var.langsmith_release_name : "${var.langsmith_release_name}-langsmith"
  smithdb_service_account    = "${local.langsmith_release_fullname}-smithdb"

  # A StorageClass is cluster-scoped, unlike everything else this module creates
  # for SmithDB, so two deployments sharing a cluster collide on a fixed name and
  # the second apply fails on an object the first one owns. Suffix it the same
  # way as the namespaced resources above.
  smithdb_cache_storage_class = var.smithdb_cache_storage_class_name != "" ? var.smithdb_cache_storage_class_name : "smithdb-cache-premium-v2${local.name_suffix}${local.uniq_suffix}"

  # Max 24 chars, globally unique. Attaching takes the customer's name with no
  # fallback, same as aks_name above.
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
  create_postgres_subnet = (var.postgres_source == "external" || var.enable_smithdb) && !local.byo_postgres_subnet
  create_redis_subnet    = var.redis_source == "external" && !local.byo_redis_subnet

  vnet_id            = var.create_vnet ? module.vnet.vnet_id : var.vnet_id
  aks_subnet_id      = local.byo_aks_subnet ? var.aks_subnet_id : module.vnet.subnet_main_id
  postgres_subnet_id = local.byo_postgres_subnet ? var.postgres_subnet_id : module.vnet.subnet_postgres_id
  redis_subnet_id    = local.byo_redis_subnet ? var.redis_subnet_id : module.vnet.subnet_redis_id

  # Blob Private Endpoints default into the AKS subnet. That subnet already
  # carries this traffic to the same accounts, so placing them there adds one
  # address per endpoint and no new reachability.
  storage_private_endpoint_subnet_id = var.storage_private_endpoint_subnet_id != "" ? var.storage_private_endpoint_subnet_id : local.aks_subnet_id

  # Names that differ between commercial Azure and Azure Government. Zone names
  # are Microsoft's recommended names from the private endpoint DNS reference
  # (learn.microsoft.com/azure/private-link/private-endpoint-dns, 2026-08-11);
  # a private endpoint only registers its record automatically in a zone with
  # exactly this name. The cloudapp suffix is what Azure appends to a public IP
  # DNS label. Managed Redis has no Government zone because the service is not
  # offered there; redis_source refuses that combination at plan.
  azure_clouds = {
    public = {
      postgres_private_dns_zone = "privatelink.postgres.database.azure.com"
      blob_private_dns_zone     = "privatelink.blob.core.windows.net"
      keyvault_private_dns_zone = "privatelink.vaultcore.azure.net"
      cloudapp_suffix           = "cloudapp.azure.com"
    }
    usgovernment = {
      postgres_private_dns_zone = "privatelink.postgres.database.usgovcloudapi.net"
      blob_private_dns_zone     = "privatelink.blob.core.usgovcloudapi.net"
      keyvault_private_dns_zone = "privatelink.vaultcore.usgovcloudapi.net"
      cloudapp_suffix           = "cloudapp.usgovcloudapi.net"
    }
  }
  azure_cloud = local.azure_clouds[var.azure_environment]

  # Both accounts share one privatelink.blob.core.windows.net zone. Azure links
  # a zone name to a VNet once, so the root owns it and hands the ID to each
  # module instead of letting both create their own.
  create_blob_private_dns_zone = var.storage_private_endpoint_enabled && var.storage_private_dns_zone_id == ""
  blob_private_dns_zone_id     = local.create_blob_private_dns_zone ? azurerm_private_dns_zone.blob[0].id : var.storage_private_dns_zone_id

  # The Key Vault endpoint follows the blob endpoints into their subnet unless
  # given its own, and its zone works the same way: supplied, or created and
  # linked here.
  keyvault_private_endpoint_subnet_id = var.keyvault_private_endpoint_subnet_id != "" ? var.keyvault_private_endpoint_subnet_id : local.storage_private_endpoint_subnet_id
  create_keyvault_private_dns_zone    = var.keyvault_private_endpoint_enabled && var.keyvault_private_dns_zone_id == ""
  keyvault_private_dns_zone_id        = local.create_keyvault_private_dns_zone ? azurerm_private_dns_zone.keyvault[0].id : var.keyvault_private_dns_zone_id

  # A supplied PostgreSQL zone serves both Flexible Servers, LangSmith's and
  # the SmithDB metastore, so neither module creates or links one.
  postgres_private_dns_zone_supplied = var.postgres_private_dns_zone_id != ""

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
  # networking module), so this only matters for one you supply. With the Key
  # Vault private endpoint on, the vault's firewall no longer allowlists the
  # subnet (public access is off), so Azure has no subnet rule to validate and
  # Microsoft.KeyVault is not needed. Storage keeps its rule either way: both
  # accounts stay default-deny so turning their endpoints off never opens them.
  required_aks_service_endpoints = concat(["Microsoft.Storage"], var.keyvault_private_endpoint_enabled ? [] : ["Microsoft.KeyVault"])

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

  # ── AKS network mode ────────────────────────────────────────────────────────
  # The provider takes null for node-subnet mode and "overlay" for overlay, and
  # pod_cidr may only be set in overlay mode, so both are derived from the one
  # operator-facing variable. The data plane follows the mode unless named:
  # Cilium needs overlay, and Cilium's policy engine has to be Cilium too.
  aks_overlay             = var.aks_network_mode == "overlay"
  aks_network_plugin_mode = local.aks_overlay ? "overlay" : null
  aks_pod_cidr            = local.aks_overlay ? var.aks_pod_cidr : null
  aks_network_dataplane   = var.aks_network_dataplane != "" ? var.aks_network_dataplane : (local.aks_overlay ? "cilium" : "azure")
  aks_network_policy      = local.aks_network_dataplane == "cilium" ? "cilium" : "azure"

  # Ranges Azure keeps for itself on every AKS cluster; an overlay pod range that
  # touches one is refused at creation. Listed once so the check and its message
  # agree on what was compared.
  aks_reserved_cidrs = ["169.254.0.0/16", "172.30.0.0/16", "172.31.0.0/16", "192.0.2.0/24"]

  # ── AKS subnet capacity ─────────────────────────────────────────────────────
  # In node-subnet mode nodes and pods both draw IPs from this subnet. Azure's
  # formula is (nodes + surge) + ((nodes + surge) * max_pods), which factors to
  # (nodes + surge) * (max_pods + 1). One surge node per pool covers upgrades.
  # Additional pools do not set max_pods, so they get the Azure CNI default.
  # In overlay mode pods come from aks_pod_cidr and only the nodes count here,
  # at one address each.
  aks_default_pool_max_pods = 30

  # Held per pool rather than as a single total, so the number and the error
  # message that has to justify it are built from the same place. Only the pools
  # Terraform creates: an attached cluster's own pools are already in the subnet,
  # and Terraform cannot see their sizes.
  aks_pool_sizing = merge(
    var.create_cluster ? {
      default = {
        nodes              = var.default_node_pool_max_count + 1
        addresses_per_node = local.aks_overlay ? 1 : var.default_node_pool_max_pods + 1
      }
    } : {},
    {
      for name, pool in local.aks_managed_node_pools : name => {
        nodes              = pool.max_count + 1
        addresses_per_node = local.aks_overlay ? 1 : local.aks_default_pool_max_pods + 1
      }
    }
  )
  # concat([0], ...) keeps sum() off an empty list, which an attached cluster
  # with no pools to add produces.
  aks_required_ips = sum(concat([0], [for pool in local.aks_pool_sizing : pool.nodes * pool.addresses_per_node]))

  # Overlay hands every node a /24 of the pod range, so the range's capacity is
  # counted in nodes, surge included, across every pool.
  aks_node_total             = sum(concat([0], [for pool in local.aks_pool_sizing : pool.nodes]))
  aks_pod_cidr_node_capacity = local.aks_overlay ? pow(2, 24 - tonumber(split("/", var.aks_pod_cidr)[1])) : 0

  effective_node_pools = var.additional_node_pools

  # On a pre-existing cluster whose node pools the customer owns, an empty map, so
  # Terraform doesn't attach pools to a cluster it doesn't manage.
  aks_managed_node_pools = var.create_cluster || var.existing_cluster_node_pools_managed ? local.effective_node_pools : {}

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

  # ── Address space of the VNet the subnets are carved from ──────────────────
  # A VNet ID is one segment shorter than a subnet ID, so the same positional
  # read applies with the name at 8 instead of 10:
  #   0:"" 1:subscriptions 2:<sub> 3:resourceGroups 4:<rg>
  #   5:providers 6:Microsoft.Network 7:virtualNetworks 8:<name>
  byo_vnet_parts = split("/", var.vnet_id)
  # The configured space when Terraform builds the VNet, or the one read back
  # from vnet_id. Empty only under bring-your-own with no vnet_id, which has its
  # own precondition.
  vnet_address_space = var.create_vnet ? var.vnet_address_space : coalesce(one(data.azurerm_virtual_network.byo_vnet[*].address_space), [])
  # Names the VNet in a containment failure, so the message points at the input
  # that set its address space.
  vnet_address_space_source = var.create_vnet ? "vnet_address_space" : "vnet_id"

  # Every prefix Terraform is about to carve, tagged with the variable that set
  # it so a failure names what to change. A service running in-cluster carves
  # nothing, so its prefix is left out rather than checked pointlessly.
  carved_prefixes = flatten([
    for entry in [
      { name = "aks_subnet_address_prefix", carve = local.create_aks_subnet, prefixes = var.aks_subnet_address_prefix },
      { name = "postgres_subnet_address_prefix", carve = local.create_postgres_subnet, prefixes = var.postgres_subnet_address_prefix },
      { name = "redis_subnet_address_prefix", carve = local.create_redis_subnet, prefixes = var.redis_subnet_address_prefix },
      # Carved only out of a VNet Terraform owns, matching module.vnet below.
      { name = "agic_subnet_address_prefix", carve = var.ingress_controller == "agic" && var.create_vnet, prefixes = var.agic_subnet_address_prefix },
      { name = "bastion_subnet_address_prefix", carve = var.create_bastion && var.create_vnet, prefixes = var.bastion_subnet_address_prefix },
    ] : [for prefix in entry.prefixes : { name = entry.name, prefix = prefix }] if entry.carve
  ])

  # Subnets already in a reused VNet, which the carved prefixes must stay clear
  # of. module.vnet names its own subnets after local.vnet_name, and once applied
  # they show up in the VNet's subnet list too, so leave those out. Read only
  # when something is carved, since each sibling costs a subnet read.
  terraform_subnet_names = [for suffix in ["0", "postgres", "redis", "bastion", "agic"] : lower("${local.vnet_name}-subnet-${suffix}")]
  byo_vnet_sibling_names = length(local.carved_prefixes) == 0 ? [] : [
    for name in coalesce(one(data.azurerm_virtual_network.byo_vnet[*].subnets), []) : name
    if !contains(local.terraform_subnet_names, lower(name))
  ]
  # IPv4 only: the bounds below are computed from dotted quads, and every
  # carved prefix is IPv4, so an IPv6 sibling cannot overlap one.
  byo_vnet_sibling_prefixes = flatten([
    for name, subnet in data.azurerm_subnet.byo_vnet_siblings : [
      for prefix in subnet.address_prefixes : { name = name, prefix = prefix } if can(cidrnetmask(prefix))
    ]
  ])

  # Terraform has no CIDR containment or overlap function, so reduce every range
  # to its numeric bounds and compare those. cidrhost(x, 0) is the network
  # address, and the last address is that plus the host count.
  measured_cidrs = distinct(concat(
    local.vnet_address_space,
    [for entry in local.carved_prefixes : entry.prefix],
    [for entry in local.byo_vnet_sibling_prefixes : entry.prefix],
    [local.aks_service_cidr],
    # A single address, measured as a /32 so the bounds below cover it too.
    ["${local.aks_dns_service_ip}/32"],
    # The overlay pod range and everything it must stay clear of.
    [var.aks_pod_cidr],
    local.aks_reserved_cidrs,
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

  # Two ranges overlap unless one ends before the other starts.
  sibling_subnet_overlaps = [
    for pair in setproduct(local.carved_prefixes, local.byo_vnet_sibling_prefixes) :
    "${pair[0].prefix} (${pair[0].name}) overlaps ${pair[1].prefix} (subnet ${pair[1].name})"
    if local.cidr_first[pair[0].prefix] <= local.cidr_last[pair[1].prefix] && local.cidr_last[pair[0].prefix] >= local.cidr_first[pair[1].prefix]
  ]

  # The ClusterIP range is the opposite case: it is not carved from the VNet and
  # must stay clear of it. Two ranges overlap unless one ends before the other
  # starts.
  service_cidr_overlaps_vnet = anytrue([
    for space in local.vnet_address_space :
    local.cidr_first[local.aks_service_cidr] <= local.cidr_last[space] &&
    local.cidr_last[local.aks_service_cidr] >= local.cidr_first[space]
  ])
  # Inside a VNet Terraform builds, the range may share the address space but
  # not a subnet: the default 10.0.64.0/20 is the gap the default subnet
  # prefixes leave in 10.0.0.0/17.
  service_cidr_subnet_overlaps = [
    for entry in local.carved_prefixes : "${entry.prefix} (${entry.name})"
    if local.cidr_first[local.aks_service_cidr] <= local.cidr_last[entry.prefix] && local.cidr_last[local.aks_service_cidr] >= local.cidr_first[entry.prefix]
  ]

  # AKS takes the CoreDNS address out of the service range and rejects one that
  # sits outside it. A /32 starts and ends at the same number, so its first
  # bound is the address.
  dns_service_ip_outside_service_cidr = (
    local.cidr_first["${local.aks_dns_service_ip}/32"] < local.cidr_first[local.aks_service_cidr] ||
    local.cidr_first["${local.aks_dns_service_ip}/32"] > local.cidr_last[local.aks_service_cidr]
  )

  # In overlay mode the pod range is private to the cluster but still routed on
  # every node, so it has to stay clear of the VNet, the ClusterIP range and the
  # ranges AKS reserves. Each neighbor is named so the message says which one.
  aks_pod_cidr_neighbors = local.aks_overlay ? merge(
    { for space in local.vnet_address_space : "the VNet address space ${space}" => space },
    { "aks_service_cidr ${local.aks_service_cidr}" = local.aks_service_cidr },
    { for range in local.aks_reserved_cidrs : "the AKS reserved range ${range}" => range },
  ) : {}
  aks_pod_cidr_conflicts = [
    for name, cidr in local.aks_pod_cidr_neighbors : name
    if local.cidr_first[var.aks_pod_cidr] <= local.cidr_last[cidr] && local.cidr_last[var.aks_pod_cidr] >= local.cidr_first[cidr]
  ]

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

# Catch an over-long name before the resource group exists, rather than as an
# Azure 400 partway through the apply. Key Vault binds first — hyphens kept,
# inside Storage's 24-char limit — so ~12 chars of name_prefix is the ceiling
# under unique_resource_names. AKS binds only once both 24-char names are
# overridden. VNet and the resource group never bind before those, so they are
# not checked.
#
# One list, checked by a single precondition on the resource group and on the
# existing-group read below, so the check runs whichever one is planned and
# everything placed in the group waits on it.
locals {
  name_length_errors = compact([
    length(replace(local.blob_name, "-", "")) >= 3 && length(replace(local.blob_name, "-", "")) <= 24 ? "" : "Storage account name '${replace(local.blob_name, "-", "")}' is ${length(replace(local.blob_name, "-", ""))} chars; Azure allows 3-24. Shorten var.name_prefix or set var.storage_account_name explicitly.",
    # Exempt when attaching: the name is the operator's already-created resource,
    # and the remedy below is a config variables.tf rejects once create_* is
    # false. An unset existing_* name fails on the module's own precondition.
    !var.create_keyvault || (length(local.keyvault_name) >= 3 && length(local.keyvault_name) <= 24) ? "" : "Key Vault name '${local.keyvault_name}' is ${length(local.keyvault_name)} chars; Azure allows 3-24. Shorten var.name_prefix or set var.keyvault_name explicitly.",
    length(local.postgres_name) <= 63 ? "" : "Postgres name '${local.postgres_name}' is ${length(local.postgres_name)} chars; Azure allows at most 63. Shorten var.name_prefix or set var.postgres_name explicitly.",
    length(local.redis_name) <= 60 ? "" : "Redis name '${local.redis_name}' is ${length(local.redis_name)} chars; Azure allows at most 60. Shorten var.name_prefix or set var.redis_name explicitly.",
    !var.create_cluster || length(local.aks_name) <= 63 ? "" : "AKS cluster name '${local.aks_name}' is ${length(local.aks_name)} chars; Azure allows at most 63. Shorten var.name_base or var.name_prefix, or set var.cluster_name explicitly.",
  ])
}

# The resource group that contains all LangSmith Azure resources.
# Deleting this resource group will delete EVERYTHING inside it.
resource "azurerm_resource_group" "resource_group" {
  count    = var.create_resource_group ? 1 : 0
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags

  lifecycle {
    precondition {
      condition     = length(local.name_length_errors) == 0
      error_message = join("\n", local.name_length_errors)
    }
  }
}

# Deployments applied before create_resource_group existed hold the group at the
# unindexed address.
moved {
  from = azurerm_resource_group.resource_group
  to   = azurerm_resource_group.resource_group[0]
}

# A group the customer's platform team created. Read only for its name and ID:
# its tags, locks, and policy assignments stay as its owner set them, and
# terraform destroy leaves it in place. Resources keep var.location, which Azure
# allows to differ from the group's own.
data "azurerm_resource_group" "existing" {
  count = var.create_resource_group ? 0 : 1
  name  = var.existing_resource_group_name

  lifecycle {
    precondition {
      condition     = length(local.name_length_errors) == 0
      error_message = join("\n", local.name_length_errors)
    }
  }
}

locals {
  # Read off the resource or the data source rather than local.resource_group_name,
  # so that everything placed in the group waits for it on a first apply.
  rg_name = var.create_resource_group ? azurerm_resource_group.resource_group[0].name : data.azurerm_resource_group.existing[0].name
  rg_id   = var.create_resource_group ? azurerm_resource_group.resource_group[0].id : data.azurerm_resource_group.existing[0].id

  # A pre-existing cluster lives in its own resource group, not the one this
  # module uses for Key Vault and Storage. existing_cluster_resource_group_name
  # is required when create_cluster = false, so this is never blank.
  aks_rg_name = var.create_cluster ? local.rg_name : var.existing_cluster_resource_group_name
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
  resource_group_name = local.rg_name

  create_vnet      = var.create_vnet
  existing_vnet_id = var.vnet_id
  address_space    = var.vnet_address_space

  # A subnet is skipped when the operator supplied one, or when the service it
  # serves runs in-cluster and needs no dedicated subnet.
  create_main_subnet     = local.create_aks_subnet
  create_postgres_subnet = local.create_postgres_subnet
  create_redis_subnet    = local.create_redis_subnet

  main_subnet_address_prefix     = var.aks_subnet_address_prefix
  postgres_subnet_address_prefix = var.postgres_subnet_address_prefix
  redis_subnet_address_prefix    = var.redis_subnet_address_prefix

  # The bastion and AGIC subnets below are carved only out of a VNet Terraform
  # owns. Under bring-your-own the operator supplies the subnet instead, and
  # local.*_subnet_id selects it.
  enable_bastion                = var.create_bastion && var.create_vnet
  bastion_subnet_address_prefix = var.bastion_subnet_address_prefix

  # AGIC subnet: provisioned only when ingress_controller = "agic"
  enable_agic                = var.ingress_controller == "agic" && var.create_vnet
  agic_subnet_address_prefix = var.agic_subnet_address_prefix

  enable_subnet_nsgs  = var.enable_subnet_nsgs
  aks_source_prefixes = local.aks_subnet_prefixes

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

# Reads each subnet already in a reused VNet for its address prefixes, so a
# carved prefix that collides with one fails at plan. The VNet read returns only
# subnet names.
data "azurerm_subnet" "byo_vnet_siblings" {
  for_each             = toset(local.byo_vnet_sibling_names)
  name                 = each.key
  virtual_network_name = local.byo_vnet_parts[8]
  resource_group_name  = local.byo_vnet_parts[4]
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

# azurerm_subnet does not expose delegations. Feeds the check below.
data "azapi_resource" "byo_agic_subnet_delegations" {
  count                  = local.byo_agic_subnet && var.ingress_controller == "agic" ? 1 : 0
  type                   = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  resource_id            = var.agic_subnet_id
  response_export_values = ["properties.delegations"]
}

# ── Cluster egress (aks_outbound_type) ───────────────────────────────────────
# userDefinedRouting sends node egress by the supplied subnet's route table and
# userAssignedNATGateway by the NAT gateway on it, and AKS needs either in place
# when it creates the cluster, by which time the identities, Key Vault and
# storage already exist. Both are therefore read here, at plan: the route table ID from the
# subnet read above, and the NAT gateway in its own block below. The route
# table's own routes are read too. AKS accepts a 0.0.0.0/0 route there only
# with next hop VirtualAppliance or VirtualNetworkGateway, and refuses any
# other (None, Internet, VnetLocal) with RouteTableInvalidNextHop (seen live
# for None, on a test cluster in eastus2), so such a route is refused here.
# No 0.0.0.0/0 route at all is only a warning: a default route learned over
# BGP from ExpressRoute or VPN never appears in the table.
# aks_network_owner_checks = false skips the read, for a deploying identity
# that may not read the route table; Azure still checks the next hop at create,
# but nothing replaces the two warnings below that read it.
locals {
  aks_outbound_custom   = var.aks_outbound_type != "loadBalancer"
  aks_subnet_route_tbl  = try(one(data.azurerm_subnet.byo_aks_subnet[*].route_table_id), null)
  aks_subnet_has_routes = local.aks_subnet_route_tbl != null && local.aks_subnet_route_tbl != ""
  # Resource group and name of the route table, null when the ID has another
  # shape, so a mocked read reaches the precondition rather than a bad index.
  aks_route_tbl_parts = local.aks_subnet_has_routes ? try(regex("(?i)^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft\\.Network/routeTables/([^/]+)$", local.aks_subnet_route_tbl), null) : null

  # The table's 0.0.0.0/0 routes, empty when it was not read, and the ones AKS
  # would refuse. A for over the zero-or-one tables, not an index: Terraform
  # 1.11 evaluates both sides of || and &&, so [0] would fail with no table.
  aks_udr_next_hops_allowed = ["virtualappliance", "virtualnetworkgateway"]
  aks_udr_default_routes = flatten([
    for t in data.azurerm_route_table.byo_aks_subnet : [for r in t.route : r if r.address_prefix == "0.0.0.0/0"]
  ])
  aks_udr_bad_default_routes = [
    for r in local.aks_udr_default_routes : r if !contains(local.aks_udr_next_hops_allowed, lower(coalesce(r.next_hop_type, "")))
  ]

  # Routes straight to the internet. When every one of them names a service tag
  # (AzureCloud, say) rather than an address range, the routes send only Azure's
  # own ranges out directly, and the AKS required FQDNs, several of which
  # resolve outside AzureCloud, depend on whatever sits behind the default route.
  aks_udr_internet_routes = flatten([
    for t in data.azurerm_route_table.byo_aks_subnet : [for r in t.route : r if lower(coalesce(r.next_hop_type, "")) == "internet"]
  ])
  aks_udr_service_tag_only_egress = length(local.aks_udr_internet_routes) > 0 && alltrue([
    for r in local.aks_udr_internet_routes : !can(cidrnetmask(r.address_prefix))
  ])

  # The live outbound type, null until the cluster exists or when the read
  # carries none; null never counts as a change.
  aks_outbound_live     = try(local.aks_live.outbound, null)
  aks_outbound_changing = local.aks_outbound_live != null && try(lower(local.aks_outbound_live), "") != lower(var.aks_outbound_type)
}

data "azurerm_route_table" "byo_aks_subnet" {
  count               = var.create_cluster && var.aks_network_owner_checks && var.aks_outbound_type == "userDefinedRouting" && local.aks_route_tbl_parts != null ? 1 : 0
  name                = local.aks_route_tbl_parts[1]
  resource_group_name = local.aks_route_tbl_parts[0]
}

resource "terraform_data" "aks_outbound_guard" {
  input = var.aks_outbound_type

  lifecycle {
    # An attached cluster's egress belongs to whoever built it.
    precondition {
      condition     = var.create_cluster || !local.aks_outbound_custom
      error_message = "aks_outbound_type = \"${var.aks_outbound_type}\" has no effect with create_cluster = false: an attached cluster keeps the outbound type it was built with. Remove the setting, or leave it at \"loadBalancer\"."
    }

    # The route table or NAT gateway belongs to the network's owner, on a subnet
    # they supply.
    precondition {
      condition     = !var.create_cluster || !local.aks_outbound_custom || local.byo_aks_subnet
      error_message = "aks_outbound_type = \"${var.aks_outbound_type}\" needs create_vnet = false and aks_subnet_id set to a subnet that already carries your ${var.aks_outbound_type == "userDefinedRouting" ? "route table" : "NAT gateway"}. A subnet this module creates or carves has none."
    }

    precondition {
      condition     = !var.create_cluster || var.aks_outbound_type != "userDefinedRouting" || !local.byo_aks_subnet || local.aks_subnet_has_routes
      error_message = "aks_outbound_type = \"userDefinedRouting\" but aks_subnet_id has no route table, which AKS requires on the subnet for this outbound type. Associate the route table that carries your egress route with the subnet: az network vnet subnet update --ids ${var.aks_subnet_id} --route-table <route-table-id>."
    }

    precondition {
      condition     = length(local.aks_udr_bad_default_routes) == 0
      error_message = "aks_outbound_type = \"userDefinedRouting\", and the route table on aks_subnet_id sends 0.0.0.0/0 to next hop ${join(", ", distinct([for r in local.aks_udr_bad_default_routes : coalesce(r.next_hop_type, "unset")]))}. AKS accepts a default route only to VirtualAppliance or VirtualNetworkGateway and refuses any other at create with RouteTableInvalidNextHop. Point the route at your firewall or appliance (VirtualAppliance with its private IP) or at the VPN or ExpressRoute gateway (VirtualNetworkGateway)."
    }

    # A change moves the egress IP and drops connections, so it is never a
    # side effect of a tfvars edit.
    precondition {
      condition     = !local.aks_outbound_changing || var.aks_allow_outbound_type_change
      error_message = "Changing aks_outbound_type from ${coalesce(local.aks_outbound_live, "unknown")} to ${var.aks_outbound_type} on a cluster that already exists. Azure applies it in place, but it moves the cluster's egress IP and drops existing connections. Revert the change to keep the cluster as it is, or set aks_allow_outbound_type_change = true once firewall rules and aks_authorized_ip_ranges allow the new egress IP."
    }
  }
}

# ── NAT gateway on the AKS subnet (aks_nat_gateway) ───────────────────────────
# Kept apart from the outbound guard above so either mode can change or go on
# its own. existing: the network owner attached a NAT gateway, and plan checks
# it is there. create: Terraform makes a Standard NAT gateway and public IP in
# the deployment group and associates them with the supplied subnet, which is
# the only change it makes to that subnet; route tables stay the owner's. A
# NAT gateway serves the routes whose next hop is Internet: Azure prefers a
# route to a virtual appliance or gateway over it, and it over the system
# default route (Microsoft, "What is Azure NAT Gateway?").
locals {
  aks_nat_wanted = var.aks_nat_gateway != "none"
  aks_nat_create = var.create_cluster && local.byo_aks_subnet && var.aks_nat_gateway == "create"

  # The NAT gateway the subnet carries now, null when none; read for both modes.
  aks_subnet_nat_id = try(data.azapi_resource.byo_aks_subnet_nat[0].output.properties.natGateway.id, null)

  aks_nat_gateway_name = "${local.name_base}-nat${local.name_suffix}"
  # A Standard NAT gateway lives in one zone or none. Pin it, and its public IP,
  # only when availability_zones names exactly one zone; otherwise Azure places
  # it (Microsoft: "By default, a Standard NAT gateway is placed in No zone").
  aks_nat_zones = length(var.availability_zones) == 1 ? var.availability_zones : null

  # True when the subnet's NAT gateway is the one this module creates. Compared
  # by resource group and name, both known at plan, so a first apply (no NAT
  # gateway yet) and later ones (ours) both pass.
  aks_subnet_nat_is_ours = local.aks_subnet_nat_id == null ? true : (
    lower(try(split("/", local.aks_subnet_nat_id)[4], "")) == lower(local.resource_group_name) &&
    lower(try(split("/", local.aks_subnet_nat_id)[8], "")) == lower(local.aks_nat_gateway_name)
  )
}

# azurerm_subnet does not expose the NAT gateway, so this goes through azapi.
data "azapi_resource" "byo_aks_subnet_nat" {
  count                  = var.create_cluster && local.byo_aks_subnet && local.aks_nat_wanted ? 1 : 0
  type                   = "Microsoft.Network/virtualNetworks/subnets@2023-11-01"
  resource_id            = var.aks_subnet_id
  response_export_values = ["properties.natGateway"]
}

resource "terraform_data" "aks_nat_gateway_guard" {
  input = var.aks_nat_gateway

  lifecycle {
    precondition {
      condition     = !local.aks_nat_wanted || var.create_cluster
      error_message = "aks_nat_gateway = \"${var.aks_nat_gateway}\" has no effect with create_cluster = false: an attached cluster keeps the egress it was built with. Leave it at \"none\"."
    }

    precondition {
      condition     = !local.aks_nat_wanted || !var.create_cluster || local.byo_aks_subnet
      error_message = "aks_nat_gateway = \"${var.aks_nat_gateway}\" needs create_vnet = false and aks_subnet_id set: the NAT gateway goes on a subnet you supply."
    }

    precondition {
      condition     = !local.aks_nat_wanted || contains(["userDefinedRouting", "userAssignedNATGateway"], var.aks_outbound_type)
      error_message = "aks_nat_gateway = \"${var.aks_nat_gateway}\" needs aks_outbound_type = \"userAssignedNATGateway\" or \"userDefinedRouting\". With \"loadBalancer\", the cluster's own outbound IP is the egress path."
    }

    precondition {
      condition     = var.aks_outbound_type != "userAssignedNATGateway" || local.aks_nat_wanted
      error_message = "aks_outbound_type = \"userAssignedNATGateway\" needs a NAT gateway on aks_subnet_id: set aks_nat_gateway = \"existing\" for one already attached, or \"create\" to have Terraform create and attach it."
    }

    precondition {
      condition     = var.aks_nat_gateway != "existing" || !var.create_cluster || !local.byo_aks_subnet || try(local.aks_subnet_nat_id != null && local.aks_subnet_nat_id != "", false)
      error_message = "aks_nat_gateway = \"existing\" but aks_subnet_id has no NAT gateway. Attach one first (az network vnet subnet update --ids ${var.aks_subnet_id} --nat-gateway <nat-gateway-id>), or set aks_nat_gateway = \"create\"."
    }

    precondition {
      condition     = var.aks_nat_gateway != "create" || local.aks_subnet_nat_is_ours
      error_message = "aks_nat_gateway = \"create\" but aks_subnet_id already has a NAT gateway (${coalesce(local.aks_subnet_nat_id, "unknown")}), and associating a new one would replace it. Set aks_nat_gateway = \"existing\" to use it."
    }
  }
}

resource "azurerm_public_ip" "aks_nat" {
  count               = local.aks_nat_create ? 1 : 0
  name                = "${local.aks_nat_gateway_name}-pip"
  location            = var.location
  resource_group_name = local.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.aks_nat_zones
  tags                = local.common_tags

  # Zones are creation-time on a public IP, so a change would replace it and
  # move the egress address. See check.aks_nat_gateway_zone_drift.
  lifecycle {
    ignore_changes = [zones]
  }
}

resource "azurerm_nat_gateway" "aks" {
  count                   = local.aks_nat_create ? 1 : 0
  name                    = local.aks_nat_gateway_name
  location                = var.location
  resource_group_name     = local.rg_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = var.aks_nat_gateway_idle_timeout_minutes
  zones                   = local.aks_nat_zones
  tags                    = local.common_tags

  # Zones are creation-time on a NAT gateway, and local.aks_nat_zones follows
  # availability_zones: ["1"] pins it, ["1","2","3"] leaves it unpinned. Without
  # this, widening availability_zones on a running deployment replaces the NAT
  # gateway and its public IP, which changes the egress address and cuts a
  # userAssignedNATGateway cluster's egress during the replace. The cluster
  # ignores the same edit to its node pool zones (modules/k8s-cluster), so the
  # NAT gateway does the same, and the check below reports the drift.
  lifecycle {
    ignore_changes = [zones]
  }

  depends_on = [terraform_data.aks_nat_gateway_guard]
}

# ignore_changes on zones makes an availability_zones edit a no-op for the NAT
# gateway and its public IP. Warn on every plan when the live zones differ from
# what availability_zones now asks for, so the discarded change isn't mistaken
# for an applied one. A check block, not a postcondition, for the same reason as
# check.aks_node_pool_zone_drift: report the drift, don't block unrelated work.
check "aks_nat_gateway_zone_drift" {
  assert {
    condition = length(azurerm_nat_gateway.aks) == 0 ? true : (
      toset(azurerm_nat_gateway.aks[0].zones == null ? [] : azurerm_nat_gateway.aks[0].zones) ==
      toset(local.aks_nat_zones == null ? [] : local.aks_nat_zones)
    )
    error_message = join("", [
      "The NAT gateway on the AKS subnet is in zones [",
      join(",", sort(tolist(length(azurerm_nat_gateway.aks) == 0 ? [] : (azurerm_nat_gateway.aks[0].zones == null ? [] : azurerm_nat_gateway.aks[0].zones)))),
      "] but availability_zones now asks for [",
      join(",", sort(local.aks_nat_zones == null ? [] : local.aks_nat_zones)),
      "] (a NAT gateway is pinned only when availability_zones names exactly one zone). ",
      "This module ignores zone changes on an existing NAT gateway and its public IP, because ",
      "changing them replaces both: the egress address changes, and the cluster loses egress ",
      "until the new one is attached. To make it take effect, revert availability_zones, or ",
      "drop zones from ignore_changes on azurerm_nat_gateway.aks and azurerm_public_ip.aks_nat ",
      "in main.tf and apply in a maintenance window, then update any firewall rule that names ",
      "the old address (output aks_nat_gateway_public_ip).",
    ])
  }
}

resource "azurerm_nat_gateway_public_ip_association" "aks" {
  count                = local.aks_nat_create ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.aks[0].id
  public_ip_address_id = azurerm_public_ip.aks_nat[0].id
}

# The one write to the supplied subnet. A standalone association rather than an
# azapi patch so destroy detaches the NAT gateway before deleting it. After the
# service-endpoint patch, so the two never write the subnet at once.
resource "azurerm_subnet_nat_gateway_association" "aks" {
  count          = local.aks_nat_create ? 1 : 0
  subnet_id      = var.aks_subnet_id
  nat_gateway_id = azurerm_nat_gateway.aks[0].id

  depends_on = [azapi_update_resource.byo_aks_subnet_endpoints, azurerm_nat_gateway_public_ip_association.aks]
}

# Only a warning, for the same reason as the default-route check: a firewall
# or proxy behind the gateway that does reach those FQDNs is invisible here.
check "aks_route_table_service_tag_egress" {
  assert {
    condition     = !local.aks_udr_service_tag_only_egress
    error_message = "aks_outbound_type = \"userDefinedRouting\", and the only routes on aks_subnet_id's route table that go straight to Internet name service tags (${join(", ", distinct([for r in local.aks_udr_internet_routes : r.address_prefix]))}). Several destinations AKS needs to bootstrap nodes resolve outside AzureCloud, among them packages.microsoft.com, mcr.microsoft.com, packages.aks.azure.com and acs-mirror.azureedge.net. If nothing behind the default route reaches them, AKS accepts the create and node bootstrap then fails with CSE exit status 99. See Microsoft's outbound network and FQDN rules for AKS."
  }
}

check "aks_route_table_default_route" {
  assert {
    condition     = length(data.azurerm_route_table.byo_aks_subnet) == 0 || length(local.aks_udr_default_routes) > 0
    error_message = "aks_outbound_type = \"userDefinedRouting\", and the route table on aks_subnet_id has no 0.0.0.0/0 route. That is expected when the default route is learned over BGP from ExpressRoute or VPN. Otherwise add one with next hop VirtualAppliance or VirtualNetworkGateway, which Microsoft's UDR page requires."
  }
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
      condition     = var.enable_smithdb || (!var.smithdb_ingestion_enabled && !var.smithdb_migration_enabled && !var.smithdb_query_enabled)
      error_message = "SmithDB integration gates require enable_smithdb = true."
    }

    precondition {
      condition     = var.smithdb_ingestion_enabled || (!var.smithdb_migration_enabled && !var.smithdb_query_enabled)
      error_message = "smithdb_migration_enabled and smithdb_query_enabled require smithdb_ingestion_enabled = true."
    }

    # Azure allows 0.25 MB/s of throughput per provisioned IOPS, so the two
    # variable ranges overlap on pairs Azure rejects: 3000 IOPS caps throughput
    # at 750 MB/s, while 1200 passes its own range check. Without this the disk
    # is refused when the CSI driver creates the PVC, well after a clean apply,
    # and the pod reports a provisioning failure naming neither variable.
    #
    # Checked here rather than on the variable because a validation block that
    # reads another variable cannot be evaluated while that variable is itself
    # invalid, which would hide the throughput range error whenever the IOPS
    # value is wrong too.
    precondition {
      condition     = var.smithdb_cache_disk_throughput_mbps <= var.smithdb_cache_disk_iops * 0.25
      error_message = "smithdb_cache_disk_throughput_mbps (${var.smithdb_cache_disk_throughput_mbps}) cannot exceed 0.25 MB/s per provisioned IOPS. Azure caps a Premium SSD v2 at 0.25 * smithdb_cache_disk_iops, which is ${var.smithdb_cache_disk_iops * 0.25} MB/s at the configured ${var.smithdb_cache_disk_iops} IOPS. Raise smithdb_cache_disk_iops or lower the throughput."
    }

    # SmithDB caches sit on Premium SSD v2, and in most regions that offer
    # availability zones a Premium SSD v2 disk only attaches to a zonal VM. An
    # empty availability_zones asks Azure to place the pool, which can leave the
    # nodes nonzonal and the cache PVCs unschedulable - a failure that appears
    # after a clean apply, as SmithDB pods pending on a disk attach error.
    # default_node_pool[0].zones also carries ignore_changes and applies at
    # creation, so recovering from it means rebuilding the pool rather than
    # editing a variable. Refuse at plan time instead.
    precondition {
      condition     = !var.enable_smithdb || length(var.availability_zones) > 0
      error_message = "enable_smithdb = true requires availability_zones to name at least one zone, for example [\"1\",\"2\",\"3\"]. SmithDB cache volumes use Premium SSD v2, which attaches only to zonal VMs in most regions that support availability zones, and AKS zones apply at creation only. A small set of regions does support nonzonal Premium SSD v2 - see https://learn.microsoft.com/en-us/azure/virtual-machines/disks-deploy-premium-v2#nonzonal-premium-ssd-v2-deployments - so on one of those, or on an attached cluster whose nodes are already zonal, set availability_zones to the zones those nodes use."
    }

    # A Private Endpoint removes the public listener that storage_allowed_ips
    # writes rules for, so the allowlist stops granting anything. Say so at plan
    # time rather than leaving an operator to believe a CI runner still reaches
    # the data plane.
    precondition {
      condition     = !var.storage_private_endpoint_enabled || length(var.storage_allowed_ips) == 0
      error_message = "storage_allowed_ips cannot be combined with storage_private_endpoint_enabled = true: the storage accounts have no public endpoint for those rules to apply to. Clear storage_allowed_ips and reach the blob data plane from inside the VNet, or leave the private endpoints off."
    }

    precondition {
      condition     = var.create_vnet || var.vnet_id != ""
      error_message = "vnet_id is required when create_vnet = false. Supply the VNet that LangSmith should deploy into."
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

    # AKS nodes, the delegated Postgres server, and the private endpoints all have
    # to sit in the VNet's region, and Azure refuses each one partway through the
    # apply, after the resources before it exist. The ternary guards the index,
    # since || does not short-circuit before Terraform 1.14. Azure accepts both
    # "East US" and "eastus" for the same region.
    precondition {
      condition = length(data.azurerm_virtual_network.byo_vnet) == 0 ? true : (
        lower(replace(data.azurerm_virtual_network.byo_vnet[0].location, " ", "")) == lower(replace(var.location, " ", ""))
      )
      error_message = "vnet_id is in ${try(data.azurerm_virtual_network.byo_vnet[0].location, "another region")}, and location is ${var.location}. The cluster, Postgres, and the private endpoints have to be in the VNet's region, so set location to ${try(data.azurerm_virtual_network.byo_vnet[0].location, "the VNet's region")}."
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

    # The AKS subnet is allowlisted by ID on the blob storage firewall
    # (hardcoded default-deny) and, unless the vault is on a private endpoint,
    # on the Key Vault firewall. Azure rejects a subnet rule whose subnet lacks
    # the matching service endpoint, and azurerm exposes no way to skip that
    # check, so each required endpoint is required regardless of
    # keyvault_default_action. Skipped when Terraform is the one adding them,
    # since checking first would fail the plan that would fix it.
    precondition {
      condition = local.manage_aks_subnet_endpoints || length(data.azurerm_subnet.byo_aks_subnet) == 0 ? true : alltrue([
        for endpoint in local.required_aks_service_endpoints :
        contains(data.azurerm_subnet.byo_aks_subnet[0].service_endpoints, endpoint)
      ])
      error_message = "The subnet given as aks_subnet_id must carry the ${join(" and ", local.required_aks_service_endpoints)} service endpoint${length(local.required_aks_service_endpoints) > 1 ? "s" : ""}. Without ${length(local.required_aks_service_endpoints) > 1 ? "them" : "it"} the firewall${length(local.required_aks_service_endpoints) > 1 ? "s" : ""} in front of ${var.keyvault_private_endpoint_enabled ? "blob storage" : "blob storage and Key Vault"} cannot allowlist the subnet, and LangSmith pods lose access. Add ${length(local.required_aks_service_endpoints) > 1 ? "both endpoints" : "the endpoint"} to the subnet, set manage_byo_subnet_service_endpoints = true to have Terraform add ${length(local.required_aks_service_endpoints) > 1 ? "them" : "it"}, or clear aks_subnet_id and let Terraform create a subnet."
    }

    # The Postgres and Redis NSGs admit aks_subnet_id alone, so pods on an
    # attached cluster's other node subnets would time out reaching both.
    precondition {
      condition     = !var.enable_subnet_nsgs || length(module.aks.node_subnet_ids) <= 1
      error_message = "enable_subnet_nsgs = true admits only aks_subnet_id to the Postgres and Redis subnets, and cluster '${local.aks_name}' runs node pools in ${length(module.aks.node_subnet_ids)} subnets: [${join(", ", module.aks.node_subnet_ids)}]. Set enable_subnet_nsgs = false and attach NSGs that admit every node subnet yourself."
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
          "The AKS subnet holds ${local.aks_usable_ips} usable addresses, short of the ${local.aks_required_ips} that Azure CNI needs for the configured node pools. ${local.aks_overlay ? "In overlay mode only nodes draw IPs from this subnet, one each, at (max_count + 1) per pool:" : "Nodes and pods both draw IPs from this subnet, at (max_count + 1) nodes x (max_pods + 1) addresses per pool:"}",
          "",
        ],
        local.aks_demand_rows,
        [
          "",
          local.aks_overlay ? "Undersized, the cluster still starts and the autoscaler stalls short of max_count later, once the subnet runs dry. Widen the subnet to a /${local.aks_smallest_prefix} or larger, the smallest prefix that holds ${local.aks_required_ips} plus the 5 addresses Azure reserves, or lower a pool's max_count. max_pods does not size the subnet in overlay mode." : "Undersized, the cluster still starts and the autoscaler stalls short of max_count later, once the subnet runs dry. Widen the subnet to a /${local.aks_smallest_prefix} or larger, the smallest prefix that holds ${local.aks_required_ips} plus the 5 addresses Azure reserves. ${var.create_cluster ? "Or lower the default pool: one off default_node_pool_max_count frees ${var.default_node_pool_max_pods + 1} addresses, and one off default_node_pool_max_pods frees ${var.default_node_pool_max_count + 1}." : "Or lower a pool's max_count in additional_node_pools."}",
        ]
      ))
    }

    # Two combinations the provider rejects at apply, checked here rather than
    # on the variables so that each variable's own enum error still shows when
    # the other variable is wrong too.
    precondition {
      condition     = local.aks_network_dataplane != "cilium" || local.aks_overlay
      error_message = "aks_network_dataplane = \"cilium\" requires aks_network_mode = \"overlay\". Azure CNI Powered by Cilium runs on overlay (or pod-subnet) IPAM, not on node-subnet mode."
    }

    precondition {
      condition     = var.aks_support_plan != "AKSLongTermSupport" || var.aks_sku_tier == "Premium"
      error_message = "aks_support_plan = \"AKSLongTermSupport\" requires aks_sku_tier = \"Premium\"."
    }

    # Azure refuses an overlay pod range that overlaps the VNet, the ClusterIP
    # range or its own reserved ranges, but only at cluster creation, after the
    # resource group, VNet, Key Vault and storage have already been applied.
    precondition {
      condition = length(local.aks_pod_cidr_conflicts) == 0
      error_message = join(" ", [
        "aks_pod_cidr (${var.aks_pod_cidr}) overlaps ${join(", ", local.aks_pod_cidr_conflicts)}.",
        "The overlay pod range is private to the cluster but is routed on every node, so it must not overlap the VNet address space, anything peered or on-premises, aks_service_cidr, or the ranges AKS reserves (${join(", ", local.aks_reserved_cidrs)}).",
        "Pick a range outside all of them; 10.244.0.0/16 is the AKS default and is only wrong when your VNet or a peer uses it.",
      ])
    }

    # Each node takes a /24 from the pod range, so a small range caps the node
    # count the same way a small subnet does in node-subnet mode: the cluster
    # starts, and the autoscaler stalls once the range is spent.
    precondition {
      condition = !local.aks_overlay || local.aks_node_total <= local.aks_pod_cidr_node_capacity
      error_message = join(" ", [
        "aks_pod_cidr (${var.aks_pod_cidr}) holds ${local.aks_pod_cidr_node_capacity} /24 blocks, one per node, but the configured pools can reach ${local.aks_node_total} nodes (max_count + 1 surge node per pool).",
        "Widen the range: a /${24 - ceil(log(local.aks_node_total, 2))} holds ${local.aks_node_total} nodes. Or lower a pool's max_count.",
      ])
    }

    # 10.0.64.0/20 only avoids the subnets Terraform carves by default. Inside
    # someone else's address space AKS can accept an overlapping ClusterIP range
    # and break later, so make the operator name one.
    precondition {
      condition     = var.create_vnet || var.aks_service_cidr != ""
      error_message = "aks_service_cidr is required when create_vnet = false. The 10.0.64.0/20 default only misses the subnets Terraform carves by default and can fall inside your VNet. AKS requires a ClusterIP range that nothing on or connected to your VNet uses, so set one outside your VNet's address space."
    }

    # Requiring aks_service_cidr does not make it correct, and a range picked out
    # of the VNet's own space is the mistake the requirement exists to prevent.
    # AKS accepts the overlap at cluster creation and the collision surfaces
    # later, so it is worth the read.
    precondition {
      condition     = length(data.azurerm_virtual_network.byo_vnet) == 0 || !local.service_cidr_overlaps_vnet
      error_message = "aks_service_cidr (${local.aks_service_cidr}) overlaps the address space of vnet_id (${join(", ", local.vnet_address_space)}). Kubernetes ClusterIPs are not carved from the VNet, and AKS requires a range nothing on or connected to it uses. This check only sees the VNet's own address space, so keep clear of peered and on-premises ranges too."
    }

    # A VNet Terraform builds is checked against its subnets instead, since the
    # default range sits inside the default address space. Moving a subnet
    # prefix onto 10.0.64.0/20 fails the cluster create partway through apply.
    # Under create_vnet = false the address-space check above already covers it.
    precondition {
      condition     = !var.create_vnet || length(local.service_cidr_subnet_overlaps) == 0
      error_message = "aks_service_cidr (${local.aks_service_cidr}) overlaps these subnet prefixes: ${join(", ", local.service_cidr_subnet_overlaps)}. AKS rejects a ClusterIP range that overlaps a subnet in its VNet. Move the subnet, or set aks_service_cidr to a range no subnet uses. Changing aks_service_cidr on an existing cluster rebuilds it."
    }

    # Left empty the address is derived from the range and is always inside it.
    # Set explicitly it is a second place the range is written down, and a change
    # to aks_service_cidr strands it — the pair is exactly what an operator edits
    # while working out a range their VNet does not already use. Azure rejects
    # the mismatch partway through apply, once the resource group and Key Vault
    # exist.
    precondition {
      condition     = !local.dns_service_ip_outside_service_cidr
      error_message = "aks_dns_service_ip (${local.aks_dns_service_ip}) is outside aks_service_cidr (${local.aks_service_cidr}). AKS takes the CoreDNS ClusterIP out of the service range. Leave aks_dns_service_ip empty to get ${cidrhost(local.aks_service_cidr, 10)}, the eleventh address, which is the Azure convention."
    }

    # The subnet prefix defaults sit inside the default 10.0.0.0/17, so they go
    # wrong on someone else's network and on a VNet built at a moved
    # vnet_address_space alike. Azure rejects an out-of-range prefix partway
    # through apply, once the resource group and Key Vault already exist.
    precondition {
      condition     = length(local.vnet_address_space) == 0 || length(local.uncontained_prefixes) == 0
      error_message = "These subnet prefixes fall outside the address space of ${local.vnet_address_space_source} (${join(", ", local.vnet_address_space)}): ${join(", ", local.uncontained_prefixes)}. Point each at a free range inside that space${var.create_vnet ? "" : ", or supply that subnet's ID to reuse a subnet that already exists"}."
    }

    # Containment is not enough in a reused VNet: the free-looking range can
    # already belong to someone else's subnet, and Azure rejects the overlap
    # partway through apply.
    precondition {
      condition     = length(local.sibling_subnet_overlaps) == 0
      error_message = "These subnet prefixes collide with subnets already in vnet_id: ${join("; ", local.sibling_subnet_overlaps)}. Point each at a range no existing subnet uses, or supply the existing subnet's ID to reuse it."
    }
  }
}

# A supplied subnet belongs to the operator, so report rather than fix. A check
# and not a precondition, because a gateway created before Azure applied network
# isolation keeps running undelegated and is never revalidated.
check "agic_subnet_delegation" {
  assert {
    condition = length(data.azapi_resource.byo_agic_subnet_delegations) == 0 || contains([
      for d in try(data.azapi_resource.byo_agic_subnet_delegations[0].output.properties.delegations, []) :
      try(d.properties.serviceName, "")
    ], "Microsoft.Network/applicationGateways")
    error_message = "The subnet given as agic_subnet_id is not delegated to Microsoft.Network/applicationGateways. Creating an Application Gateway there fails with ApplicationGatewayNetworkIsolationRequiresSubnetDelegation, partway through the apply. Have the subnet's owner add the delegation (action Microsoft.Network/virtualNetworks/subnets/join/action) before applying: `az network vnet subnet update --ids ${var.agic_subnet_id} --delegations Microsoft.Network/applicationGateways`. Ignore this if the gateway already exists and runs — an existing one is not revalidated."
  }
}

# Microsoft supports AGIC on Azure CNI Overlay (AGIC 1.9.1 or later, a
# delegated subnet of /24 or smaller, both of which this module provides) except
# in Azure Government and Azure China, where the pairing is unsupported. Nothing
# here has exercised it: the test cluster does not run agic. A check rather than a
# precondition, so the plan says so and proceeds; once the module knows which
# cloud it deploys to, the Government case becomes a precondition.
check "agic_with_overlay_unverified" {
  assert {
    condition     = !(var.ingress_controller == "agic" && local.aks_overlay)
    error_message = "ingress_controller = \"agic\" with aks_network_mode = \"overlay\": Microsoft supports the pairing (AGIC 1.9.1 or later, a delegated /24 subnet, as here) except in Azure Government and Azure China, where it is unsupported and the WAF path is Application Gateway in front of an internal load balancer instead. This module has not exercised AGIC on overlay; confirm ingress on this cluster before relying on it, or use envoy-gateway, the default."
  }
}

# The Envoy Gateway controller picks the proxy image itself, so mirroring it
# needs that default for each chart version. envoy_gateway_image_registry
# refuses a version missing from this map.
locals {
  envoy_proxy_default_images = {
    "v1.2.0" = "envoyproxy/envoy:distroless-v1.32.1"
  }
}

# ── Kubernetes Cluster ────────────────────────────────────────────────────────
# AKS cluster with OIDC + Workload Identity enabled, ingress controller installed.
# The OIDC issuer URL output is consumed by module.blob for federated credentials.

module "aks" {
  source              = "./modules/k8s-cluster"
  cluster_name        = local.aks_name
  location            = var.location
  resource_group_name = local.rg_name
  subnet_id           = local.aks_subnet_id
  service_cidr        = local.aks_service_cidr   # K8s ClusterIP range (must not overlap VNet)
  dns_service_ip      = local.aks_dns_service_ip # CoreDNS IP (derived from service_cidr)
  kubernetes_version  = var.aks_kubernetes_version

  # Bring-your-own cluster: read an existing AKS cluster instead of creating one.
  create_cluster = var.create_cluster
  create_vnet    = var.create_vnet
  kube_auth      = var.aks_kube_auth

  # Both of these are passed straight from variables, never derived from another
  # resource. azurerm_resource_group.resource_group[0] is pending creation on a first
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
  default_node_pool_os_sku    = var.aks_os_sku

  # Network mode, data plane and tier, derived above from the operator-facing
  # variables. The tier and support plan update in place. The mode, the pod
  # range and the data plane are fixed at creation, short of the two one-way
  # updates Azure runs in place (the Azure data plane to Cilium; a policy engine
  # installed where none runs): the provider applies every other change by
  # replacing the cluster, so terraform_data.aks_network_guard below compares
  # these with the profile the cluster runs and refuses a change not asked for.
  network_plugin_mode = local.aks_network_plugin_mode
  pod_cidr            = local.aks_pod_cidr
  network_data_plane  = local.aks_network_dataplane
  network_policy      = local.aks_network_policy
  outbound_type       = var.aks_outbound_type
  # A NAT gateway Terraform creates is on the subnet before the cluster is.
  egress_dependencies = azurerm_subnet_nat_gateway_association.aks[*].id
  sku_tier            = var.aks_sku_tier
  support_plan        = var.aks_support_plan

  # Additional pools (e.g. "large" for ClickHouse / memory-heavy workloads).
  additional_node_pools = local.aks_managed_node_pools

  # Ingress controller: 'envoy-gateway' (Helm, default), 'nginx' (Helm), 'istio' (Helm), 'istio-addon' (Azure managed), 'agic', 'none'
  ingress_controller = var.ingress_controller
  dns_label          = var.dns_label

  ingress_load_balancer                          = var.ingress_load_balancer
  ingress_load_balancer_subnet_id                = var.ingress_load_balancer_subnet_id
  ingress_load_balancer_ip                       = var.ingress_load_balancer_ip
  ingress_load_balancer_manage_subnet_assignment = var.ingress_load_balancer_manage_subnet_assignment
  # A ternary rather than &&, which below Terraform 1.14 evaluates both sides.
  # A supplied node subnet is compared by ID. A carved one has no ID before
  # apply, so it is compared by name: the load-balancer subnet is in the
  # cluster's VNet, where the name alone identifies it.
  ingress_load_balancer_needs_subnet_grant = var.ingress_load_balancer == "internal" && var.ingress_load_balancer_subnet_id != "" ? (
    local.byo_aks_subnet
    ? lower(var.ingress_load_balancer_subnet_id) != lower(var.aks_subnet_id)
    : lower(element(split("/", var.ingress_load_balancer_subnet_id), length(split("/", var.ingress_load_balancer_subnet_id)) - 1)) != lower("${local.vnet_name}-subnet-0")
  ) : false
  istio_version        = var.istio_version
  istio_addon_revision = var.istio_addon_revision

  # AGIC — wired from vnet module output
  subscription_id = var.subscription_id
  agic_subnet_id  = local.agic_subnet_id

  # A WAF policy can only be associated with the WAF_v2 tier, so create_waf
  # decides the tier rather than leaving the two to be set into a combination
  # that fails at apply. The dependency runs both ways: WAF_v2 is equally
  # invalid without a policy, so agw_sku_tier = "WAF_v2" on its own is rejected
  # by a precondition on the gateway rather than silently downgraded.
  agw_sku_tier       = var.create_waf ? "WAF_v2" : var.agw_sku_tier
  firewall_policy_id = one(module.waf[*].waf_policy_id)

  agic_network_contributor_scope = var.agic_network_contributor_scope

  # Envoy Gateway
  envoy_gateway_version                = var.envoy_gateway_version
  envoy_gateway_image_registry         = var.envoy_gateway_image_registry
  envoy_proxy_default_image            = lookup(local.envoy_proxy_default_images, var.envoy_gateway_version, "")
  envoy_gateway_image_pull_secret_name = var.envoy_gateway_image_pull_secret_name

  langsmith_namespace = var.langsmith_namespace
  # The chart names its service accounts after its fullname, which is the release
  # name only when it contains "langsmith" (prod -> prod-langsmith-backend), so the
  # federated credential subjects are built from the fullname.
  langsmith_release_name = local.langsmith_release_fullname

  # Preserve existing identity name when migrating from storage module.
  # New deployments leave this unset and get "${cluster_name}-app-identity".
  workload_identity_name = "k8s-app-identity"

  availability_zones = var.availability_zones

  # API server access — empty list keeps the master publicly reachable for
  # Terraform-driven Helm/kubectl steps. Populate var.aks_authorized_ip_ranges
  # in terraform.tfvars to restrict to operator/CI CIDRs.
  authorized_ip_ranges = var.aks_authorized_ip_ranges

  # Private API server, Entra-only access, and the control-plane identity, all
  # off by default.
  private_cluster_enabled      = var.aks_private_cluster_enabled
  private_dns_zone_id          = var.aks_private_dns_zone_id
  entra_only                   = var.aks_entra_only
  entra_admin_group_object_ids = var.aks_entra_admin_group_object_ids
  control_plane_identity       = var.aks_control_plane_identity
  control_plane_identity_id    = var.aks_control_plane_identity_id

  control_plane_identity_manage_grants = local.aks_control_plane_manage_grants
  control_plane_grant_check            = var.aks_network_owner_checks
  vnet_id                              = local.vnet_id
  subnet_route_table_id                = local.aks_subnet_has_routes ? local.aks_subnet_route_tbl : ""

  tags = local.common_tags
}

# ── AKS network guard ─────────────────────────────────────────────────────────
# The network_profile of an existing cluster changes in one of three ways. Azure
# applies two updates in place, each reimaging every node pool: the Azure data
# plane to Cilium, and installing a policy engine where none runs. Azure's
# migration from node-subnet to overlay is in place too, but only on a cluster
# with no policy engine, and this module sets network_policy on every cluster it
# creates, so through Terraform the migration and the engine's install would be
# one apply, which Microsoft does not support; it is refused outright. Every
# other change (overlay back to node-subnet, Cilium back to Azure, a policy
# engine swapped or removed, a new pod range) is applied by the provider as a
# replacement of the cluster and everything installed on it. Any of them would
# follow from a one-line tfvars edit, so the requested profile is compared with
# the one Azure reports for the cluster (module.aks reads it at plan time; null
# until the cluster exists). A change is refused unless aks_allow_network_upgrade
# is set, and then only the two in-place updates pass. The read depends on
# variables alone, so every condition here is known at plan and a failure stops
# the plan before anything is applied. Provider rules from azurerm's
# ForceNewIfChange (main, read 2026-09-25): network_policy changes in place from
# none and from azure or calico to cilium; network_data_plane from azure to
# cilium; network_plugin_mode only towards overlay. Those in-place paths exist
# from azurerm 4.58.0 (to cilium) and 4.59.0 (calico to cilium), both below the
# 4.65.0 floor in versions.tf.
locals {
  aks_live = var.create_cluster ? module.aks.live_network_profile : null

  aks_mode_changing      = local.aks_live != null && try(local.aks_live.mode, null) != var.aks_network_mode
  aks_dataplane_changing = local.aks_live != null && try(local.aks_live.dataplane, null) != local.aks_network_dataplane
  aks_policy_changing    = local.aks_live != null && try(local.aks_live.policy, null) != local.aks_network_policy
  # Only a range change within overlay mode counts: a cluster entering overlay
  # gets its range for the first time.
  aks_pod_cidr_changing = local.aks_live != null && try(local.aks_live.mode, null) == "overlay" && local.aks_overlay && try(local.aks_live.pod_cidr, null) != null && try(local.aks_live.pod_cidr, null) != var.aks_pod_cidr

  # What changed, named for the message; empty when nothing did.
  aks_network_changes = compact([
    local.aks_mode_changing ? "aks_network_mode ${coalesce(try(local.aks_live.mode, null), "unknown")} to ${var.aks_network_mode}" : "",
    local.aks_dataplane_changing ? "aks_network_dataplane ${coalesce(try(local.aks_live.dataplane, null), "unknown")} to ${local.aks_network_dataplane}" : "",
    local.aks_policy_changing ? "the network policy engine ${coalesce(try(local.aks_live.policy, null), "unknown")} to ${local.aks_network_policy}" : "",
    local.aks_pod_cidr_changing ? "aks_pod_cidr ${coalesce(try(local.aks_live.pod_cidr, null), "unknown")} to ${var.aks_pod_cidr}" : "",
  ])

  # The two updates Azure and the provider apply in place.
  aks_dataplane_upgrade = try(local.aks_live.dataplane, null) == "azure" && local.aks_network_dataplane == "cilium"
  aks_policy_upgrade    = try(local.aks_live.policy, null) == "none" || (contains(["azure", "calico"], try(local.aks_live.policy, "")) && local.aks_network_policy == "cilium")
}

resource "terraform_data" "aks_network_guard" {
  input = {
    mode      = var.aks_network_mode
    dataplane = local.aks_network_dataplane
    policy    = local.aks_network_policy
    pod_cidr  = local.aks_pod_cidr
  }

  lifecycle {
    # Any change to an existing cluster's network profile is refused until asked for.
    precondition {
      condition = length(local.aks_network_changes) == 0 || var.aks_allow_network_upgrade
      error_message = join(" ", compact([
        "Changing ${join(", ", local.aks_network_changes)} on a cluster that already exists.",
        var.aks_network_dataplane == "" && local.aks_dataplane_changing ? "The data plane value is the default for aks_network_mode = \"${var.aks_network_mode}\"; set aks_network_dataplane = \"${coalesce(try(local.aks_live.dataplane, null), "azure")}\" explicitly to keep the cluster as it is." : "",
        "Revert the change to keep the cluster as it is. Azure applies two updates in place, each reimaging every node pool: the azure data plane to cilium, and installing a network policy engine where none runs; set aks_allow_network_upgrade = true to run one of those deliberately. Every other change either replaces the cluster and everything installed on it, or is a migration this module cannot express; for those, build a new cluster.",
      ]))
    }

    # With the flag, the mode still never migrates through this module.
    precondition {
      condition = !(local.aks_mode_changing && var.aks_allow_network_upgrade)
      error_message = join(" ", [
        "aks_network_mode is changing from ${coalesce(try(local.aks_live.mode, null), "unknown")} to ${var.aks_network_mode}, which aks_allow_network_upgrade does not permit.",
        "Azure migrates node-subnet to overlay only on a cluster with no network policy engine, and this module sets one on every cluster it creates, so through Terraform the migration and the engine's install would be one apply, which Microsoft does not support. Overlay back to node-subnet has no migration at all; the provider would replace the cluster.",
        "Build a new cluster in the mode you want and move the release to it.",
      ])
    }

    # With the flag, the data plane moves only from azure to cilium.
    precondition {
      condition = !(local.aks_dataplane_changing && var.aks_allow_network_upgrade) || local.aks_dataplane_upgrade
      error_message = join(" ", [
        "aks_network_dataplane is changing from ${coalesce(try(local.aks_live.dataplane, null), "unknown")} to ${local.aks_network_dataplane}, and Azure has no update in that direction: the provider would replace the cluster, and everything installed on it, on apply.",
        "aks_allow_network_upgrade does not permit this. Revert aks_network_dataplane, or build a new cluster with the data plane you want.",
      ])
    }

    # With the flag, a policy engine is installed where none runs, or azure or
    # calico moves to cilium alongside the data plane. Anything else replaces.
    precondition {
      condition = !(local.aks_policy_changing && var.aks_allow_network_upgrade) || local.aks_policy_upgrade
      error_message = join(" ", [
        "The network policy engine is changing from ${coalesce(try(local.aks_live.policy, null), "unknown")} to ${local.aks_network_policy}, and the provider applies that by replacing the cluster: it changes the engine in place only where none runs, or from azure or calico to cilium.",
        "aks_allow_network_upgrade does not permit this. Revert the change (the engine follows aks_network_dataplane), or build a new cluster.",
      ])
    }

    # The pod range never changes in place.
    precondition {
      condition = !local.aks_pod_cidr_changing
      error_message = join(" ", [
        "aks_pod_cidr is changing from ${coalesce(try(local.aks_live.pod_cidr, null), "unknown")} to ${var.aks_pod_cidr} on a cluster that already runs overlay mode.",
        "Azure does not change a cluster's pod range, so the provider would replace the cluster, and everything installed on it, on apply. Revert aks_pod_cidr, or build a new cluster with the range you want.",
      ])
    }
  }
}

# ── AKS access guard ──────────────────────────────────────────────────────────
# Whether the API server is private, and its private DNS zone, are fixed when a
# cluster is created: the provider applies a change to either by replacing the
# cluster and everything installed on it. Entra integration goes one way: Azure
# turns it on in place and refuses to turn it off. Each follows from a one-line
# tfvars edit, so the requested access is compared with what Azure reports for
# the cluster (module.aks reads it at plan time; null until the cluster exists)
# and a change is refused with no override. The control-plane identity is
# refused the same way, though Azure swaps it in place: the grants the old
# identity holds on the network do not follow the control plane to the new one.
# The read depends on variables alone, so a failure stops the plan before
# anything is applied. Who owns that identity and its grants is not something
# Azure reports, so terraform_data.aks_grants_pin keeps the setting the cluster
# was created with, and a change to it is refused until it is made on purpose.
locals {
  aks_live_access = var.create_cluster ? module.aks.live_access_profile : null

  # Azure reports the zone as "system", "none", or the zone ID; compare the
  # requested one in that form.
  aks_private_dns_zone = var.aks_private_dns_zone_id == "" ? "system" : lower(var.aks_private_dns_zone_id)

  aks_private_changing  = local.aks_live_access != null && try(local.aks_live_access.private, null) != var.aks_private_cluster_enabled
  aks_dns_zone_changing = local.aks_live_access != null && try(local.aks_live_access.private, null) == true && var.aks_private_cluster_enabled && lower(coalesce(try(local.aks_live_access.private_dns_zone, null), "system")) != local.aks_private_dns_zone
  aks_entra_removing    = local.aks_live_access != null && try(local.aks_live_access.entra, null) == true && !var.aks_entra_only

  # Azure reports the identity type and the user-assigned IDs; a cluster that
  # reports no identity is skipped. ?: rather than && and ||, which evaluate
  # both sides before Terraform 1.14 and would lower() a system identity's null
  # ID.
  aks_identity          = var.create_cluster ? module.aks.control_plane_identity : null
  aks_live_identity     = try(local.aks_live_access.identity, null)
  aks_identity_changing = local.aks_live_identity == null || local.aks_identity == null ? false : local.aks_live_identity != local.aks_identity.type ? true : local.aks_identity.type == "user" ? !contains(try(local.aks_live_access.identity_ids, []), lower(local.aks_identity.id)) : false

  # A network the module built is the module's to grant on; a supplied one is
  # its owner's, unless asked otherwise.
  aks_control_plane_manage_grants = coalesce(var.aks_control_plane_identity_manage_grants, var.create_vnet)

  # Whether the module creates the user-assigned identity and makes its grants.
  # Changing either on a live cluster deletes, with a clean plan, the identity or
  # the grants the cluster still runs on, or creates grants the owner already
  # made. Skipped while the identity itself is changing, which the identity
  # check already refuses.
  aks_grants_mode = var.create_cluster && var.aks_control_plane_identity == "user" ? {
    create_identity = var.aks_control_plane_identity_id == ""
    manage_grants   = local.aks_control_plane_manage_grants
  } : null
  aks_grants_pinned   = try(one(terraform_data.aks_grants_pin[*].output).mode, local.aks_grants_mode)
  aks_grants_changing = local.aks_live_access == null || local.aks_identity_changing ? false : local.aks_grants_pinned != local.aks_grants_mode
}

# The setting the cluster was created with. The cluster's ID holds the write
# back until the cluster exists, so a failed first apply does not pin a setting
# no cluster has; ignore_changes keeps it after that, and -replace records a new
# one.
resource "terraform_data" "aks_grants_pin" {
  count = var.create_cluster ? 1 : 0
  input = {
    cluster_id = module.aks.cluster_id
    mode       = local.aks_grants_mode
  }

  lifecycle {
    ignore_changes = [input]
  }
}

resource "terraform_data" "aks_access_guard" {
  input = {
    private          = var.aks_private_cluster_enabled
    private_dns_zone = local.aks_private_dns_zone
    entra_only       = var.aks_entra_only
    identity         = local.aks_identity
  }

  lifecycle {
    precondition {
      condition = !local.aks_private_changing
      error_message = join(" ", [
        "aks_private_cluster_enabled is changing to ${var.aks_private_cluster_enabled} on a cluster that already exists.",
        "Azure does not change whether an API server is private, so the provider would replace the cluster, and everything installed on it, on apply. Revert aks_private_cluster_enabled, or build a new cluster with the access you want.",
      ])
    }

    precondition {
      condition = !local.aks_dns_zone_changing
      error_message = join(" ", [
        "aks_private_dns_zone_id is changing from ${coalesce(try(local.aks_live_access.private_dns_zone, null), "system")} to ${local.aks_private_dns_zone} on a cluster that already exists.",
        "Azure does not move a private API server to another zone, so the provider would replace the cluster, and everything installed on it, on apply. Revert aks_private_dns_zone_id, or build a new cluster with the zone you want.",
      ])
    }

    precondition {
      condition = !local.aks_entra_removing
      error_message = join(" ", [
        "aks_entra_only is false, but the cluster already has Entra integration, and Azure cannot turn it off.",
        "Set aks_entra_only = true to keep the cluster as it is.",
      ])
    }

    precondition {
      condition = !local.aks_identity_changing
      error_message = join(" ", [
        "The control-plane identity is changing on a cluster that already exists: Azure reports ${coalesce(local.aks_live_identity, "unknown")}${length(try(local.aks_live_access.identity_ids, [])) > 0 ? " (${join(", ", local.aks_live_access.identity_ids)})" : ""}, and the configuration asks for ${try(local.aks_identity.type, "unknown")}${try(local.aks_identity.id, null) != null ? " (${local.aks_identity.id})" : ""}.",
        "The grants the current identity holds on the network and the private DNS zone do not follow the control plane to a new one. Revert aks_control_plane_identity and aks_control_plane_identity_id, or build a new cluster with the identity you want.",
      ])
    }

    precondition {
      condition = !local.aks_grants_changing
      error_message = join(" ", [
        "The cluster was created with ${try(local.aks_grants_pinned.create_identity, false) ? "an identity the module created" : "a supplied identity"} and ${try(local.aks_grants_pinned.manage_grants, false) ? "grants the module made" : "grants left to the network's owner"}.",
        "The configuration now asks for ${try(local.aks_grants_mode.create_identity, false) ? "an identity the module creates" : "a supplied identity"} and ${try(local.aks_grants_mode.manage_grants, false) ? "grants the module makes" : "grants left to the network's owner"}.",
        "On apply, Terraform would delete the identity or the grants the cluster runs on, or create grants that already exist.",
        "Revert aks_control_plane_identity_id and aks_control_plane_identity_manage_grants. To hand them over on purpose, first move them in state.",
        "To leave them to the owner, run terraform state rm on module.aks.azurerm_role_assignment.control_plane_network_contributor[0] and module.aks.azurerm_role_assignment.control_plane_dns_zone_contributor[0], and on module.aks.azurerm_user_assigned_identity.control_plane[0] when supplying the identity the module created.",
        "To take them over, run terraform import on the owner's assignments at the same addresses.",
        "Then apply with -replace='terraform_data.aks_grants_pin[0]' to record the new setting.",
      ])
    }
  }
}

# ── Storage redundancy guard ──────────────────────────────────────────────────
# Azure converts an account between locally and zone-redundant replication in
# place, with no downtime, but the azurerm provider cannot: it applies any change
# between LRS/GRS/RAGRS and ZRS/GZRS/RAGZRS by deleting the account and creating
# it again, and the trace-blob account holds every trace payload. So the
# requested replication is compared with the SKU Azure reports for each account
# (listed at subscription scope, empty until the account exists), and a change
# across that boundary is refused. The way through is Azure's conversion, after
# which the live SKU matches the variable and the plan is clean. Changes within
# a group (LRS to GRS, ZRS to GZRS) update in place and pass. Provider rule from
# the azurerm 4.81.0 storage_account docs, account_replication_type.
locals {
  blob_account_name = replace(local.blob_name, "-", "")

  storage_guarded_accounts = merge(
    { (local.blob_account_name) = { variable = "storage_replication_type", requested = var.storage_replication_type } },
    var.enable_smithdb ? { (local.smithdb_storage_name) = { variable = "smithdb_storage_replication_type", requested = var.smithdb_storage_replication_type } } : {},
  )

  # try() covers a mocked provider, whose output has no such shape.
  storage_live_skus = {
    for a in try(data.azapi_resource_list.storage_accounts.output.accounts, []) :
    lower(a.name) => replace(a.sku, "Standard_", "")
    if lower(split("/", a.id)[4]) == lower(local.resource_group_name)
  }

  # An account Azure does not have yet reads as its requested value, so it never
  # counts as a change. lookup() rather than an index guarded by &&: Terraform
  # before 1.12 evaluates both operands, and versions.tf allows 1.11.
  # One instruction per account, built from the live SKU, so the message names the
  # account and the value to set rather than placeholders. Setting the variable to
  # what Azure reports is right in both cases this fires: after a conversion made
  # outside Terraform (the variable is behind), and before one (convert first).
  # Azure's conversion changes only the zone part of the replication and keeps
  # the geo part (LRS<->ZRS, GRS<->GZRS, RAGRS<->RAGZRS). A target that also
  # changes the geo part, such as LRS to GZRS, is two steps: the conversion, then
  # an in-place change within the new group, which Azure allows 24 hours after a
  # conversion. The message names the conversion step and, when needed, the second.
  storage_zone_flip = { LRS = "ZRS", ZRS = "LRS", GRS = "GZRS", GZRS = "GRS", RAGRS = "RAGZRS", RAGZRS = "RAGRS" }

  storage_zone_changes = [
    for name, want in local.storage_guarded_accounts :
    join(" ", compact([
      "${name}: ${want.variable} is \"${want.requested}\" here and Azure reports \"${lookup(local.storage_live_skus, lower(name), want.requested)}\".",
      "Set ${want.variable} = \"${lookup(local.storage_live_skus, lower(name), want.requested)}\" to match it now.",
      "To convert the account, run az storage account migration start --account-name ${name} --resource-group ${local.resource_group_name} --sku Standard_${lookup(local.storage_zone_flip, lookup(local.storage_live_skus, lower(name), want.requested), want.requested)} --no-wait, and set ${want.variable} = \"${lookup(local.storage_zone_flip, lookup(local.storage_live_skus, lower(name), want.requested), want.requested)}\" once az storage account migration show --account-name ${name} --resource-group ${local.resource_group_name} --name default reads Completed.",
      lookup(local.storage_zone_flip, lookup(local.storage_live_skus, lower(name), want.requested), want.requested) == want.requested ? "" : "Azure converts only the zone part, so ${want.requested} is a second step: at least 24 hours after the conversion, set ${want.variable} = \"${want.requested}\", which updates the account in place.",
    ]))
    if contains(["ZRS", "GZRS", "RAGZRS"], lookup(local.storage_live_skus, lower(name), want.requested)) != contains(["ZRS", "GZRS", "RAGZRS"], want.requested)
  ]
}

data "azapi_resource_list" "storage_accounts" {
  type      = "Microsoft.Storage/storageAccounts@2023-05-01"
  parent_id = "/subscriptions/${var.subscription_id}"
  response_export_values = {
    accounts = "value[?${join(" || ", [for name in keys(local.storage_guarded_accounts) : "name=='${name}'"])}].{id: id, name: name, sku: sku.name}"
  }
}

resource "terraform_data" "storage_replication_guard" {
  input = { for name, want in local.storage_guarded_accounts : name => want.requested }

  lifecycle {
    precondition {
      condition = length(local.storage_zone_changes) == 0
      error_message = join(" ", concat(
        ["This plan adds or removes zone redundancy on a storage account that already exists. The azurerm provider would apply that by deleting the account, and every blob in it, and creating it again; Azure converts it in place instead."],
        local.storage_zone_changes,
        ["See README \"Storage redundancy\"."],
      ))
    }
  }
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
  resource_group_name = local.rg_name
  vnet_id             = local.vnet_id # needed to link the private DNS zone
  subnet_id           = local.postgres_subnet_id

  private_dns_zone_name = local.azure_cloud.postgres_private_dns_zone
  # A supplied central zone replaces the zone and VNet link the module creates.
  private_dns_zone_id = local.postgres_private_dns_zone_supplied ? var.postgres_private_dns_zone_id : null

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
  database_name  = var.postgres_database_name
  sku_name       = var.postgres_sku_name

  postgres_version      = var.postgres_version
  storage_mb            = var.postgres_storage_mb
  storage_tier          = var.postgres_storage_tier
  backup_retention_days = var.postgres_backup_retention_days

  # availability_zones = [] means "let Azure place this", which is the only way
  # to deploy a VM or database SKU that is not offered in every zone of the
  # region. Indexing an empty list is an error, so this is a ternary rather than
  # a length() guard joined with &&, which evaluates both sides below Terraform
  # 1.14 and would error on the very input it is meant to handle.
  availability_zone            = length(var.availability_zones) > 0 ? var.availability_zones[0] : ""
  high_availability            = var.postgres_high_availability
  standby_availability_zone    = var.postgres_standby_availability_zone
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup

  # Create the dedicated langsmith_fleet database when standalone Fleet is enabled.
  enable_fleet = var.enable_fleet

  tags = local.common_tags
}

# ── SmithDB infrastructure (optional) ────────────────────────────────────────

module "smithdb" {
  source = "./modules/smithdb"
  count  = var.enable_smithdb ? 1 : 0

  name                = local.smithdb_name
  location            = var.location
  resource_group_name = local.rg_name
  vnet_id             = local.vnet_id

  private_dns_zone_name = local.azure_cloud.postgres_private_dns_zone
  subnet_id             = local.postgres_subnet_id
  aks_subnet_id         = local.aks_subnet_id
  oidc_issuer_url       = module.aks.oidc_issuer_url
  namespace             = var.langsmith_namespace
  service_account_name  = local.smithdb_service_account

  metastore_admin_username        = var.smithdb_metastore_admin_username
  metastore_admin_password        = var.smithdb_metastore_admin_password
  metastore_sku_name              = var.smithdb_metastore_sku_name
  metastore_storage_mb            = var.smithdb_metastore_storage_mb
  metastore_backup_retention_days = var.smithdb_metastore_backup_retention_days
  # The flag is derived from variables so the module's count can read it. The ID
  # beside it is a resource attribute and is unknown until apply on the external
  # path, which is why the two are passed separately. A supplied central zone
  # serves the metastore too, so the module creates its own only when there is
  # neither that nor LangSmith's server to share one with.
  create_private_dns_zone = var.postgres_source != "external" && !local.postgres_private_dns_zone_supplied
  private_dns_zone_id = (
    local.postgres_private_dns_zone_supplied ? var.postgres_private_dns_zone_id :
    var.postgres_source == "external" ? module.postgres[0].private_dns_zone_id : null
  )

  storage_account_name = local.smithdb_storage_name
  replication_type     = var.smithdb_storage_replication_type
  container_name       = var.smithdb_storage_container_name

  # Prefixed to keep it apart from private_dns_zone_id above, which is the
  # metastore's PostgreSQL zone.
  blob_private_endpoint_enabled   = var.storage_private_endpoint_enabled
  blob_private_endpoint_subnet_id = local.storage_private_endpoint_subnet_id
  blob_private_dns_zone_id        = local.blob_private_dns_zone_id

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
  resource_group_name = local.rg_name
  resource_group_id   = local.rg_id           # azapi parent_id for AMR
  subnet_id           = local.redis_subnet_id # private endpoint goes here
  vnet_id             = local.vnet_id         # private DNS zone link
  amr_sku             = var.amr_sku
  clustering_policy   = var.redis_clustering_policy
  high_availability   = var.redis_high_availability
  cluster_location    = var.redis_location # null => var.location

  tags = local.common_tags
}

# ── Blob private DNS ──────────────────────────────────────────────────────────
# Shared by the LangSmith trace-blob account and the SmithDB object store. The
# account keeps its usual <name>.blob.<cloud suffix> hostname; this zone is
# what makes that name resolve to the Private Endpoint address inside the VNet.
# Skipped when the operator supplies a central zone.

resource "azurerm_private_dns_zone" "blob" {
  count               = local.create_blob_private_dns_zone ? 1 : 0
  name                = local.azure_cloud.blob_private_dns_zone
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count                 = local.create_blob_private_dns_zone ? 1 : 0
  name                  = "${local.name_base}-blob-dnslink"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
  tags                  = local.common_tags
}

# ── Key Vault private DNS ─────────────────────────────────────────────────────
# Only with keyvault_private_endpoint_enabled and no central zone supplied. The
# vault keeps its <name>.vault.<cloud suffix> hostname; this zone is what makes
# it resolve to the endpoint's address inside the VNet.

resource "azurerm_private_dns_zone" "keyvault" {
  count               = local.create_keyvault_private_dns_zone ? 1 : 0
  name                = local.azure_cloud.keyvault_private_dns_zone
  resource_group_name = local.rg_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault" {
  count                 = local.create_keyvault_private_dns_zone ? 1 : 0
  name                  = "${local.name_base}-keyvault-dnslink"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault[0].name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
  tags                  = local.common_tags
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
  resource_group_name  = local.rg_name

  replication_type = var.storage_replication_type

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

  # When enabled, the public endpoint is turned off and the firewall above
  # becomes inert. It stays declared so disabling the endpoint restores a
  # default-deny account rather than an open one.
  private_endpoint_enabled   = var.storage_private_endpoint_enabled
  private_endpoint_subnet_id = local.storage_private_endpoint_subnet_id
  private_dns_zone_id        = local.blob_private_dns_zone_id

  tags = local.common_tags

  # A subnet ID is a plain string and creates no dependency, so the firewall rule
  # has to be told to wait for the endpoint that makes it valid.
  depends_on = [azapi_update_resource.byo_aks_subnet_endpoints]
}

# The historical backfill is the one SmithDB workload that reads outside its own
# object store: it pulls the run payloads LangSmith offloaded to the trace-blob
# account and rewrites them into SmithDB's format. Without this grant the job
# plans its tasks and then fails every one on a 403 from the source account.
# Reader rather than Contributor because it only reads there; it writes to the
# SmithDB account, which modules/smithdb grants separately.
#
# Migration-gated so a steady-state install leaves the identity able to reach
# nothing but its own account, matching the objectViewer binding in
# modules/gcp/infra/modules/smithdb/iam.tf. enable_smithdb is in the condition
# because this lives in the root module and indexes module.smithdb[0]: on the
# migration flag alone, enable_smithdb = false would hit "Invalid index" instead
# of the readable message in terraform_data.validate_network.
resource "azurerm_role_assignment" "smithdb_trace_blob_reader" {
  count = var.enable_smithdb && var.smithdb_migration_enabled ? 1 : 0

  scope                = module.blob.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = module.smithdb[0].workload_identity_principal_id
  principal_type       = "ServicePrincipal"
}

# Azure takes up to 10 minutes to make a blob data-plane grant effective, and the
# backfill Job is started by hand after this apply returns. Started too early it
# fails every task on a 403 from the source account, which is the same symptom as
# the grant above being absent. Hold the apply open instead: the delay is spent
# once, with an explanation, rather than in a failure that reads as a defect.
# Same approach as time_sleep.wait_for_rbac in modules/keyvault and
# time_sleep.agic_identity_propagation in modules/k8s-cluster.
#
# Nothing reads this resource. Blocking the apply is the entire effect, so it is
# not an unused resource to remove. triggers re-runs the delay when the grant is
# replaced rather than created, which happens if the trace-blob account is
# rebuilt and the scope moves with it.
#
# 300s against a 10-minute ceiling is deliberate: it covers the common case
# without stalling every migration apply for the worst one. SMITHDB.md keeps the
# verify-then-retry step, because this shortens the race and does not remove it.
resource "time_sleep" "smithdb_trace_blob_reader_propagation" {
  count = var.enable_smithdb && var.smithdb_migration_enabled ? 1 : 0

  create_duration = "300s"
  depends_on      = [azurerm_role_assignment.smithdb_trace_blob_reader]

  triggers = {
    role_assignment_id = azurerm_role_assignment.smithdb_trace_blob_reader[0].id
  }
}

# ── Key Vault ─────────────────────────────────────────────────────────────────
# Centralized secret storage for all LangSmith sensitive values.
# Depends on blob module (needs the managed identity principal ID for RBAC).
# Secrets stored here by Terraform: postgres password and license key.
#
# The LangSmith app secrets (admin password, API key salt, JWT secret, Fernet
# keys) are written straight to the vault by scripts/seed-keyvault-secrets.sh
# after apply, so they never enter Terraform state. Run `make seed-secrets`
# between `make apply` and `make k8s-secrets`.

# Read here rather than inside the keyvault module: its module-level depends_on
# defers every data source in it while module.blob has changes pending, which
# made the deployer's object_id unknown at plan time and replaced its grant.
data "azurerm_client_config" "current" {}

module "keyvault" {
  source              = "./modules/keyvault"
  name                = local.keyvault_name
  location            = var.location
  resource_group_name = local.rg_name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # The identity running apply, granted Secrets Officer so it can write secrets.
  terraform_principal_id = data.azurerm_client_config.current.object_id

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
  # With the private endpoint the vault has no public listener, so the subnet
  # rule would filter nothing, and dropping it is what lets the AKS subnet go
  # without the Microsoft.KeyVault service endpoint.
  allowed_subnet_ids = var.keyvault_private_endpoint_enabled ? [] : [local.aks_subnet_id]

  # Private Endpoint: public network access off, the endpoint in its subnet, and
  # its record in the supplied zone or the one created below.
  private_endpoint_enabled   = var.keyvault_private_endpoint_enabled
  private_endpoint_subnet_id = local.keyvault_private_endpoint_subnet_id
  private_dns_zone_id        = local.keyvault_private_dns_zone_id

  # ── Secrets ─────────────────────────────────────────────────────────────────
  # Only the two Terraform already holds in state for another reason. The
  # LangSmith app secrets are written to the vault post-apply by
  # scripts/seed-keyvault-secrets.sh and never pass through Terraform.
  # keyvault_manage_secrets = false drops those two too; the seed script then
  # writes all nine.
  manage_secrets          = var.keyvault_manage_secrets
  postgres_admin_password = var.postgres_admin_password
  langsmith_license_key   = var.langsmith_license_key

  purge_protection_enabled = var.keyvault_purge_protection

  tags = local.common_tags

  # The zone's VNet link comes before the endpoint and the secret writes, so a
  # runner inside the VNet resolves the vault's private address on first apply.
  depends_on = [module.blob, azapi_update_resource.byo_aks_subnet_endpoints, azurerm_private_dns_zone_virtual_network_link.keyvault]
}

# ── Kubernetes Bootstrap ───────────────────────────────────────────────────────
# Connects to the AKS cluster and:
#   1. Creates the langsmith namespace, service account, resource quota, network policies
#   2. Installs cert-manager (TLS automation) and KEDA (autoscaling)
#   3. Creates K8s secrets for PostgreSQL and Redis connection URLs
#
# LangSmith application deployment is handled outside Terraform:
#   Pass 1.5: bash helm/scripts/get-kubeconfig.sh <cluster> <rg>
#   Pass 2:   bash helm/scripts/generate-secrets.sh && bash helm/scripts/deploy.sh
#             (deploy.sh also applies the letsencrypt-prod ClusterIssuer)
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
  kube_auth              = module.aks.kube_auth

  # K8s namespace for LangSmith workloads
  langsmith_namespace = var.langsmith_namespace

  # SmithDB metastore connection. Keeping this Secret in the bootstrap module
  # ensures it uses that module's AKS-configured Kubernetes provider.
  enable_smithdb                   = var.enable_smithdb
  smithdb_metastore_host           = var.enable_smithdb ? module.smithdb[0].metastore_host : ""
  smithdb_metastore_database       = var.enable_smithdb ? module.smithdb[0].metastore_database : ""
  smithdb_metastore_username       = var.enable_smithdb ? module.smithdb[0].metastore_username : ""
  smithdb_metastore_password       = var.smithdb_metastore_admin_password
  smithdb_cache_storage_class_name = local.smithdb_cache_storage_class
  smithdb_cache_disk_iops          = var.smithdb_cache_disk_iops
  smithdb_cache_disk_throughput    = var.smithdb_cache_disk_throughput_mbps

  # Ingress controller — drives the NetworkPolicy's allowed source namespace and
  # cert-manager's Gateway API support.
  ingress_controller    = var.ingress_controller
  envoy_gateway_version = module.aks.envoy_gateway_version

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
  redis_cluster_node_uris = var.redis_source == "external" ? module.redis[0].cluster_node_uris : ""
  redis_cluster_password  = var.redis_source == "external" ? module.redis[0].cluster_password : ""

  # Standalone Fleet — creates the langsmith-fleet-postgres secret pointing at the
  # dedicated langsmith_fleet database. No fleet Redis secret: Fleet uses the chart's
  # in-cluster bundled Redis (Azure Managed Redis can't do the logical-DB isolation
  # the AWS/GCP Fleet relies on).
  enable_fleet                  = var.enable_fleet
  fleet_postgres_connection_url = var.postgres_source == "external" && var.enable_fleet ? module.postgres[0].fleet_connection_url : ""

  # Blob storage — Workload Identity client ID is added as a pod annotation
  # so the OIDC token exchange can bind the pod to the Managed Identity.
  blob_managed_identity_client_id    = module.blob.k8s_managed_identity_client_id
  backend_service_account_name       = "${local.langsmith_release_fullname}-backend"
  smithdb_service_account_name       = local.smithdb_service_account
  smithdb_managed_identity_client_id = var.enable_smithdb ? module.smithdb[0].workload_identity_client_id : ""

  # License key — stored in K8s secret langsmith-license.
  # App secrets (api_key_salt, jwt_secret, admin_password) are written by
  # helm/scripts/generate-secrets.sh from Azure Key Vault.
  langsmith_license_key = var.langsmith_license_key

  # Cluster components, off when the cluster already runs them, which is only
  # possible on the attach path. Helm cannot adopt a release it does not own.
  install_cert_manager = var.install_cert_manager
  install_keda         = var.install_keda

  # TLS / cert-manager. The ClusterIssuers themselves are applied by
  # helm/scripts/deploy.sh, which reads letsencrypt_email, langsmith_domain and
  # subscription_id straight from terraform.tfvars.
  tls_certificate_source          = var.tls_certificate_source
  cert_manager_identity_client_id = module.aks.cert_manager_identity_client_id
}

# The DNS-01 ClusterIssuer used to be a kubernetes_manifest in k8s-bootstrap, which
# broke terraform plan on a fresh deploy: kubernetes_manifest opens an API connection
# during plan and there is no cluster yet. deploy.sh already applied an identical
# issuer, so the Terraform copy was dropped. Existing deployments keep the live
# object; only the state entry goes.
removed {
  from = module.k8s_bootstrap.kubernetes_manifest.cluster_issuer_dns01

  lifecycle {
    destroy = false
  }
}

# ── WAF (optional) ────────────────────────────────────────────────────────────
# Deploy Azure WAF policy with OWASP 3.2 + bot protection.
# Attached to the Application Gateway when ingress_controller = "agic".
# Front Door needs its own policy type (azurerm_cdn_frontdoor_firewall_policy).
# Enable with: create_waf = true in terraform.tfvars

module "waf" {
  count               = var.create_waf ? 1 : 0
  source              = "./modules/waf"
  name                = "langsmith-waf${local.name_suffix}"
  resource_group_name = local.rg_name
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
  resource_group_name = local.rg_name
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
  resource_group_name  = local.rg_name
  location             = var.location
  subnet_id            = local.bastion_subnet_id
  vm_size              = var.bastion_vm_size
  admin_ssh_public_key = var.bastion_admin_ssh_public_key
  allowed_ssh_cidrs    = var.bastion_allowed_ssh_cidrs
  tags                 = local.common_tags

  depends_on = [module.vnet]
}

# A public Azure DNS zone answers on the internet, so with an internal load
# balancer its A record would publish a private address that resolves for
# everyone and connects for no one outside the network. The record exists only
# when ingress_ip is set; the zone alone is what DNS-01 needs. A warning rather
# than a refusal: a split-horizon setup can want exactly that record.
# Behind an internal load balancer there is no cloudapp label, so the hostname
# can only come from langsmith_domain. Without one, init-values.sh has nothing
# to write, and deploy.sh creates no Istio add-on Gateway. A warning, because
# a hostname can still be supplied to init-values.sh another way.
check "internal_ingress_hostname" {
  assert {
    condition     = var.ingress_load_balancer == "public" || var.langsmith_domain != ""
    error_message = "ingress_load_balancer = \"internal\" with no langsmith_domain: there is no cloudapp label behind a private address, so set langsmith_domain to the name your DNS resolves to the load balancer's IP."
  }
}

check "dns_zone_with_internal_ingress" {
  assert {
    condition     = !(var.create_dns_zone && var.ingress_load_balancer == "internal" && var.ingress_ip != "")
    error_message = "create_dns_zone = true and ingress_ip set with ingress_load_balancer = \"internal\": the public zone's A record would carry the load balancer's private address. Leave ingress_ip empty so the zone serves only the DNS-01 challenge, and put the record in your own DNS or an Azure Private DNS zone linked to the VNet, unless you mean to publish it."
  }
}

# ── DNS (optional) ────────────────────────────────────────────────────────────
# Azure DNS zone + A record. Delegates DNS-01 to cert-manager for TLS.
# Enable with: create_dns_zone = true and set langsmith_domain + ingress_ip.

module "dns" {
  count               = var.create_dns_zone ? 1 : 0
  source              = "./modules/dns"
  domain              = var.langsmith_domain
  resource_group_name = local.rg_name
  ingress_ip          = var.ingress_ip
  tags                = local.common_tags

  # Grant cert-manager DNS Zone Contributor so it can create TXT records
  # for DNS-01 ACME challenges. Only needed when tls_certificate_source = "dns01".
  grant_cert_manager_dns    = var.tls_certificate_source == "dns01"
  cert_manager_principal_id = var.tls_certificate_source == "dns01" ? module.aks.cert_manager_identity_principal_id : ""
}
