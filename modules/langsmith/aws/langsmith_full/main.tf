locals {
  vpc_name = "langsmith-vpc-full"
  cluster_name = "langsmith-eks-full"
  redis_name = "langsmith-redis-full"
}

provider "aws" {
  region = "us-west-2"
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
  vpc_name = local.vpc_name
  cluster_name = local.cluster_name
}

module "eks" {
  source = "../submodules/eks"
  cluster_name = local.cluster_name
  vpc_id = module.vpc.vpc_id
  subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)
}

module "redis" {
    source = "../submodules/redis"
    name = local.redis_name
    vpc_id = module.vpc.vpc_id
    subnet_ids = module.vpc.private_subnets
    instance_type = "cache.m6g.16xlarge"
    ingress_cidrs = [module.vpc.vpc_cidr_block]
}

# module "postgres" {
#     source = "../postgres"
# }

# module "s3" {
#     source = "../s3"
# }
