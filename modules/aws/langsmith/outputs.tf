output "postgres_connection_url" {
  value     = module.postgres.connection_url
  sensitive = true
}

output "redis_connection_url" {
  value     = module.redis.connection_url
  sensitive = true
}
