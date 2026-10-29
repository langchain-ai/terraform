locals {
  policy_template_vars = {
    account_id               = local.account_id
    control_plane_account_id = local.control_plane_account_id
    customer_vpc_arns        = jsonencode(local.customer_vpc_arns)
    role_name                = var.role_name
  }

  acm_statements                        = jsondecode(templatefile("${path.module}/policies/acm.json", local.policy_template_vars))
  ec2_eni_statements                    = jsondecode(templatefile("${path.module}/policies/ec2-eni.json", local.policy_template_vars))
  eks_statements                        = jsondecode(templatefile("${path.module}/policies/eks.json", local.policy_template_vars))
  elasticache_statements                = jsondecode(templatefile("${path.module}/policies/elasticache.json", local.policy_template_vars))
  elbv2_statements                      = jsondecode(templatefile("${path.module}/policies/elbv2.json", local.policy_template_vars))
  eventbridge_statements                = jsondecode(templatefile("${path.module}/policies/eventbridge.json", local.policy_template_vars))
  iam_statements                        = jsondecode(templatefile("${path.module}/policies/iam.json", local.policy_template_vars))
  iam_karpenter_eks_profiles_statements = jsondecode(templatefile("${path.module}/policies/iam-karpenter-eks-profiles.json", local.policy_template_vars))
  kms_statements                        = jsondecode(templatefile("${path.module}/policies/kms.json", local.policy_template_vars))
  lambda_statements                     = jsondecode(templatefile("${path.module}/policies/lambda.json", local.policy_template_vars))
  network_firewall_statements           = jsondecode(templatefile("${path.module}/policies/network_firewall.json", local.policy_template_vars))
  delete_statements                     = jsondecode(templatefile("${path.module}/policies/delete.json", local.policy_template_vars))
  rds_statements                        = jsondecode(templatefile("${path.module}/policies/rds.json", local.policy_template_vars))
  route53_statements                    = jsondecode(templatefile("${path.module}/policies/route53.json", local.policy_template_vars))
  # Optional. Only applied if allow_public_ingress is true.
  route53_public_statements = [for s in jsondecode(templatefile("${path.module}/policies/route53_public.json", local.policy_template_vars)) : s if var.allow_public_ingress]
  s3_statements = [
    for statement in jsondecode(templatefile("${path.module}/policies/s3.json", local.policy_template_vars)) : statement
    if !(var.allow_retained_data_deletion && try(statement.Sid, "") == "S3DenyObjectDataAccess")
  ]
  s3_delete_statements       = jsondecode(templatefile("${path.module}/policies/s3_delete.json", local.policy_template_vars))
  secrets_manager_statements = jsondecode(templatefile("${path.module}/policies/secrets_manager.json", local.policy_template_vars))
  vpc_statements             = jsondecode(templatefile("${path.module}/policies/vpc.json", local.policy_template_vars))
  byovpc_vpc_statements      = jsondecode(templatefile("${path.module}/policies/vpc_byovpc.json", local.policy_template_vars))
  self_hosted_migration_statements = [
    for s in jsondecode(templatefile("${path.module}/policies/self_hosted_migration.json", local.policy_template_vars)) : s if var.allow_self_hosted_migration_permissions
  ]
  byovpc_self_hosted_migration_statements = [
    for s in jsondecode(templatefile("${path.module}/policies/self_hosted_migration_byovpc.json", local.policy_template_vars)) : s if var.allow_self_hosted_migration_permissions
  ]

  delete_statements_for_policy = {
    for policy_name, statements in local.delete_statements : policy_name => [
      for statement in statements : statement if var.allow_delete_permissions
    ]
  }

  unfiltered_role_policies = {
    # Keep optional delete permissions packed into smaller existing policies so
    # each managed policy stays under IAM's 6,144 character policy size limit.
    vpc = concat(
      [for statement in local.vpc_statements : statement if var.allow_vpc_creation_permissions],
      [for statement in local.byovpc_vpc_statements : statement if !var.allow_vpc_creation_permissions],
    )
    ec2-eni = concat(
      local.ec2_eni_statements,
      [for statement in local.network_firewall_statements : statement if var.allow_vpc_creation_permissions],
      [for statement in local.delete_statements_for_policy.vpc : statement if var.allow_vpc_creation_permissions],
      [for statement in local.delete_statements_for_policy.vpc_byovpc : statement if !var.allow_vpc_creation_permissions],
      [for statement in local.self_hosted_migration_statements : statement if var.allow_vpc_creation_permissions],
      [for statement in local.byovpc_self_hosted_migration_statements : statement if !var.allow_vpc_creation_permissions],
    )
    iam                        = local.iam_statements
    iam-karpenter-eks-profiles = concat(local.iam_karpenter_eks_profiles_statements, local.delete_statements_for_policy["iam-karpenter-eks-profiles"], local.delete_statements_for_policy.iam)
    eks                        = concat(local.eks_statements, local.delete_statements_for_policy.eks)
    elbv2                      = concat(local.elbv2_statements, local.delete_statements_for_policy.elbv2)
    data                       = concat(local.rds_statements, local.secrets_manager_statements, local.kms_statements, local.delete_statements_for_policy.data, local.delete_statements_for_policy.storage)
    storage                    = concat(local.elasticache_statements, local.s3_statements)
    lambda                     = concat(local.lambda_statements, local.eventbridge_statements, local.delete_statements_for_policy.lambda)
    dns = concat(
      local.route53_statements,
      local.route53_public_statements,
      local.acm_statements,
      local.delete_statements_for_policy.dns,
      var.allow_public_ingress ? local.delete_statements_for_policy["dns-public"] : [],
    )
  }

  byoiam_allowed_actions = [
    "iam:GetRole",
    "iam:ListAttachedRolePolicies",
    "iam:ListRolePolicies",
    "iam:GetRolePolicy",
    "iam:ListInstanceProfilesForRole",
    "iam:GetInstanceProfile",
    "iam:GetPolicy",
    "iam:GetPolicyVersion",
    "iam:ListPolicyVersions",
    "iam:PassRole",
    "iam:SimulatePrincipalPolicy",
  ]

  # Exact-ARN grants for BYOIAM resources with custom names. Read and pass only,
  # so the IAM-management filter below leaves them unchanged.
  byoiam_role_statements = [for statement in [
    {
      Sid      = "BYOIAMCustomRoleRead"
      Effect   = "Allow"
      Action   = ["iam:GetRole", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies", "iam:GetRolePolicy", "iam:ListInstanceProfilesForRole"]
      Resource = var.byoiam_role_arns
    },
    {
      Sid      = "BYOIAMCustomRolePass"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = var.byoiam_role_arns
      Condition = {
        StringEquals = {
          "iam:PassedToService" = ["eks.amazonaws.com", "ec2.amazonaws.com", "pods.eks.amazonaws.com", "monitoring.rds.amazonaws.com", "lambda.amazonaws.com"]
        }
      }
    },
  ] : statement if length(var.byoiam_role_arns) > 0]
  byoiam_instance_profile_statements = [for statement in [
    {
      Sid      = "BYOIAMCustomInstanceProfileRead"
      Effect   = "Allow"
      Action   = ["iam:GetInstanceProfile"]
      Resource = ["arn:aws:iam::${local.account_id}:instance-profile/${coalesce(var.byoiam_instance_profile_name, "unset")}"]
    },
  ] : statement if var.byoiam_instance_profile_name != null]
  byoiam_controller_policy_statements = [for statement in [
    {
      Sid      = "BYOIAMCustomControllerPolicyRead"
      Effect   = "Allow"
      Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
      Resource = [coalesce(var.byoiam_karpenter_controller_policy_arn, "unset")]
    },
  ] : statement if var.byoiam_karpenter_controller_policy_arn != null]
  byoiam_custom_name_statements = concat(
    local.byoiam_role_statements,
    local.byoiam_instance_profile_statements,
    local.byoiam_controller_policy_statements,
  )

  # Filter after composing teardown permissions so enabling deletes cannot
  # restore IAM writes. Mixed statements retain their permitted read actions.
  filtered_role_policies = {
    for name, statements in local.unfiltered_role_policies : name => [
      for statement in statements : merge(statement, {
        Action = [for action in flatten([statement.Action]) : action if
          var.allow_iam_management_permissions || !startswith(lower(action), "iam:") || contains(local.byoiam_allowed_actions, action)
        ]
      })
    ]
  }
  base_role_policies = {
    for name, statements in local.filtered_role_policies : name => [
      for statement in statements : statement if length(statement.Action) > 0
    ]
  }
  role_policies = merge(
    local.base_role_policies,
    var.allow_retained_data_deletion ? { storage-delete = local.s3_delete_statements } : {},
  )
}

resource "aws_iam_policy" "this" {
  for_each = local.role_policies

  name = "${var.role_name}-${each.key}"
  path = "/"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = local.role_policies

  role       = aws_iam_role.langchain_byoc.name
  policy_arn = aws_iam_policy.this[each.key].arn
}

resource "aws_iam_role_policy" "byoiam_custom_names" {
  count = length(local.byoiam_custom_name_statements) > 0 ? 1 : 0

  name = "${var.role_name}-byoiam"
  role = aws_iam_role.langchain_byoc.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.byoiam_custom_name_statements
  })
}
