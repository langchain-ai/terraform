locals {
  # urlencode() uses "+" for spaces, but URI userinfo requires "%20".
  postgres_password_uri_encoded = replace(urlencode(azurerm_postgresql_flexible_server.db.administrator_password), "+", "%20")
}

output "postgres_id" {
  description = "Resource ID of the PostgreSQL Flexible Server — used by the diagnostics module for diagnostic settings"
  value       = azurerm_postgresql_flexible_server.db.id
}

output "connection_url" {
  description = "The connection URL for the PostgreSQL Flexible Server"
  value       = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${local.postgres_password_uri_encoded}@${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/${var.database_name}"
}

# Connection URL for the standalone Fleet database. Same server, dedicated
# langsmith_fleet DB. sslmode=require matches the AWS/GCP fleet URLs (the app
# connection_url above omits it, relying on the chart's default). Empty string
# when enable_fleet = false so it's never emitted as an unused credential URL.
output "fleet_connection_url" {
  description = "The connection URL for the standalone Fleet database (langsmith_fleet)"
  sensitive   = true
  value       = var.enable_fleet ? "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${local.postgres_password_uri_encoded}@${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/langsmith_fleet?sslmode=require" : ""
}
