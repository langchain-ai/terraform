// Tag vpc/subnets with the LangGraph Cloud enabled tag
resource "aws_ec2_tag" "langgraph_cloud_enabled_tags" {
  for_each = toset(concat([var.vpc_id], var.private_subnet_ids, var.public_subnet_ids))

  resource_id = each.key
  key         = "langgraph-cloud-enabled"
  value       = "1"
}

// Tag all private subnets with the LangGraph Cloud tag. Private subnets are used to deploy ECS tasks and RDS instances.
resource "aws_ec2_tag" "langgraph_cloud_private_subnet_tags" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "langgraph-cloud-private"
  value       = "1"
}

resource "aws_db_subnet_group" "langgraph_cloud_db_subnet_group" {
  name       = "langgraph-cloud-db-subnet-group"
  subnet_ids = var.private_subnet_ids
}

// Tag all public subnets with LangGraph cloud tags. Load Balancers will be deployed in public subnets.
resource "aws_ec2_tag" "langgraph_cloud_public_subnet_tags" {
  for_each    = toset(var.public_subnet_ids)
  resource_id = each.value
  key         = "langgraph-cloud-private"
  value       = "0"
}

// Create a role with access to provision ECS and RDS resources in the account
resource "aws_iam_role" "langgraph_cloud_role" {
  name               = "LangGraphCloudBYOCRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

// Attach the necessary policies to the role
resource "aws_iam_role_policy_attachment" "role_attachments" {
  for_each   = toset(["AmazonVPCReadOnlyAccess", "AmazonECS_FullAccess", "SecretsManagerReadWrite", "CloudWatchReadOnlyAccess", "AmazonRDSFullAccess"])
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
  role       = aws_iam_role.langgraph_cloud_role.name
}

resource "aws_iam_policy" "custom_permissions" {
  name = "LangGraphCloudCustomPermissions"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "application-autoscaling:*",
        ],
        Resource = "*",
      },
    ],
  })
}

resource "aws_iam_role_policy_attachment" "custom_policy" {
  policy_arn = aws_iam_policy.custom_permissions.arn
  role       = aws_iam_role.langgraph_cloud_role.name
}


// Allow LangGraph Cloud role to assume role in the account
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.langgraph_role_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = var.langgraph_external_ids
    }
  }
}

resource "aws_cloudwatch_log_group" "langgraph_cloud_log_group" {
  name = "/aws/ecs/langgraph-cloud"
}

// Create an ECS cluster
resource "aws_ecs_cluster" "langgraph_cloud_cluster" {
  name = "langgraph-cloud-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

}

// Create ECS role with ECR access and access to its own secret
resource "aws_iam_role" "langgraph_cloud_ecs_role" {
  name               = "LangGraphCloudECSTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_role_policy" {
  role       = aws_iam_role.langgraph_cloud_ecs_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "secrets_read" {
  name        = "SecretsRead"
  description = "Allows reading secrets from Secrets Manager"
  policy = jsonencode(
    {
      "Version" : "2012-10-17",
      "Statement" : [
        {
          "Effect" : "Allow",
          "Action" : "secretsmanager:GetSecretValue",
          "Resource" : "*",
          "Condition" : {
            "StringLike" : {
              "aws:ResourceTag/langgraph-cloud" : "*"
            }
          }
        }
      ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "secrets_read" {
  role       = aws_iam_role.langgraph_cloud_ecs_role.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

// Create Load Balancer Service Linked Role
resource "aws_iam_service_linked_role" "elastic_load_balancing" {
  aws_service_name = "elasticloadbalancing.amazonaws.com"
}

resource "aws_security_group" "langgraph_cloud_lb_sg" {
  name        = "langgraph-cloud-lb-sg"
  description = "Security group for LangGraph Cloud Load Balancer"
  vpc_id      = var.vpc_id

  // HTTP and HTTPS ingress
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  // Egress to the internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    langgraph-cloud-enabled = "1"
  }
}

resource "aws_security_group" "langgraph_cloud_service_sg" {
  name        = "langgraph-cloud-service-sg"
  description = "Security group for LangGraph Cloud ECS services/RDS instances"
  vpc_id      = var.vpc_id

  // Ingress from lbs
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.langgraph_cloud_lb_sg.id]
  }

  // Ingress from Self
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  // Egress to the internet
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    langgraph-cloud-enabled = "1"
  }
}
