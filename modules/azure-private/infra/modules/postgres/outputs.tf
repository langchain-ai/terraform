output "postgres_id" {
  description = "Resource ID of the PostgreSQL Flexible Server — used by the diagnostics module for diagnostic settings"
  value       = azurerm_postgresql_flexible_server.db.id
}

output "connection_url" {
  description = "The connection URL for the PostgreSQL Flexible Server"
  sensitive   = true
  # urlencode() percent-encodes every URL-reserved character in the password (@ / : ! …)
  # so the userinfo section can't be mis-parsed — same approach the redis module uses.
  # ?sslmode=require — Flexible Server enforces TLS; the chart's example connection
  # string includes this, so make it explicit rather than relying on client defaults.
  value = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${urlencode(azurerm_postgresql_flexible_server.db.administrator_password)}@${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/${var.database_name}?sslmode=require"
}
