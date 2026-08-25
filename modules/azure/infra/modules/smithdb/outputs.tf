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

output "metastore_auth_mode" {
  description = "SmithDB metastore authentication mode: entra or password."
  value       = local.use_entra_auth ? "entra" : "password"
}

output "metastore_username" {
  description = "Username SmithDB uses to connect to the metastore."
  value       = local.use_entra_auth ? azurerm_user_assigned_identity.smithdb.name : var.metastore_admin_username
}
