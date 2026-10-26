locals {
  # urlencode() uses "+" for spaces, but URI userinfo requires "%20".
  postgres_login_uri_encoded    = replace(urlencode(azurerm_postgresql_flexible_server.db.administrator_login), "+", "%20")
  postgres_password_uri_encoded = replace(urlencode(azurerm_postgresql_flexible_server.db.administrator_password), "+", "%20")
}

output "postgres_id" {
  description = "Resource ID of the PostgreSQL Flexible Server — used by the diagnostics module for diagnostic settings"
  value       = azurerm_postgresql_flexible_server.db.id
}

output "private_dns_zone_id" {
  description = "Resource ID of the private PostgreSQL DNS zone: the one this module created, or the one supplied."
  value       = local.private_dns_zone_id
}

output "connection_url" {
  description = "The connection URL for the PostgreSQL Flexible Server"
  value       = "postgresql://${local.postgres_login_uri_encoded}:${local.postgres_password_uri_encoded}@${azurerm_postgresql_flexible_server.db.fqdn}:5432/${var.database_name}"
}

# Connection URL for the standalone Fleet database. Same server, dedicated
# langsmith_fleet DB. sslmode=require matches the AWS/GCP fleet URLs (the app
# connection_url above omits it, relying on the chart's default). Empty string
# when enable_fleet = false so it's never emitted as an unused credential URL.
output "fleet_connection_url" {
  description = "The connection URL for the standalone Fleet database (langsmith_fleet)"
  sensitive   = true
  value       = var.enable_fleet ? "postgresql://${local.postgres_login_uri_encoded}:${local.postgres_password_uri_encoded}@${azurerm_postgresql_flexible_server.db.fqdn}:5432/langsmith_fleet?sslmode=require" : ""
}

output "private_dns_zone_name" {
  description = "Name of the private PostgreSQL DNS zone."
  value       = local.private_dns_zone_name
}

output "private_dns_zone_created" {
  description = "Whether this module created the server's private DNS zone and its VNet link (false when a central zone was supplied)."
  value       = local.create_private_dns_zone
}

output "server_private_dns_zone_id" {
  description = "The private DNS zone ID the Flexible Server is configured with."
  value       = azurerm_postgresql_flexible_server.db.private_dns_zone_id
}

output "customer_managed_key" {
  description = "The server's customer_managed_key block as configured (key_vault_key_id, primary_user_assigned_identity_id, geo_backup_key_vault_key_id, geo_backup_user_assigned_identity_id); null under the service-managed key."
  value       = one(azurerm_postgresql_flexible_server.db.customer_managed_key[*])
}

output "identity_ids" {
  description = "User-assigned identities assigned to the server for its customer-managed keys; empty under the service-managed key."
  value       = try(azurerm_postgresql_flexible_server.db.identity[0].identity_ids, toset([]))
}
