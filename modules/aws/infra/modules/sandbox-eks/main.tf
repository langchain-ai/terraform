# A second EKS cluster that runs only the sandbox-host node group. It follows
# ../eks on the upstream module version and on the v21 adjustments below, so a
# fix to one usually belongs in the other.

locals {
  # v21 no longer bootstraps vpc-cni, kube-proxy and coredns at cluster
  # creation, and nodes never reach Ready unless vpc-cni and kube-proxy exist
  # before the node group joins (before_compute = true). Same normalization as
  # ../eks: the old v20 conflict policy and version pin, then any override from
  # var.cluster_addons for these three, whose Blueprints-style
  # resolve_conflicts key is split into the create/update pair v21 expects.
  # Other add-ons in var.cluster_addons are left to the LangSmith cluster: this
  # cluster runs sandbox-host and CoreDNS only.
  core_addon_names = toset(["vpc-cni", "kube-proxy", "coredns"])

  addons = {
    for name in local.core_addon_names : name => merge(
      {
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        most_recent                 = false
      },
      { for k, v in try(var.cluster_addons[name], {}) : k => v if k != "resolve_conflicts" },
      can(var.cluster_addons[name].resolve_conflicts) ? {
        resolve_conflicts_on_create = var.cluster_addons[name].resolve_conflicts
        resolve_conflicts_on_update = var.cluster_addons[name].resolve_conflicts
      } : {},
      name == "coredns" ? {} : { before_compute = true },
    )
  }

  # v21 dropped the module-level eks_managed_node_group_defaults input, so the
  # defaults are merged into the group here, as ../eks does: the v20 values,
  # then var.managed_node_group_defaults, then the group. metadata_options is
  # merged key by key, so the group's hop limit of 1 survives a partial
  # default. A null capacity_type is dropped so the upstream default
  # (ON_DEMAND) applies.
  v20_node_group_defaults = {
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
    enable_monitoring              = true
    use_latest_ami_release_version = false
  }

  sandbox_host_node_group = merge(
    local.v20_node_group_defaults,
    var.managed_node_group_defaults,
    { for attr, value in var.managed_node_group : attr => value if !(attr == "capacity_type" && value == null) },
    {
      metadata_options = merge([
        for m in [
          local.v20_node_group_defaults.metadata_options,
          try(var.managed_node_group_defaults.metadata_options, null),
          try(var.managed_node_group.metadata_options, null),
        ] : m if m != null
      ]...)
      desired_size             = coalesce(try(var.managed_node_group.desired_size, null), var.managed_node_group.min_size)
      iam_role_use_name_prefix = coalesce(try(var.managed_node_group.iam_role_use_name_prefix, null), true)
    }
  )
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id                       = var.vpc_id
  subnet_ids                   = var.subnet_ids
  endpoint_private_access      = true
  endpoint_public_access       = var.public_cluster_enabled
  endpoint_public_access_cidrs = var.public_access_cidrs

  enable_cluster_creator_admin_permissions = true
  enabled_log_types                        = var.cluster_enabled_log_types

  eks_managed_node_groups = {
    sandbox_host = local.sandbox_host_node_group
  }

  addons = local.addons

  tags = var.tags
}
