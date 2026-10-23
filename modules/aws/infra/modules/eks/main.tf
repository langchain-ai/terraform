data "aws_region" "current" {}

locals {
  custom_networking = length(var.pod_subnet_ids_by_az) > 0

  # v21 hardcodes bootstrap_self_managed_addons = false (UPGRADE-21.0.md), so EKS
  # no longer auto-installs vpc-cni/kube-proxy/coredns at cluster creation the way
  # it did under v20. vpc-cni and kube-proxy additionally have to exist BEFORE the
  # node groups join (before_compute = true) or nodes never reach Ready and
  # node-group creation times out. eks_blueprints_addons (below) can't provide
  # that: its add-ons are created after create_delay_dependencies (the node group
  # ARNs) resolve via time_sleep.this, so by the time it would run, the node
  # groups it's implicitly waiting behind have already failed to come up. So
  # these three go through module.eks's own `addons` input instead, normalized
  # from the Blueprints eks_addons schema (`resolve_conflicts` single key) to the
  # one `addons` uses (split create/update). A key in var.eks_addons overrides
  # the matching default; the custom-networking vpc-cni entry's
  # configuration_values are layered on separately below. coredns schedules onto
  # nodes like any other pod, so it keeps the default before_compute = false,
  # which depends_on the node groups directly — same ordering Blueprints gave it.
  core_addon_names = toset(["vpc-cni", "kube-proxy", "coredns"])

  core_addons = {
    for name in local.core_addon_names : name => merge(
      {
        # v20 effectively defaulted to resolve_conflicts_on_create = "OVERWRITE"
        # (bootstrap_self_managed_addons was true, which this module used to
        # pick the conflict policy) and most_recent = false. v21 changed those
        # defaults to "NONE" / true (UPGRADE-21.0.md) for every entry in
        # `addons` — pin the old values here so these don't silently start
        # auto-upgrading or conflict-failing on apply.
        resolve_conflicts_on_create = "OVERWRITE"
        resolve_conflicts_on_update = "OVERWRITE"
        most_recent                 = false
      },
      { for k, v in try(var.eks_addons[name], {}) : k => v if !contains(["configuration_values", "resolve_conflicts"], k) },
      can(var.eks_addons[name].resolve_conflicts) ? {
        resolve_conflicts_on_create = var.eks_addons[name].resolve_conflicts
        resolve_conflicts_on_update = var.eks_addons[name].resolve_conflicts
      } : {},
      name == "coredns" ? {} : { before_compute = true },
    )
  }

  # Custom networking owns vpc-cni's configuration_values: prefix delegation or
  # warm-pool tuning in a user-supplied var.eks_addons["vpc-cni"] still carries
  # over via local.core_addons above, merged with the custom networking settings
  # here so neither side clobbers the other.
  user_vpc_cni_config = try(jsondecode(local.core_addons["vpc-cni"].configuration_values), {})

  addons = merge(
    local.core_addons,
    local.custom_networking ? {
      "vpc-cni" = merge(local.core_addons["vpc-cni"], {
        configuration_values = jsonencode(merge(local.user_vpc_cni_config, {
          env = merge(try(local.user_vpc_cni_config.env, {}), {
            AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
            ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
          })
          # One ENIConfig per AZ, named after the AZ. securityGroups is omitted,
          # so pod ENIs carry the node security group and every rule that admits
          # nodes (the ALB target rules included) admits pods too.
          eniConfig = {
            create  = true
            region  = data.aws_region.current.region
            subnets = { for az, id in var.pod_subnet_ids_by_az : az => { id = id } }
          }
        }))
      })
    } : {},
  )

  # v21 changed these (UPGRADE-21.0.md). They are merged under
  # eks_managed_node_group_defaults because setting that variable replaces its
  # default entirely. Hop limit 1 blocks pod IMDSv2, which the ALB controller
  # uses to look up its VPC and region. Monitoring and AMI following are the
  # v20 values. metadata_options is merged key-wise so a partial override keeps
  # the keys it does not set.
  v20_node_group_defaults = {
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 2
    }
    enable_monitoring              = true
    use_latest_ami_release_version = false
  }

  # try() covers extra groups, which are untyped and may omit either attribute.
  # eks_managed_node_group_defaults is merged in here (pins, then the variable,
  # then the group) because v21 of the upstream module dropped that top-level
  # input — see UPGRADE-21.0.md. This is also what lets a group-level
  # cpu_options (e.g. sandbox_host_node_group_overrides.cpu_options.
  # nested_virtualization) reach the upstream module: it is typed as `any`
  # here, and v21's eks_managed_node_groups object type has
  # cpu_options.nested_virtualization, so it survives the conversion into that
  # type (v20's cpu_options object type only had core_count/threads_per_core
  # and silently dropped it).
  # A null capacity_type is omitted so the upstream module keeps ON_DEMAND
  # without planning a capacity change on groups that never set it.
  eks_managed_node_groups = {
    for k, v in merge(var.eks_managed_node_groups, var.extra_eks_managed_node_groups) : k => merge(
      local.v20_node_group_defaults,
      var.eks_managed_node_group_defaults,
      { for attr, value in v : attr => value if !(attr == "capacity_type" && value == null) },
      {
        # Drop null maps instead of merging {}. merge() with an empty object
        # turns the hop limit into a string.
        metadata_options = merge([
          for m in [
            local.v20_node_group_defaults.metadata_options,
            try(var.eks_managed_node_group_defaults.metadata_options, null),
            try(v.metadata_options, null),
          ] : m if m != null
        ]...)
        desired_size             = coalesce(try(v.desired_size, null), v.min_size)
        iam_role_use_name_prefix = coalesce(try(v.iam_role_use_name_prefix, null), true)
      }
    )
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id                                   = var.vpc_id
  subnet_ids                               = var.subnet_ids
  endpoint_public_access                   = var.public_cluster_enabled
  endpoint_public_access_cidrs             = var.public_access_cidrs
  enable_cluster_creator_admin_permissions = true
  enabled_log_types                        = var.cluster_enabled_log_types

  # The community module ignores desired_size changes (lifecycle ignore_changes) so
  # the cluster autoscaler can manage it. min_size and max_size DO propagate through
  # terraform apply. If plan shows no changes after modifying min/max, run
  # `terraform refresh` first — the ASG may have been changed out-of-band (e.g. via
  # AWS CLI or console) and the state already reflects the new values.
  eks_managed_node_groups = local.eks_managed_node_groups

  addons = local.addons
  # 30s is the upstream default. Custom networking waits longer so the vpc-cni
  # add-on is active before the first nodes join.
  dataplane_wait_duration = local.custom_networking ? "2m" : "30s"

  tags = var.tags
}

# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.24.1"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# Create the EBS CSI Driver addon for volume provisioning.
resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
  tags                     = var.tags

  depends_on = [module.eks]
}

# Create some important addons for the EKS cluster.
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  # Disable the ALB controller's cluster-wide Service mutating webhook
  # (mservice.elbv2.k8s.aws). This module uses ALB Ingress + TargetGroupBinding,
  # not Service type=LoadBalancer, so the mutator is unnecessary. Leaving it on
  # makes the controller intercept ALL Service creations, which races with other
  # Helm releases on a fresh apply - notably Karpenter, whose Service fails with
  # "no endpoints available for service aws-load-balancer-webhook-service" if the
  # ALB controller pods aren't ready yet.
  aws_load_balancer_controller = {
    set = [{
      name  = "enableServiceMutatorWebhook"
      value = "false"
    }]
  }

  enable_metrics_server     = true
  enable_cluster_autoscaler = true

  # Karpenter provisions the SmithDB instance-store (local-NVMe, RAID0) and
  # compute pools. It coexists with cluster-autoscaler, which manages the core
  # managed node group; the two own disjoint nodes. When enabled, this installs
  # the Karpenter controller, its IRSA role, the node IAM role, and the SQS
  # interruption queue. The SmithDB NodePools/EC2NodeClasses are created in the
  # infra root.
  enable_karpenter = var.enable_karpenter
  karpenter = merge(
    { chart_version = var.karpenter_chart_version },
    # The primary ENI holds no pod IPs under custom networking, so Karpenter must
    # leave it out of the max-pods calculation or it overcommits every node.
    local.custom_networking ? { set = [{ name = "settings.reservedENIs", value = "1" }] } : {},
  )
  # Stable node IAM role name (referenced by the SmithDB EC2NodeClass). The
  # controller itself runs on the core managed node group — SmithDB nodes are
  # tainted, so it never lands there.
  karpenter_node = {
    iam_role_use_name_prefix = false
  }

  # Use a newer cluster-autoscaler chart with correct RBAC for K8s 1.33+
  cluster_autoscaler = {
    chart_version = "9.56.0"
  }

  # EKS managed addons other than vpc-cni/kube-proxy/coredns, which are handled
  # by module.eks's own `addons` input above (see local.core_addons) so they can
  # be created before the node groups that need them to come up.
  eks_addons = { for k, v in var.eks_addons : k => v if !contains(local.core_addon_names, k) }

  # Waits for node groups without a module-level depends_on, which defers this module's data sources and replaces (detaches) the Karpenter node role's policy attachments whenever module.eks changes.
  create_delay_dependencies = [for ng in module.eks.eks_managed_node_groups : ng.node_group_arn]
}

# Karpenter node role access entry. The eks-blueprints add-on creates the
# Karpenter node IAM role but NOT the EKS access entry, so Karpenter-launched
# instances can't register as nodes (they hang at NodeClaim Ready=Unknown) on a
# cluster using access-entry auth. EC2_LINUX maps the role to system:nodes; no
# access-policy association is needed.
resource "aws_eks_access_entry" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks_blueprints_addons.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"

  depends_on = [module.eks_blueprints_addons]
}

# Create the gp3 storage class, make it the default storage class, and allow volume expansion.
resource "kubernetes_storage_class" "gp3_default" {
  count = var.create_gp3_storage_class ? 1 : 0
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  depends_on = [aws_eks_addon.ebs-csi]
}

# Port 15017 is the istiod sidecar-injector webhook port. The EKS API server must
# reach it from the cluster security group (sg-* associated with the control plane).
# The upstream EKS module does not include this port in its default webhook rules.
resource "aws_security_group_rule" "istiod_webhook" {
  count = var.enable_istio_gateway ? 1 : 0

  type                     = "ingress"
  from_port                = 15017
  to_port                  = 15017
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "Cluster API to node 15017/tcp istio sidecar-injector webhook"

  depends_on = [module.eks]
}

# IRSA role for LangSmith pods — allows pods to access S3 via their service account.
# https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
resource "aws_iam_role" "langsmith" {
  count = var.create_langsmith_irsa_role ? 1 : 0

  name = "${module.eks.cluster_name}-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:${var.langsmith_namespace}:*"
          }
        }
      }
    ]
  })

  depends_on = [module.eks]
}
