terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    # kubectl provider is used for ESO CRD-backed resources (ClusterSecretStore,
    # ExternalSecret). Unlike kubernetes_manifest, kubectl_manifest defers schema
    # validation to apply time — plan succeeds even before ESO CRDs are installed.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
