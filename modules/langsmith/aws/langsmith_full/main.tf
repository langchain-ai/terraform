locals {
  identifier    = "full" # Update these local variables for your use case if needed.
  vpc_name      = "langsmith-vpc-${local.identifier}"
  cluster_name  = "langsmith-eks-${local.identifier}"
  redis_name    = "langsmith-redis-${local.identifier}"
  bucket_name   = "langsmith-s3-${local.identifier}"
  postgres_name = "langsmith-postgres-${local.identifier}"

  region = "us-west-2"

  vpc_id          = var.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  private_subnets = var.create_vpc ? module.vpc[0].private_subnets : var.private_subnets
  public_subnets  = var.create_vpc ? module.vpc[0].public_subnets : var.public_subnets
  vpc_cidr_block  = var.create_vpc ? module.vpc[0].vpc_cidr_block : var.vpc_cidr_block
}

provider "aws" {
  region = local.region
}

# You may want to keep the terraform state in S3 instead of locally
# terraform {
#   backend "s3" {
#     bucket         = "langsmith-terraform-state-bucket"
#     key            = "envs/dev/terraform.tfstate"  # customize as needed
#     region         = "us-west-2"
#     encrypt        = true
#   }
# }

module "vpc" {
  source = "../submodules/vpc"

  count        = var.create_vpc ? 1 : 0
  vpc_name     = local.vpc_name
  cluster_name = local.cluster_name
}

module "eks" {
  source       = "../submodules/eks"
  cluster_name = local.cluster_name
  vpc_id       = local.vpc_id
  subnet_ids   = concat(local.private_subnets, local.public_subnets)
}

module "redis" {
  source        = "../submodules/redis"
  name          = local.redis_name
  vpc_id        = local.vpc_id
  subnet_ids    = local.private_subnets
  instance_type = "cache.m6g.xlarge"
  ingress_cidrs = [local.vpc_cidr_block]
}

module "s3" {
  source      = "../submodules/s3"
  bucket_name = local.bucket_name
  region      = local.region
  vpc_id      = local.vpc_id
}

module "postgres" {
  source        = "../submodules/postgres"
  name          = local.postgres_name
  vpc_id        = local.vpc_id
  subnet_ids    = local.private_subnets
  ingress_cidrs = [local.vpc_cidr_block]

  username = var.postgres_username
  password = var.postgres_password
}
