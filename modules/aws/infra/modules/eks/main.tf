data "aws_region" "current" {}

locals {
  custom_networking = length(var.pod_subnet_ids_by_az) > 0

  # Role names that upstream modules choose for themselves. With a prefix, each
  # starts with it like the roles this module names, so one role/<prefix>-*
  # grant covers them all. Each fits a 15-character name_prefix plus "staging"
  # under IAM's 38-character name_prefix limit.
  prefixed_role_names = var.iam_role_name_prefix != null
  role_names = {
    alb_controller     = local.prefixed_role_names ? "${var.iam_role_name_prefix}-lb-controller" : "alb-controller"
    cluster_autoscaler = local.prefixed_role_names ? "${var.iam_role_name_prefix}-autoscaler" : "cluster-autoscaler"
    karpenter          = local.prefixed_role_names ? "${var.iam_role_name_prefix}-karpenter" : "karpenter"
    karpenter_node     = local.prefixed_role_names ? "${var.iam_role_name_prefix}-karpenter-node" : "karpenter-${var.cluster_name}"
    ebs_csi            = local.prefixed_role_names ? "${var.iam_role_name_prefix}-ebs-csi" : "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  }

  # Roles the caller created. Blueprints sets the IRSA annotation only on roles
  # it creates, so a supplied controller role gets it through set.
  existing_roles           = var.existing_iam_role_arns
  irsa_annotation          = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
  karpenter_node_role_name = local.existing_roles.karpenter_node != null ? reverse(split("/", local.existing_roles.karpenter_node))[0] : local.role_names.karpenter_node
  karpenter_node_role_arn  = local.existing_roles.karpenter_node != null ? local.existing_roles.karpenter_node : module.eks_blueprints_addons.karpenter.node_iam_role_arn

  # Custom networking owns the vpc-cni add-on, so a vpc-cni entry in eks_addons
  # moves here instead of going to the Blueprints add-on, where it would be a
  # second aws_eks_addon for the same add-on. Its settings carry over, and its
  # configuration_values are merged with the custom networking ones, so prefix
  # delegation or warm-pool tuning keeps working. Blueprints spells the conflict
  # policy resolve_conflicts; the upstream module splits it in two.
  user_vpc_cni        = try(var.eks_addons["vpc-cni"], {})
  user_vpc_cni_config = try(jsondecode(local.user_vpc_cni.configuration_values), {})
  vpc_cni_addon = merge(
    { for k, v in local.user_vpc_cni : k => v if !contains(["configuration_values", "resolve_conflicts"], k) },
    can(local.user_vpc_cni.resolve_conflicts) ? {
      resolve_conflicts_on_create = local.user_vpc_cni.resolve_conflicts
      resolve_conflicts_on_update = local.user_vpc_cni.resolve_conflicts
    } : {},
    {
      # Create the add-on without waiting for compute. Node groups wait only on
      # dataplane_wait_duration, not on this add-on, so that wait is what gives
      # the CNI time to be configured before nodes join. Nodes that joined
      # without it keep pod IPs in the node subnets until they are replaced.
      before_compute = true
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
          region  = data.aws_region.current.name
          subnets = { for az, id in var.pod_subnet_ids_by_az : az => { id = id } }
        }
      }))
    },
  )

  # try() covers extra groups, which are untyped and may omit either attribute.
  eks_managed_node_groups = {
    for k, v in merge(var.eks_managed_node_groups, var.extra_eks_managed_node_groups) : k => merge(v, {
      desired_size             = coalesce(try(v.desired_size, null), v.min_size)
      iam_role_use_name_prefix = coalesce(try(v.iam_role_use_name_prefix, null), true)
      # A node group name is user-chosen, so truncate it to the name_prefix limit.
      iam_role_name = try(v.iam_role_name, null) != null || !local.prefixed_role_names ? try(v.iam_role_name, null) : (
        coalesce(try(v.iam_role_use_name_prefix, null), true) ? substr("${var.iam_role_name_prefix}-${try(v.name, k)}", 0, 37) : "${var.iam_role_name_prefix}-${try(v.name, k)}"
      )
      create_iam_role               = local.existing_roles.node_group == null
      iam_role_arn                  = local.existing_roles.node_group
      iam_role_permissions_boundary = var.iam_permissions_boundary_arn
      iam_role_path                 = var.iam_role_path
    })
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                                   = var.vpc_id
  subnet_ids                               = var.subnet_ids
  cluster_endpoint_public_access           = var.public_cluster_enabled
  cluster_endpoint_public_access_cidrs     = var.public_access_cidrs
  enable_cluster_creator_admin_permissions = true
  cluster_enabled_log_types                = var.cluster_enabled_log_types

  create_iam_role               = local.existing_roles.cluster == null
  iam_role_arn                  = local.existing_roles.cluster
  iam_role_permissions_boundary = var.iam_permissions_boundary_arn
  iam_role_path                 = var.iam_role_path

  eks_managed_node_group_defaults = var.eks_managed_node_group_defaults

  # The community module ignores desired_size changes (lifecycle ignore_changes) so
  # the cluster autoscaler can manage it. min_size and max_size DO propagate through
  # terraform apply. If plan shows no changes after modifying min/max, run
  # `terraform refresh` first — the ASG may have been changed out-of-band (e.g. via
  # AWS CLI or console) and the state already reflects the new values.
  eks_managed_node_groups = local.eks_managed_node_groups

  cluster_addons = local.custom_networking ? { vpc-cni = local.vpc_cni_addon } : {}
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

  create_role                   = local.existing_roles.ebs_csi == null
  role_name                     = local.role_names.ebs_csi
  role_path                     = var.iam_role_path
  role_permissions_boundary_arn = var.iam_permissions_boundary_arn
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# Create the EBS CSI Driver addon for volume provisioning.
resource "aws_eks_addon" "ebs-csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = local.existing_roles.ebs_csi != null ? local.existing_roles.ebs_csi : module.irsa-ebs-csi.iam_role_arn
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
    create_role                   = local.existing_roles.alb_controller == null
    role_name                     = local.role_names.alb_controller
    role_path                     = var.iam_role_path
    role_permissions_boundary_arn = var.iam_permissions_boundary_arn
    set = concat(
      [{
        name  = "enableServiceMutatorWebhook"
        value = "false"
      }],
      local.existing_roles.alb_controller != null ? [{ name = local.irsa_annotation, value = local.existing_roles.alb_controller }] : [],
    )
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
  karpenter = {
    chart_version                 = var.karpenter_chart_version
    create_role                   = local.existing_roles.karpenter == null
    role_name                     = local.role_names.karpenter
    role_path                     = var.iam_role_path
    role_permissions_boundary_arn = var.iam_permissions_boundary_arn
    set = concat(
      # The primary ENI holds no pod IPs under custom networking, so Karpenter must
      # leave it out of the max-pods calculation or it overcommits every node.
      local.custom_networking ? [{ name = "settings.reservedENIs", value = "1" }] : [],
      local.existing_roles.karpenter != null ? [{ name = local.irsa_annotation, value = local.existing_roles.karpenter }] : [],
    )
  }
  # Stable node IAM role name (referenced by the SmithDB EC2NodeClass). The
  # controller itself runs on the core managed node group — SmithDB nodes are
  # tainted, so it never lands there.
  karpenter_node = {
    create_iam_role               = local.existing_roles.karpenter_node == null
    iam_role_arn                  = local.existing_roles.karpenter_node
    iam_role_use_name_prefix      = false
    iam_role_name                 = local.karpenter_node_role_name
    iam_role_path                 = var.iam_role_path
    iam_role_permissions_boundary = var.iam_permissions_boundary_arn
  }

  # Use a newer cluster-autoscaler chart with correct RBAC for K8s 1.33+
  cluster_autoscaler = {
    chart_version                 = "9.56.0"
    create_role                   = local.existing_roles.cluster_autoscaler == null
    role_name                     = local.role_names.cluster_autoscaler
    role_path                     = var.iam_role_path
    role_permissions_boundary_arn = var.iam_permissions_boundary_arn
    set                           = local.existing_roles.cluster_autoscaler != null ? [{ name = local.irsa_annotation, value = local.existing_roles.cluster_autoscaler }] : []
  }

  # EKS managed addons (coredns, kube-proxy, vpc-cni, etc.)
  # One filter rather than a conditional: the two branches of a conditional are
  # objects with different attributes, and differently shaped add-ons fail to
  # unify into one type even when custom networking is off.
  eks_addons = { for k, v in var.eks_addons : k => v if !(local.custom_networking && k == "vpc-cni") }

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
  principal_arn = local.karpenter_node_role_arn
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
  count = var.create_langsmith_irsa_role && local.existing_roles.langsmith == null ? 1 : 0

  name                 = "${module.eks.cluster_name}-irsa-role"
  path                 = var.iam_role_path
  permissions_boundary = var.iam_permissions_boundary_arn

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
