# Outputs for AWS Redis Module

output "connection_url" {
  description = "Redis connection URL with TLS"
  value = (
    var.auth_token == null || var.auth_token == ""
    ? "rediss://${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
    : "rediss://:${var.auth_token}@${aws_elasticache_replication_group.redis.primary_endpoint_address}:6379"
  )
  sensitive = true
}

output "host" {
  description = "Redis primary endpoint host"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "port" {
  description = "Redis port"
  value       = 6379
}
