locals {
  identifier          = "" # Add a unique identifier here if needed. Example: "-prod" or "-staging" or "-${terraform.workspace}"
  resource_group_name = "langsmith-rg${local.identifier}"
  vnet_name           = "langsmith-vnet${local.identifier}"
  aks_name            = "langsmith-aks${local.identifier}"
  postgres_name       = "langsmith-postgres${local.identifier}"
  redis_name          = "langsmith-redis${local.identifier}"
  blob_name           = "langsmith-blob${local.identifier}"

  vnet_id            = var.create_vnet ? module.vnet.vnet_id : var.vnet_id
  aks_subnet_id      = var.create_vnet ? module.vnet.subnet_main_id : var.aks_subnet_id
  postgres_subnet_id = var.create_vnet ? module.vnet.subnet_postgres_id : var.postgres_subnet_id
  redis_subnet_id    = var.create_vnet ? module.vnet.subnet_redis_id : var.redis_subnet_id
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

resource "azurerm_resource_group" "resource_group" {
  name     = local.resource_group_name
  location = var.location
}

module "vnet" {
  source              = "../vnet"
  network_name        = local.vnet_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name

  enable_external_postgres = var.enable_external_postgres
  enable_external_redis    = var.enable_external_redis

  postgres_subnet_address_prefix = var.postgres_subnet_address_prefix
  redis_subnet_address_prefix    = var.redis_subnet_address_prefix
}

module "aks" {
  source              = "../aks"
  cluster_name        = local.aks_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id           = local.aks_subnet_id
  service_cidr        = var.aks_service_cidr
  dns_service_ip      = var.aks_dns_service_ip

  default_node_pool_vm_size   = var.default_node_pool_vm_size
  default_node_pool_max_count = var.default_node_pool_max_count

  additional_node_pools = var.additional_node_pools

  nginx_ingress_enabled = var.nginx_ingress_enabled
}

module "postgres" {
  source              = "../postgres"
  name                = local.postgres_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  vnet_id             = local.vnet_id
  subnet_id           = local.postgres_subnet_id

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
}

module "redis" {
  source              = "../redis"
  name                = local.redis_name
  location            = var.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id           = local.redis_subnet_id
  capacity            = var.redis_capacity
}

module "blob" {
  source               = "../blob"
  storage_account_name = local.blob_name
  container_name       = "${local.blob_name}-container"
  location             = var.location
  resource_group_name  = azurerm_resource_group.resource_group.name

  ttl_enabled    = var.blob_ttl_enabled
  ttl_short_days = var.blob_ttl_short_days
  ttl_long_days  = var.blob_ttl_long_days

  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  langsmith_namespace = var.langsmith_namespace

  depends_on = [
    module.aks
  ]
}
