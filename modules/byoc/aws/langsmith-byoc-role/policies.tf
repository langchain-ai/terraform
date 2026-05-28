locals {
  policy_template_vars = {
    account_id               = local.account_id
    control_plane_account_id = local.control_plane_account_id
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
  rds_statements                        = jsondecode(templatefile("${path.module}/policies/rds.json", local.policy_template_vars))
  route53_statements                    = jsondecode(templatefile("${path.module}/policies/route53.json", local.policy_template_vars))
  # Optional. Only applied if allow_public_ingress is true.
  route53_public_statements  = [for s in jsondecode(templatefile("${path.module}/policies/route53_public.json", local.policy_template_vars)) : s if var.allow_public_ingress]
  s3_statements              = jsondecode(templatefile("${path.module}/policies/s3.json", local.policy_template_vars))
  secrets_manager_statements = jsondecode(templatefile("${path.module}/policies/secrets_manager.json", local.policy_template_vars))
  vpc_statements             = jsondecode(templatefile("${path.module}/policies/vpc.json", local.policy_template_vars))

  role_policies = {
    vpc                        = local.vpc_statements
    ec2-eni                    = local.ec2_eni_statements
    iam                        = local.iam_statements
    iam-karpenter-eks-profiles = local.iam_karpenter_eks_profiles_statements
    eks                        = local.eks_statements
    elbv2                      = local.elbv2_statements
    data                       = concat(local.rds_statements, local.secrets_manager_statements, local.kms_statements)
    storage                    = concat(local.elasticache_statements, local.s3_statements)
    lambda                     = concat(local.lambda_statements, local.eventbridge_statements)
    dns                        = concat(local.route53_statements, local.route53_public_statements, local.acm_statements)
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
