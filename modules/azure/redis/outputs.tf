output "connection_url" {
  value = azurerm_redis_cache.redis.primary_connection_string
}
