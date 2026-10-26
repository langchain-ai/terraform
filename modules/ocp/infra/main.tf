terraform {
  required_version = ">= 1.11.0"

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

# Writes langsmith-postgres / langsmith-redis, the two secrets the chart reads via
# postgres.external.existingSecretName and redis.external.existingSecretName. Both
# are skipped when their URL is empty; helm/scripts/generate-secrets.sh can create
# them instead, and always owns the application-level langsmith-secrets.
module "secrets" {
  source = "./modules/secrets"

  postgres_connection_url = var.postgres_connection_url
  redis_connection_url    = var.redis_connection_url
}

module "dns" {
  source = "./modules/dns"

  hostname = var.hostname
}
