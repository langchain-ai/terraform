locals {
  break_glass_eks_describe_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:DescribeCluster"
      Resource = "arn:aws:eks:*:${local.account_id}:cluster/*-smith-eks"
    }]
  })
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
          "identitystore:UserId" = var.break_glass_identitystore_user_ids
          "sts:SourceIdentity"   = var.break_glass_source_identities
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
