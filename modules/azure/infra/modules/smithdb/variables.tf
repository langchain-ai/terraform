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
variable "blob_private_endpoint_enabled" {
  type        = bool
  description = "Reach the object store over a Private Endpoint and turn off its public endpoint. The container is created through Azure Resource Manager, so provisioning is unaffected."
  default     = false
}
variable "blob_private_endpoint_subnet_id" {
  type        = string
  description = "Subnet that holds the object-store Private Endpoint. Required when blob_private_endpoint_enabled is true."
  default     = ""
}
variable "blob_private_dns_zone_id" {
  type        = string
  description = "privatelink.blob.core.windows.net zone the object-store endpoint registers in. Owned by the root module because both storage accounts share one zone. Not the metastore zone, which is private_dns_zone_id above."
  default     = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}
