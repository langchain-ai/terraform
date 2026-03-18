# AWS IAM module
# Provisions an IRSA role and policies for LangSmith pods to access S3 and Secrets Manager.

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "langsmith" {
  name               = "${var.project}-${var.environment}-langsmith"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "aws_iam_policy_document" "langsmith" {
  statement {
    sid = "S3Access"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      var.blob_bucket_arn,
      "${var.blob_bucket_arn}/*",
    ]
  }

  statement {
    sid = "SecretsManagerRead"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.secrets_manager_secret_arn]
  }
}

resource "aws_iam_role_policy" "langsmith" {
  name   = "langsmith-policy"
  role   = aws_iam_role.langsmith.id
  policy = data.aws_iam_policy_document.langsmith.json
}
