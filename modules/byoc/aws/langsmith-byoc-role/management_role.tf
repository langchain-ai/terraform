resource "aws_iam_role" "langchain_byoc_management" {
  name        = var.management_role_name
  description = "Lower-privilege role for LangSmith Control Plane day 1 management operations"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.control_plane_reconcile_role_arn
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = merge(var.tags, {
    "langsmith-byoc-role"      = "true"
    "langsmith-byoc-role-type" = "management"
  })
}

locals {
  management_policy_template_vars = {
    account_id = local.account_id
  }

  management_guardrail_statements      = jsondecode(templatefile("${path.module}/management_policies/guardrails.json", local.management_policy_template_vars))
  management_acm_statements            = jsondecode(templatefile("${path.module}/management_policies/acm.json", local.management_policy_template_vars))
  management_eks_statements            = jsondecode(templatefile("${path.module}/management_policies/eks.json", local.management_policy_template_vars))
  management_elasticache_statements    = jsondecode(templatefile("${path.module}/management_policies/elasticache.json", local.management_policy_template_vars))
  management_elbv2_statements          = jsondecode(templatefile("${path.module}/management_policies/elbv2.json", local.management_policy_template_vars))
  management_eventbridge_statements    = jsondecode(templatefile("${path.module}/management_policies/eventbridge.json", local.management_policy_template_vars))
  management_iam_statements            = jsondecode(templatefile("${path.module}/management_policies/iam.json", local.management_policy_template_vars))
  management_iam_extra_statements      = jsondecode(templatefile("${path.module}/management_policies/iam_extra.json", local.management_policy_template_vars))
  management_kms_statements            = jsondecode(templatefile("${path.module}/management_policies/kms.json", local.management_policy_template_vars))
  management_lambda_statements         = jsondecode(templatefile("${path.module}/management_policies/lambda.json", local.management_policy_template_vars))
  management_rds_statements            = jsondecode(templatefile("${path.module}/management_policies/rds.json", local.management_policy_template_vars))
  management_route53_statements        = jsondecode(templatefile("${path.module}/management_policies/route53.json", local.management_policy_template_vars))
  management_route53_public_statements = jsondecode(templatefile("${path.module}/management_policies/route53_public.json", local.management_policy_template_vars))
  management_s3_statements             = jsondecode(templatefile("${path.module}/management_policies/s3.json", local.management_policy_template_vars))
  management_secrets_statements        = jsondecode(templatefile("${path.module}/management_policies/secrets_manager.json", local.management_policy_template_vars))
  management_vpc_statements            = jsondecode(templatefile("${path.module}/management_policies/vpc.json", local.management_policy_template_vars))

  management_role_policies = {
    for name, statements in {
      guardrails = local.management_guardrail_statements
      vpc        = local.management_vpc_statements
      iam        = concat(local.management_iam_statements, local.management_iam_extra_statements)
      eks        = local.management_eks_statements
      elbv2      = local.management_elbv2_statements
      data       = concat(local.management_rds_statements, local.management_secrets_statements, local.management_kms_statements)
      storage    = concat(local.management_elasticache_statements, local.management_s3_statements)
      lambda     = concat(local.management_lambda_statements, local.management_eventbridge_statements)
      dns        = concat(local.management_route53_statements, local.management_route53_public_statements, local.management_acm_statements)
    } : name => statements if length(statements) > 0
  }
}

resource "aws_iam_policy" "management" {
  for_each = local.management_role_policies

  name = "${var.management_role_name}-${each.key}"
  path = "/"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = each.value
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "management" {
  for_each = local.management_role_policies

  role       = aws_iam_role.langchain_byoc_management.name
  policy_arn = aws_iam_policy.management[each.key].arn
}
