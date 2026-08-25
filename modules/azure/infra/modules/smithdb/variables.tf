variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "vnet_id" { type = string }
variable "subnet_id" { type = string }
variable "aks_subnet_id" { type = string }
variable "oidc_issuer_url" { type = string }
variable "namespace" { type = string }
variable "service_account_name" { type = string }
variable "metastore_admin_username" { type = string }
variable "metastore_admin_password" {
  type      = string
  sensitive = true
  default   = null
  nullable  = true
}
variable "metastore_sku_name" { type = string }
variable "metastore_storage_mb" { type = number }
variable "metastore_backup_retention_days" { type = number }
variable "private_dns_zone_id" {
  type     = string
  default  = null
  nullable = true
}
variable "storage_account_name" { type = string }
variable "container_name" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
