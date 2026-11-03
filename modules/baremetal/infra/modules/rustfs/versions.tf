#------------------------------------------------------------------------------
# Provider requirements for RustFS (S3-compatible object storage) (kubernetes,
# random). Providers are
# configured in the root module only (providers.tf), never here.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
