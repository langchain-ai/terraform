# IRSA role for the SmithDB service account. SmithDB pods use this role to read
# and write .vortex segments in the object-store bucket — no static S3 keys.
# https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
# Skipped when the caller supplies service_account_role_arn.

data "aws_iam_policy_document" "trust" {
  count = var.service_account_role_arn == null ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${var.eks_oidc_provider_url}:sub"
      values   = [local.oidc_sub_pattern]
    }
  }
}

data "aws_iam_policy_document" "s3_access" {
  count = var.service_account_role_arn == null ? 1 : 0

  statement {
    sid       = "ListAndLocate"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
  }

  statement {
    sid    = "ObjectReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_role" "smithdb" {
  count = var.service_account_role_arn == null ? 1 : 0

  name               = "${var.name}-irsa"
  assume_role_policy = data.aws_iam_policy_document.trust[0].json
  tags               = local.tags
}

resource "aws_iam_role_policy" "smithdb_s3" {
  count = var.service_account_role_arn == null ? 1 : 0

  name   = "smithdb-object-store-access"
  role   = aws_iam_role.smithdb[0].id
  policy = data.aws_iam_policy_document.s3_access[0].json
}
