#------------------------------------------------------------------------------
# Terraform and provider version constraints for this root. The exact
# resolved versions are in .terraform.lock.hcl (gitignored per provider dir).
#   kubernetes  namespaces, StatefulSets, Services, Secrets, NetworkPolicies, Jobs
#   helm        upstream charts (metrics-server, MetalLB, Envoy Gateway) and
#               the small local charts that hold their custom resources
#   random      generated datastore passwords and S3 keys
#------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
