output "connection_url" {
  value = "rediss://:${azurerm_redis_cache.redis.primary_access_key}@${azurerm_redis_cache.redis.hostname}:6380"
  description = "Redis connection string using TLS"
  sensitive   = true
}
