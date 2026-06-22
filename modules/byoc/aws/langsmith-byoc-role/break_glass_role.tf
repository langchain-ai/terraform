locals {
  break_glass_eks_describe_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "arn:aws:eks:*:${local.account_id}:cluster/*-smith-eks"
    }]
  })
  break_glass_identitystore_user_ids = length(var.break_glass_identitystore_user_ids) > 0 ? var.break_glass_identitystore_user_ids : [
    "__no_identitystore_user_ids_configured__",
  ]
  break_glass_source_identities = length(var.break_glass_source_identities) > 0 ? var.break_glass_source_identities : [
    "__no_source_identities_configured__",
  ]
}

resource "aws_iam_role" "break_glass" {
  name = "LangSmithBYOCBreakGlass"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = var.allow_break_glass_access ? "Allow" : "Deny"
      Principal = {
        AWS = "arn:aws:iam::${var.langsmith_control_plane_account_id}:root"
      }
      Action = [
        "sts:AssumeRole",
        "sts:SetSourceIdentity"
      ]
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = var.langsmith_byoc_break_glass_principal_arn_patterns
        }
        StringEquals = {
          "identitystore:UserId" = local.break_glass_identitystore_user_ids
          "sts:SourceIdentity"   = local.break_glass_source_identities
        }
      }
    }]
  })

  tags = merge(var.tags, { managed_by = "langsmith" })
}

resource "aws_iam_role_policy" "break_glass_eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.break_glass.id
  policy = local.break_glass_eks_describe_policy
}
