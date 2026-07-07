# Dedicated S3 object store for SmithDB .vortex segments.
# Access is granted to the SmithDB IRSA role (irsa.tf) and locked to TLS.

resource "aws_s3_bucket" "object_store" {
  bucket        = var.bucket_name
  force_destroy = var.s3_force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "object_store" {
  bucket                  = aws_s3_bucket.object_store.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "object_store" {
  bucket = aws_s3_bucket.object_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.s3_kms_key_arn != "" ? "aws:kms" : "AES256"
      kms_master_key_id = var.s3_kms_key_arn != "" ? var.s3_kms_key_arn : null
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "object_store" {
  count  = var.s3_versioning_enabled ? 1 : 0
  bucket = aws_s3_bucket.object_store.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Deny any non-TLS access to the object store.
data "aws_iam_policy_document" "object_store" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.object_store.arn, "${aws_s3_bucket.object_store.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "object_store" {
  bucket = aws_s3_bucket.object_store.id
  policy = data.aws_iam_policy_document.object_store.json
}
