output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = kubernetes_namespace_v1.langsmith.metadata[0].name
}

output "keda_namespace" {
  description = "Kubernetes namespace where KEDA is deployed"
  value       = helm_release.keda.namespace
}

output "postgres_secret_name" {
  description = "Name of the Kubernetes secret holding the PostgreSQL connection URL"
  value       = var.use_external_postgres ? kubernetes_secret_v1.postgres[0].metadata[0].name : null
}

output "redis_secret_name" {
  description = "Name of the Kubernetes secret holding the Redis connection URL"
  value       = var.use_external_redis ? kubernetes_secret_v1.redis[0].metadata[0].name : null
}

output "nginx_ingress_values" {
  description = "The rendered Helm values string for the NGINX ingress controller. Used by tests to assert the internal-LB annotation is present."
  value       = helm_release.nginx_ingress.values[0]
}
