terraform {
  required_providers {
    # Reads the existing cluster's securityProfile.workloadIdentity flag, which
    # azurerm doesn't expose. Source must be declared here — it's Azure/azapi,
    # not the default hashicorp/azapi.
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
