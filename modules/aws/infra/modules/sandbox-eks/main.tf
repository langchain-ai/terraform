module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                               = var.vpc_id
  subnet_ids                           = var.subnet_ids
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.public_cluster_enabled
  cluster_endpoint_public_access_cidrs = var.public_access_cidrs

  enable_cluster_creator_admin_permissions = true
  cluster_enabled_log_types                = var.cluster_enabled_log_types

  cluster_addons = merge({
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }, var.cluster_addons)

  eks_managed_node_group_defaults = var.managed_node_group_defaults
  eks_managed_node_groups = {
    sandbox_host = merge(var.managed_node_group, {
      desired_size             = coalesce(var.managed_node_group.desired_size, var.managed_node_group.min_size)
      iam_role_use_name_prefix = coalesce(var.managed_node_group.iam_role_use_name_prefix, true)
    })
  }

  tags = var.tags
}
