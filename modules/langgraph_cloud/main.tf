data "aws_availability_zones" "available" {}

module "langgraph_cloud_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "langgraph-cloud-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  private_subnet_tags = {
    "langgraph-cloud-enabled" = 1
    "private"                 = 1
  }

  public_subnet_tags = {
    "private"                 = 0
    "langgraph-cloud-enabled" = 1
  }

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  tags = {
    "langgraph-cloud-enabled" = "1"
  }
}

resource "aws_db_subnet_group" "langgraph_cloud_db_subnet_group" {
  name       = "langgraph-cloud-db-subnet-group"
  subnet_ids = module.langgraph_cloud_vpc.private_subnets
}

// Create a role with access to provision ECS and RDS resources in the account
resource "aws_iam_role" "langgraph_cloud_role" {
  name               = "LangGraphCloudBYOCRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

// Attach the necessary policies to the role
resource "aws_iam_policy_attachment" "role_attachments" {
  for_each   = toset(["AmazonVPCReadOnlyAccess", "AmazonECS_FullAccess", "SecretsManagerReadWrite", "CloudWatchReadOnlyAccess", "AmazonRDSFullAccess"])
  name       = "LangGraphCloudRoleAttachment-${each.key}"
  policy_arn = "arn:aws:iam::aws:policy/${each.key}"
  roles      = [aws_iam_role.langgraph_cloud_role.name]
}

// Allow LangGraph Cloud role to assume role in the account
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.langgraph_role_arn]
    }
  }
}

resource "aws_cloudwatch_log_group" "langgraph_cloud_log_group" {
  name = "langgraph-cloud"
}

// Create an ECS cluster
resource "aws_ecs_cluster" "langgraph_cloud_cluster" {
  name = "langgraph-cloud-cluster"
}

// Create ECS role with ECR access
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

// TODO: Scope the GetSecretValue to only langgraph-cloud secrets
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
        }
      ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "secrets_read" {
  role       = aws_iam_role.langgraph_cloud_ecs_role.name
  policy_arn = aws_iam_policy.secrets_read.arn
}

// Create Load Balancer Role
data "aws_iam_policy_document" "lb_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_iam_service_linked_role" "elastic_load_balancing" {
  aws_service_name = "elasticloadbalancing.amazonaws.com"
}
