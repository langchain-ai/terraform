# Outputs for AWS Redis Module

output "connection_url" {
  description = "Redis connection URL with TLS and auth token"
  value       = "rediss://:${var.auth_token}@${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
  sensitive   = true
}
