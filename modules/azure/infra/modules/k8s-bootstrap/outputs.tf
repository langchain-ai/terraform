output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = kubernetes_namespace_v1.langsmith.metadata[0].name
}

output "cert_manager_namespace" {
  description = "Kubernetes namespace where cert-manager is deployed, or null when this module did not install it"
  value       = one(helm_release.cert_manager[*].namespace)
}

output "cert_manager_feature_gates" {
  description = "featureGates set on the cert-manager release, empty with none, or null when this module did not install cert-manager"
  value       = one([for r in helm_release.cert_manager : join(",", [for s in r.set : s.value if s.name == "featureGates"])])
}

output "keda_namespace" {
  description = "Kubernetes namespace where KEDA is deployed, or null when this module did not install it"
  value       = one(helm_release.keda[*].namespace)
}

output "postgres_secret_name" {
  description = "Name of the Kubernetes secret holding the PostgreSQL connection URL"
  value       = var.use_external_postgres ? kubernetes_secret_v1.postgres[0].metadata[0].name : null
}

output "redis_secret_name" {
  description = "Name of the Kubernetes secret holding the Redis connection URL"
  value       = var.use_external_redis ? kubernetes_secret_v1.redis[0].metadata[0].name : null
}

output "smithdb_metastore_secret_name" {
  description = "Name of the Kubernetes Secret holding the SmithDB metastore connection fields."
  value       = var.enable_smithdb ? kubernetes_secret_v1.smithdb_metastore[0].metadata[0].name : null
}

output "smithdb_cache_storage_class_name" {
  description = "Name of the Premium SSD v2 StorageClass for SmithDB cache volumes."
  value       = var.enable_smithdb ? kubernetes_storage_class_v1.smithdb_cache[0].metadata[0].name : null
}
