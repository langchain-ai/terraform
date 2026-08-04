terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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
