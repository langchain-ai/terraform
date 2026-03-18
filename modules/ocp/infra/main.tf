terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = local.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = local.kubeconfig_path
    config_context = local.kube_context
  }
}

module "networking" {
  source = "./modules/networking"
}

module "k8s_cluster" {
  source = "./modules/k8s-cluster"
}

module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"
}

module "postgres" {
  source = "./modules/postgres"
}

module "redis" {
  source = "./modules/redis"
}

module "storage" {
  source = "./modules/storage"
}

module "scc" {
  source = "./modules/scc"
}

module "secrets" {
  source = "./modules/secrets"

  postgres_password = module.postgres.password
  redis_password    = module.redis.password
}

module "dns" {
  source = "./modules/dns"

  hostname = var.hostname
}
