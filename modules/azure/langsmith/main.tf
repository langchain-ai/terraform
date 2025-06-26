locals {
  identifier = "-joaquin"
  resource_group_name = "langsmith-rg${identifier}"
  vnet_name = "langsmith-vnet${identifier}"
  aks_name = "langsmith-aks${identifier}"
  postgres_name = "langsmith-postgres${identifier}"
  redis_name = "langsmith-redis${identifier}"
  blob_name = "langsmith-blob${identifier}"

  location = "westus2"
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "resource_group" {
  name     = local.resource_group_name
  location = local.location
}

module "vnet" {
  source = "../vnet"
  network_name = local.vnet_name
  location = local.location
  resource_group_name = azurerm_resource_group.resource_group.name

  enable_external_postgres = var.enable_external_postgres
  enable_external_redis = var.enable_external_redis
}

module "aks" {
  source = "../aks"
  cluster_name = local.aks_name
  location = local.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id = module.vnet.subnet_main_id
}

module "postgres" {
  source = "../postgres"
  name = local.postgres_name
  location = local.location
  resource_group_name = azurerm_resource_group.resource_group.name
  vnet_id = module.vnet.vnet_id
  subnet_id = module.vnet.subnet_postgres_id

  admin_username = var.postgres_admin_username
  admin_password = var.postgres_admin_password
}

module "redis" {
  source = "../redis"
  name = local.redis_name
  location = local.location
  resource_group_name = azurerm_resource_group.resource_group.name
  subnet_id = module.vnet.subnet_redis_id
  capacity = var.redis_capacity

  enable_redis_cluster = var.enable_redis_cluster
  redis_cluster_sku_name = var.redis_cluster_sku_name
}

module "blob" {
  source = "../blob"
  storage_account_name = local.blob_name
  container_name = "${local.blob_name}-container"
  location = local.location
  resource_group_name = azurerm_resource_group.resource_group.name

  ttl_enabled = var.blob_ttl_enabled
  ttl_short_days = var.blob_ttl_short_days
  ttl_long_days = var.blob_ttl_long_days
}
