data "aws_caller_identity" "current" {}

resource "aws_iam_role" "langchain_byoc" {
  name        = var.role_name
  description = "Role for LangSmith Control Plane to manage resources"

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
    "langsmith-byoc-role" = "true"
  })

  lifecycle {
    precondition {
      condition     = var.allow_vpc_creation_permissions || length(var.vpc_ids) > 0
      error_message = "At least one vpc_ids entry is required when allow_vpc_creation_permissions is false."
    }
  }
}

locals {
  account_id               = data.aws_caller_identity.current.account_id
  control_plane_account_id = split(":", var.control_plane_reconcile_role_arn)[4]
  customer_vpc_arns = [
    for vpc_id in sort(tolist(var.vpc_ids)) : "arn:aws:ec2:*:${local.account_id}:vpc/${vpc_id}"
  ]
}
