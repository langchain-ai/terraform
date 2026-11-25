output "metastore_host" {
  description = "Private hostname of the SmithDB PostgreSQL metastore."
  value       = azurerm_postgresql_flexible_server.metastore.fqdn
}

output "metastore_database" {
  description = "Database name of the SmithDB metastore."
  value       = azurerm_postgresql_flexible_server_database.metastore.name
}

output "storage_account_name" {
  description = "Name of the SmithDB object-store Storage Account."
  value       = azurerm_storage_account.smithdb.name
}

output "container_name" {
  description = "Name of the SmithDB object-store Blob container."
  value       = azapi_resource.smithdb_container.name
}

output "workload_identity_client_id" {
  description = "Client ID of the SmithDB user-assigned identity."
  value       = azurerm_user_assigned_identity.smithdb.client_id
}

output "workload_identity_principal_id" {
  description = "Principal ID of the SmithDB user-assigned identity."
  value       = azurerm_user_assigned_identity.smithdb.principal_id
}

output "metastore_auth_mode" {
  description = "SmithDB metastore authentication mode: entra or password."
  value       = local.use_entra_auth ? "entra" : "password"
}

output "metastore_username" {
  description = "Username SmithDB uses to connect to the metastore."
  value       = local.use_entra_auth ? azurerm_user_assigned_identity.smithdb.name : var.metastore_admin_username
}

output "storage_blob_endpoint" {
  description = "Blob service endpoint of the SmithDB object-store account, as Azure reports it for this cloud."
  value       = azurerm_storage_account.smithdb.primary_blob_endpoint
}

output "storage_replication_type" {
  description = "Replication the SmithDB account is planned or created with."
  value       = azurerm_storage_account.smithdb.account_replication_type
}

output "metastore_private_dns_zone_created" {
  description = "Whether this module created a private DNS zone for the metastore (false when it shares LangSmith's server zone or a supplied central zone)."
  value       = local.create_private_dns_zone
}

output "metastore_private_dns_zone_id" {
  description = "The private DNS zone ID the metastore Flexible Server is configured with."
  value       = azurerm_postgresql_flexible_server.metastore.private_dns_zone_id
}

output "storage_shared_access_key_enabled" {
  description = "Whether the SmithDB account accepts Shared Key authorization, as planned or created."
  value       = azurerm_storage_account.smithdb.shared_access_key_enabled
}

output "storage_allowed_copy_scope" {
  description = "Which accounts copy operations into the SmithDB account may source from; null means any."
  value       = azurerm_storage_account.smithdb.allowed_copy_scope
}

output "metastore_customer_managed_key" {
  description = "The metastore's customer_managed_key block as configured (key_vault_key_id, primary_user_assigned_identity_id); null under the service-managed key."
  value = one([for k in azurerm_postgresql_flexible_server.metastore.customer_managed_key : {
    key_vault_key_id                  = k.key_vault_key_id
    primary_user_assigned_identity_id = k.primary_user_assigned_identity_id
  }])
}

output "metastore_identity_ids" {
  description = "User-assigned identities assigned to the metastore for its customer-managed key; empty under the service-managed key."
  value       = try(azurerm_postgresql_flexible_server.metastore.identity[0].identity_ids, toset([]))
}

output "storage_customer_managed_key" {
  description = "The SmithDB storage account's customer_managed_key block as configured (key_vault_key_id, user_assigned_identity_id); null under the service-managed key."
  # The two fields by name, as in the blob module: the whole block also carries
  # the deprecated managed_hsm_key_id, which warns on every plan when read.
  value = one([for k in azurerm_storage_account.smithdb.customer_managed_key : {
    key_vault_key_id          = k.key_vault_key_id
    user_assigned_identity_id = k.user_assigned_identity_id
  }])
}

output "storage_identity_ids" {
  description = "User-assigned identities assigned to the SmithDB storage account for its customer-managed key; empty under the service-managed key."
  value       = try(azurerm_storage_account.smithdb.identity[0].identity_ids, toset([]))
}
