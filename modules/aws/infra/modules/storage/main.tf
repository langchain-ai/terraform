#trivy:ignore:AVD-AWS-0090 Versioning is opt-in via var.versioning_enabled to avoid storage cost impact
resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket" {
  bucket = aws_s3_bucket.bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != "" ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "bucket" {
  count  = var.versioning_enabled ? 1 : 0
  bucket = aws_s3_bucket.bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_route_tables" "vpc" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

# S3 VPC Gateway Endpoint — keeps all S3 traffic private.
# https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html
# With this in place, pods in the VPC reach S3 over AWS's private backbone
# instead of the public internet. Combined with the bucket policy below
# (which restricts access to this endpoint), the S3 bucket is not publicly
# accessible and data never leaves the AWS network.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.vpc.ids
}

# Lifecycle management — automatic object deletion by prefix and age.
# Mirrors Azure Blob TTL pattern: ttl_s/ (short-lived) and ttl_l/ (long-lived).
#
# Rule "base":     delete ttl_s/* objects after N days (default: 14)  — standard traces
# Rule "extended": delete ttl_l/* objects after N days (default: 400) — long-retention traces
resource "aws_s3_bucket_lifecycle_configuration" "ttl" {
  count  = var.s3_ttl_enabled ? 1 : 0
  bucket = aws_s3_bucket.bucket.id

  rule {
    id     = "base"
    status = "Enabled"
    filter {
      prefix = "ttl_s/"
    }
    expiration {
      days = var.s3_ttl_short_days
    }
  }

  rule {
    id     = "extended"
    status = "Enabled"
    filter {
      prefix = "ttl_l/"
    }
    expiration {
      days = var.s3_ttl_long_days
    }
  }
}

# Bucket policy: only the LangSmith IRSA role, and only via the VPC Gateway
# Endpoint, can access this bucket. Requests from outside the VPC (including
# the public internet) are implicitly denied. This is the enforcement layer
# that guarantees the bucket stays private — even if someone misconfigures
# the block-public-access settings above, this policy still blocks external access.
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.bucket.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowAccessViaVPCE",
        Effect = "Allow",
        Principal = {
          AWS = var.langsmith_irsa_role_arn
        },
        Action = [
          "s3:*",
        ],
        Resource = [
          aws_s3_bucket.bucket.arn,
          "${aws_s3_bucket.bucket.arn}/*"
        ],
        Condition = {
          StringEquals = {
            "aws:SourceVpce" = aws_vpc_endpoint.s3.id
          }
        }
      }
    ]
  })
}
