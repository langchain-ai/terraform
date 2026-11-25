#------------------------------------------------------------------------------
# Provider requirements for MetalLB in L2 mode (kubernetes, helm). Providers are
# configured in the root module only (providers.tf), never here.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}
