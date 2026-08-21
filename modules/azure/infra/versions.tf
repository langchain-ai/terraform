terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # 4.27 is the release that accepts Microsoft.Network/applicationGateways as a
    # subnet service_delegation name, which the AGIC subnet needs. Older 4.x rejects
    # it during validation, before any API call.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.27.0, < 5.0.0"
    }
    # Azure Managed Redis (Microsoft.Cache/redisEnterprise) Balanced SKUs aren't
    # reliably exposed by azurerm yet — the redis module provisions AMR via azapi.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    # Required by the keyvault module for RBAC propagation wait
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}
