locals {
  # Feel free to update these local variables for your use case if needed.
  identifier    = var.identifier
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

module "vpc" {
  source = "../vpc"

  count        = var.create_vpc ? 1 : 0
  vpc_name     = local.vpc_name
  cluster_name = local.cluster_name
}

module "eks" {
  source              = "../eks"
  cluster_name        = local.cluster_name
  vpc_id              = local.vpc_id
  subnet_ids          = concat(local.private_subnets, local.public_subnets)
  tags                = var.eks_tags
  patch_storage_class = var.patch_storage_class
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
