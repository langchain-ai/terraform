// MIT License - Copyright (c) 2026 LangChain, Inc.
// NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
// See LICENSE at the root of this repository for full license text.

// existing-aks-cluster — a stand-in for a cluster and network the customer already
// runs, so the LangSmith module's attach path (create_cluster = false,
// create_vnet = false) can be tested end to end. This is test scaffolding, not part
// of the product. It builds the customer's half of the picture, which the LangSmith
// module never creates and nothing else in this repo does either.
//
// Everything lands in one resource group, so `az group delete` is a complete
// teardown even if this state file is lost.
//
// Each setting below is here because a precondition in ../../infra/main.tf or a
// postcondition in ../../infra/modules/k8s-cluster/main.tf rejects the plan
// without it. The comments name the check.

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}

  // Every provider the module needs is already registered on the subscription,
  // and registration requires rights the test identity may not hold.
  resource_provider_registrations = "none"
}

locals {
  tags = {
    purpose   = "existing-aks-cluster-test"
    owner     = var.owner
    ephemeral = "true"
  }
}

resource "azurerm_resource_group" "prereq" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = local.tags
}

// ── The cluster owner's VNet ────────────────────────────────────────────────
// Deliberately not 10.0.0.0/16. The module's default carve prefixes all sit in
// 10.0.x, so a distinct range proves the attach path reads real subnet IDs rather
// than falling through to a default that happens to match.
resource "azurerm_virtual_network" "customer" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.prereq.location
  resource_group_name = azurerm_resource_group.prereq.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

// AKS nodes and pods. Azure CNI is flat here, so both draw IPs from this subnet:
// infra/main.tf computes (max_count + 1) * (max_pods + 1) and the precondition at
// infra/main.tf:340 rejects anything under that. A /22 gives 1019 usable, which
// covers the 764 the module's bare defaults ask for.
//
// The two service endpoints are mandatory. The blob storage firewall is hardcoded
// default-deny and allowlists this subnet by ID (storage/main.tf:37), and Azure
// rejects a subnet rule whose matching endpoint is absent.
resource "azurerm_subnet" "aks" {
  name                 = "aks-nodes"
  resource_group_name  = azurerm_resource_group.prereq.name
  virtual_network_name = azurerm_virtual_network.customer.name
  address_prefixes     = [var.aks_subnet_prefix]
  service_endpoints    = ["Microsoft.Storage", "Microsoft.KeyVault"]
}

// Postgres Flexible Server is subnet-injected and needs the delegation. Checked
// through azapi at infra/main.tf:239 because the azurerm subnet data source does
// not expose delegations, then enforced at infra/main.tf:307.
resource "azurerm_subnet" "postgres" {
  name                 = "postgres"
  resource_group_name  = azurerm_resource_group.prereq.name
  virtual_network_name = azurerm_virtual_network.customer.name
  address_prefixes     = [var.postgres_subnet_prefix]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

// Azure Managed Redis is reached through a private endpoint, not subnet
// injection, so this subnet must NOT be delegated — a delegated subnet accepts
// only its delegated service. Nothing in the module validates that, so getting it
// wrong surfaces as an apply-time failure on azurerm_private_endpoint.redis.
//
// private_endpoint_network_policies must stay Disabled for the same reason, and
// the module does not check that either.
resource "azurerm_subnet" "redis" {
  name                              = "redis"
  resource_group_name               = azurerm_resource_group.prereq.name
  virtual_network_name              = azurerm_virtual_network.customer.name
  address_prefixes                  = [var.redis_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

// ── The cluster LangSmith will attach to ─────────────────────────────────────
resource "azurerm_kubernetes_cluster" "customer" {
  name                = "${var.name_prefix}-aks"
  location            = azurerm_resource_group.prereq.location
  resource_group_name = azurerm_resource_group.prereq.name
  dns_prefix          = var.name_prefix
  kubernetes_version  = var.kubernetes_version
  tags                = local.tags

  // Federated identity credentials for the LangSmith service accounts are built
  // on the OIDC issuer, and the postcondition at k8s-cluster/main.tf:135 reads
  // both flags off the live cluster.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  // The kubernetes and helm providers authenticate with the cluster's kube_config
  // (k8s-bootstrap/main.tf:5). Azure returns that empty for an AAD-only cluster and
  // there is no kubelogin exec path, so disabling local accounts is a hard blocker.
  local_account_disabled = false

  default_node_pool {
    name                 = "default"
    vm_size              = var.node_vm_size
    vnet_subnet_id       = azurerm_subnet.aks.id
    auto_scaling_enabled = true
    min_count            = var.node_min_count
    max_count            = var.node_max_count
    max_pods             = 60
    zones                = var.availability_zones
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    // Azure CNI without overlay, matching what the module creates. Overlay would
    // take pod IPs from a separate space and make the subnet-size check moot.
    network_plugin = "azure"
    // k8s-bootstrap creates kubernetes_network_policy_v1 objects, which a cluster
    // with no policy engine accepts and then never enforces.
    network_policy    = "azure"
    load_balancer_sku = "standard"
    // Must stay clear of the VNet address space: infra/main.tf:357 rejects an
    // overlap, and the module needs this same value passed back as
    // aks_service_cidr even though it ignores it for the cluster itself.
    service_cidr   = var.aks_service_cidr
    dns_service_ip = cidrhost(var.aks_service_cidr, 10)
  }
}
