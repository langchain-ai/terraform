output "postgres_secret_name" {
  description = "Name of the Kubernetes secret holding the Postgres connection URL (postgres.external.existingSecretName), or null when Terraform does not manage it"
  value       = one(kubernetes_secret.postgres[*].metadata[0].name)
}

output "redis_secret_name" {
  description = "Name of the Kubernetes secret holding the Redis connection URL (redis.external.existingSecretName), or null when Terraform does not manage it"
  value       = one(kubernetes_secret.redis[*].metadata[0].name)
}
