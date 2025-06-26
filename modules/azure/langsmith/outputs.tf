output "postgres_connection_url" {
  sensitive = true
  value     = module.postgres.connection_url
}

output "redis_connection_url" {
  sensitive = true
  value     = module.redis.connection_url
}

output "storage_account_name" {
  value = module.blob.storage_account_name
}

output "storage_container_name" {
  value = module.blob.container_name
}

output "storage_account_connection_string" {
  sensitive = true
  value     = module.blob.connection_string
}
