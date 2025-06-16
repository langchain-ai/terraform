locals {
  base_name    = "langsmith-min"
  vpc_name     = "${local.base_name}-vpc"
  cluster_name = "${local.base_name}-eks"
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
  source       = "../submodules/vpc"
  vpc_name     = local.vpc_name
  cluster_name = local.cluster_name
}

module "eks" {
  source       = "../submodules/eks"
  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = concat(module.vpc.private_subnets, module.vpc.public_subnets)
}
