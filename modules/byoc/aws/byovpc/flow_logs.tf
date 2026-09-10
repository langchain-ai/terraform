data "aws_caller_identity" "current" {
  count = var.enable_vpc_flow_logs ? 1 : 0
}

data "aws_partition" "current" {
  count = var.enable_vpc_flow_logs ? 1 : 0
}

resource "aws_s3_bucket" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  # The provider limits bucket_prefix to 37 characters; reserve 21 for the stable suffix.
  bucket_prefix = "${substr(var.name, 0, 16)}-smith-vpc-flow-logs-"

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpc-flow-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id

  rule {
    id     = "expire-flow-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "cleanup-expired-flow-log-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_versioning.flow_logs]
}

resource "aws_s3_bucket_policy" "flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  bucket = aws_s3_bucket.flow_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.flow_logs[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current[0].account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current[0].partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current[0].account_id}:*"
          }
        }
      },
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.flow_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current[0].account_id}/*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current[0].account_id
            "s3:x-amz-acl"      = "bucket-owner-full-control"
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current[0].partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current[0].account_id}:*"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.flow_logs[0].arn,
          "${aws_s3_bucket.flow_logs[0].arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.flow_logs]
}

resource "aws_flow_log" "this" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  log_destination          = aws_s3_bucket.flow_logs[0].arn
  log_destination_type     = "s3"
  traffic_type             = "ALL"
  max_aggregation_interval = 600

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpc-flow-log"
  })

  depends_on = [
    aws_s3_bucket_lifecycle_configuration.flow_logs,
    aws_s3_bucket_ownership_controls.flow_logs,
    aws_s3_bucket_policy.flow_logs,
    aws_s3_bucket_server_side_encryption_configuration.flow_logs,
  ]
}
