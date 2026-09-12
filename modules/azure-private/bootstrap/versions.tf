terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
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
  }
}

# AzureRM provider — subscription scoped to var.subscription_id.
# Kubernetes and Helm providers are configured inside the k8s-bootstrap module
# (fed from the AKS data source), so they are not declared at the root level.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
