#------------------------------------------------------------------------------
# Provider requirements for metrics-server (helm). Providers are
# configured in the root module only (providers.tf), never here.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}
