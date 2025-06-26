locals {
  # Feel free to update these local variables for your use case if needed.
  identifier    = "-replicated-ch"
  vpc_name      = "langsmith-vpc${local.identifier}"
  cluster_name  = "langsmith-eks${local.identifier}"
  redis_name    = "langsmith-redis${local.identifier}"
  bucket_name   = "langsmith-s3${local.identifier}"
  postgres_name = "langsmith-postgres${local.identifier}"

  vpc_id          = var.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  private_subnets = var.create_vpc ? module.vpc[0].private_subnets : var.private_subnets
  public_subnets  = var.create_vpc ? module.vpc[0].public_subnets : var.public_subnets
  vpc_cidr_block  = var.create_vpc ? module.vpc[0].vpc_cidr_block : var.vpc_cidr_block
}

provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}


provider "kubernetes" {
  host                   = module.eks.endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

module "vpc" {
  source = "../vpc"

  count        = var.create_vpc ? 1 : 0
  vpc_name     = local.vpc_name
  cluster_name = local.cluster_name
}

module "eks" {
  source       = "../eks"
  cluster_name = local.cluster_name
  vpc_id       = local.vpc_id
  subnet_ids   = concat(local.private_subnets, local.public_subnets)
  tags         = var.eks_tags

  eks_managed_node_groups = {
    default = {
      name           = "node-group-default"
      instance_types = ["m5.4xlarge"]
      min_size       = 1
      max_size       = 10
    }
    large = {
      name           = "node-group-large"
      instance_types = ["m5.16xlarge"]
      min_size       = 1
      max_size       = 3
    }
  }
}

module "redis" {
  source        = "../redis"
  name          = local.redis_name
  vpc_id        = local.vpc_id
  subnet_ids    = local.private_subnets
  instance_type = "cache.m6g.xlarge"
  ingress_cidrs = [local.vpc_cidr_block]
}

module "s3" {
  source      = "../s3"
  bucket_name = local.bucket_name
  region      = var.region
  vpc_id      = local.vpc_id
}

module "postgres" {
  source        = "../postgres"
  identifier    = local.postgres_name
  vpc_id        = local.vpc_id
  subnet_ids    = local.private_subnets
  ingress_cidrs = [local.vpc_cidr_block]

  username = var.postgres_username
  password = var.postgres_password
}

module "cluster_bootstrap" {
  source      = "../../../../deployments/modules/kubernetes/cluster_bootstrap"
  environment = "dev-aws"

  datadog_enabled       = true
  datadog_agent_enabled = true
  datadog_api_key       = "5d42ff397041a44f9396a933acc4360f"
  cloud_provider        = "aws"

  nginx_ingress_enabled              = false
  cert_manager_service_account_email = "joaquin@langchain.dev"

  external_secrets_enabled    = false
  keda_enabled                = false
  velero_enabled              = false
  external_dns_enabled        = false
  clickhouse_operator_enabled = false

  clickhouse_host     = "clickhouse-replicated.ch-operator.svc.cluster.local"
  clickhouse_password = "password"
  clickhouse_user     = "default"
  clickhouse_port     = 9000
  clickhouse_tls      = false
  redis_hosts         = [module.redis.instance_info]
}
