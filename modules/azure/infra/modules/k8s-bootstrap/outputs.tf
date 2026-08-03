output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = kubernetes_namespace_v1.langsmith.metadata[0].name
}

output "cert_manager_namespace" {
  description = "Kubernetes namespace where cert-manager is deployed, or null when this module did not install it"
  value       = var.install_cert_manager ? one(helm_release.cert_manager[*].namespace) : null
}

output "keda_namespace" {
  description = "Kubernetes namespace where KEDA is deployed, or null when this module did not install it"
  value       = var.install_keda ? one(helm_release.keda[*].namespace) : null
}

output "postgres_secret_name" {
  description = "Name of the Kubernetes secret holding the PostgreSQL connection URL"
  value       = var.use_external_postgres ? kubernetes_secret_v1.postgres[0].metadata[0].name : null
}

output "redis_secret_name" {
  description = "Name of the Kubernetes secret holding the Redis connection URL"
  value       = var.use_external_redis ? kubernetes_secret_v1.redis[0].metadata[0].name : null
}
