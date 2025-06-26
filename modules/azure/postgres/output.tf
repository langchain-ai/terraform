output "connection_url" {
  description = "The connection URL for the PostgreSQL Flexible Server"
  value       = "postgresql://${azurerm_postgresql_flexible_server.db.administrator_login}:${azurerm_postgresql_flexible_server.db.administrator_password}@${azurerm_postgresql_flexible_server.db.name}.postgres.database.azure.com:5432/${azurerm_postgresql_flexible_server.db.name}"
}
