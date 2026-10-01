terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # 4.65 adds user_assigned_identity_id to azurerm_federated_identity_credential.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.65.0, < 5.0.0"
    }
  }
}
