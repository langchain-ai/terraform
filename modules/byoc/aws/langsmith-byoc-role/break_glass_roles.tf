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

# Read only role.

resource "aws_iam_role" "readonly_access" {
  name = "LangSmithBYOCReadOnlyAccess"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Principal = {
        AWS = var.langchain_break_glass_role_arn
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { managed_by = "langsmith" })

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy" "readonly_access_eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.readonly_access.id
  policy = local.break_glass_eks_describe_policy
}

# Cluster admin role, with no data access.

resource "aws_iam_role" "cluster_admin_access" {
  name = "LangSmithBYOCClusterAdminAccess"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Principal = {
        AWS = var.langchain_break_glass_role_arn
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { managed_by = "langsmith" })

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy" "cluster_admin_access_eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.cluster_admin_access.id
  policy = local.break_glass_eks_describe_policy
}

# Data access role, with full cluster + data access.

resource "aws_iam_role" "data_access" {
  name = "LangSmithBYOCDataAccess"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny"
      Principal = {
        AWS = var.langchain_break_glass_role_arn
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { managed_by = "langsmith" })

  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy" "data_access_eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.data_access.id
  policy = local.break_glass_eks_describe_policy
}
