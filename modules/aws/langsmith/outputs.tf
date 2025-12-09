output "postgres_connection_url" {
  value     = module.postgres.connection_url
  sensitive = true
}

output "postgres_iam_connection_url" {
  description = "Connection URL for IAM authentication (no password)."
  value       = module.postgres.iam_connection_url
}

output "redis_connection_url" {
  value     = module.redis.connection_url
  sensitive = true
}

output "cluster_name" {
  value = module.eks.cluster_name
}
