#------------------------------------------------------------------------------
# Provider requirements for the Cloudflare Tunnel connector (kubernetes).
# Providers are
# configured in the root module only (providers.tf), never here.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
  }
}
