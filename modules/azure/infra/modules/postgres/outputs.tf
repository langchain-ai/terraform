output "postgres_id" {
  description = "Resource ID of the PostgreSQL Flexible Server — used by the diagnostics module for diagnostic settings"
  value       = azurerm_postgresql_flexible_server.db.id
}

output "connection_url" {
  description = "The connection URL for the PostgreSQL Flexible Server"
  # replace() percent-encodes special characters that are invalid in URL userinfo.
  # ! (\x21) must be %21 — Go's net/url parser rejects bare ! or backslash-escaped \! in passwords.
  value = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${replace(azurerm_postgresql_flexible_server.db.administrator_password, "!", "%21")}@${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/${var.database_name}"
}
