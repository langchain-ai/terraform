terraform {
  required_version = ">= 1.11.0"

  required_providers {
    # 4.59 is the release on which the two network changes the guard permits are
    # in-place updates rather than replacements: 4.58.0 made network_data_plane and
    # network_policy updatable to cilium, 4.59.0 added calico to cilium. On an
    # older 4.x, aks_allow_network_upgrade = true would replace the cluster, the
    # outcome the guard exists to stop. (4.27 was the previous floor: the release
    # that accepts Microsoft.Network/applicationGateways as a subnet delegation.)
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.59.0, < 5.0.0"
    }
    # Azure Managed Redis (Microsoft.Cache/redisEnterprise) Balanced SKUs aren't
    # reliably exposed by azurerm yet — the redis module provisions AMR via azapi.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.37.1, < 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
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
