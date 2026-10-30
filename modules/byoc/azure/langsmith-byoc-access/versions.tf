terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # 4.42.0 is the first release with rbac_authorization_enabled on
    # azurerm_key_vault, and it skips the data plane calls on a vault with
    # public network access disabled.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.42.0, < 5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}
