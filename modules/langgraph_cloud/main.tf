data "aws_availability_zones" "available" {}

module "langgraph_cloud_vpc" {
  count   = var.vpc_id ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "langgraph-cloud-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
}

// Fetch VPC and subnets using data resource
data "aws_vpc" "langgraph_cloud_vpc" {
  id = var.vpc_id ? var.vpc_id : module.langgraph_cloud_vpc[0].vpc_id
}

data "aws_subnets" "langgraph_cloud_subnets" {
  vpc_id = data.aws_vpc.langgraph_cloud_vpc.id
}

// Tag the VPC and subnets with `langgraph-cloud-enabled` tag so we can identify them later
resource "aws_ec2_tag" "langgraph_cloud_vpc" {
  resource_id = data.aws_vpc.langgraph_cloud_vpc.id
  key         = "langgraph-cloud-enabled"
  value       = "1"
}

resource "aws_ec2_tag" "langgraph_cloud_enabled" {
  for_each    = toset(data.aws_subnets.langgraph_cloud_subnets.ids)
  resource_id = each.value
  key         = "langgraph-cloud-enabled"
  value       = "1"
}

// Create a role with access to provision ECS and RDS resources in the account
resource "aws_iam_role" "langgraph_cloud_role" {
  name               = "LangGraphCloudBYOCRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

// Attach the necessary policies to the role
resource "aws_iam_policy_attachment" "role_attachments" {
  for_each   = ["AmazonVPCReadOnlyAccess", "AmazonECS_FullAccess", "SecretsManagerReadWrite", "CloudWatchReadOnlyAccess", "AmazonRDSFullAccess"]
  name       = "LangGraphCloudRoleAttachment-${each.key}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/${each.key}"
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
  name = "/aws/ecs/langgraph-cloud"
}

// Create an ECS cluster
resource "aws_ecs_cluster" "langgraph_cloud_cluster" {
  name = "langgraph-cloud-cluster"

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloudwatch_log_group_arn = aws_cloudwatch_log_group.langgraph_cloud_log_group.arn
      }
    }
  }
}
