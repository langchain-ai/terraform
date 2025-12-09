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
  source                   = "../eks"
  cluster_name             = local.cluster_name
  cluster_version          = var.eks_cluster_version
  vpc_id                   = local.vpc_id
  subnet_ids               = concat(local.private_subnets, local.public_subnets)
  tags                     = var.eks_tags
  create_gp3_storage_class = var.create_gp3_storage_class
  eks_managed_node_groups  = var.eks_managed_node_groups
  public_cluster_enabled   = var.enable_public_eks_cluster

  # IRSA settings
  create_langsmith_irsa_role = var.create_langsmith_irsa_role
}

module "redis" {
  source        = "../redis"
  name          = local.redis_name
  vpc_id        = local.vpc_id
  subnet_ids    = local.private_subnets
  instance_type = var.redis_instance_type
  ingress_cidrs = [local.vpc_cidr_block]
}

module "s3" {
  source      = "../s3"
  bucket_name = local.bucket_name
  region      = var.region
  vpc_id      = local.vpc_id
}

module "postgres" {
  source         = "../postgres"
  identifier     = local.postgres_name
  vpc_id         = local.vpc_id
  subnet_ids     = local.private_subnets
  ingress_cidrs  = [local.vpc_cidr_block]
  instance_type  = var.postgres_instance_type
  storage_gb     = var.postgres_storage_gb
  max_storage_gb = var.postgres_max_storage_gb

  username = var.postgres_username
  password = var.postgres_password

  iam_database_authentication_enabled = var.postgres_iam_database_authentication_enabled
  iam_database_user                   = var.postgres_iam_database_user
  iam_auth_role_name                  = module.eks.langsmith_irsa_role_name

  depends_on = [module.eks]
}
