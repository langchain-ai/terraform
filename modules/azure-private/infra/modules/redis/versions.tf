terraform {
  required_providers {
    # AMR cluster/database are provisioned via azapi (Balanced SKUs not in azurerm yet).
    # Source must be declared here — it's Azure/azapi, not the default hashicorp/azapi.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
