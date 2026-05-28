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
          AWS = var.control_plane_role_arn
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
}

locals {
  account_id               = data.aws_caller_identity.current.account_id
  control_plane_account_id = split(":", var.control_plane_role_arn)[4]
}
