locals {
  policy_template_vars = {
    account_id               = local.account_id
    control_plane_account_id = local.control_plane_account_id
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
  delete_statements                     = jsondecode(templatefile("${path.module}/policies/delete.json", local.policy_template_vars))
  rds_statements                        = jsondecode(templatefile("${path.module}/policies/rds.json", local.policy_template_vars))
  route53_statements                    = jsondecode(templatefile("${path.module}/policies/route53.json", local.policy_template_vars))
  # Optional. Only applied if allow_public_ingress is true.
  route53_public_statements  = [for s in jsondecode(templatefile("${path.module}/policies/route53_public.json", local.policy_template_vars)) : s if var.allow_public_ingress]
  s3_statements              = jsondecode(templatefile("${path.module}/policies/s3.json", local.policy_template_vars))
  secrets_manager_statements = jsondecode(templatefile("${path.module}/policies/secrets_manager.json", local.policy_template_vars))
  vpc_statements             = jsondecode(templatefile("${path.module}/policies/vpc.json", local.policy_template_vars))

  delete_statements_for_policy = {
    for policy_name, statements in local.delete_statements : policy_name => [
      for statement in statements : statement if var.allow_delete_permissions
    ]
  }

  role_policies = {
    # Keep optional delete permissions packed into smaller existing policies so
    # each managed policy stays under IAM's 6,144 character policy size limit.
    # DeleteNetworkAclEntry is always required for network ACL reconciliation,
    # so it stays in the base VPC policy rather than the optional delete policy.
    vpc                        = local.vpc_statements
    ec2-eni                    = concat(local.ec2_eni_statements, local.delete_statements_for_policy.vpc)
    iam                        = concat(local.iam_statements, local.delete_statements_for_policy.iam)
    iam-karpenter-eks-profiles = concat(local.iam_karpenter_eks_profiles_statements, local.delete_statements_for_policy["iam-karpenter-eks-profiles"])
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
