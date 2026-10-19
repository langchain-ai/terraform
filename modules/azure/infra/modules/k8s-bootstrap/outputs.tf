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

output "sandbox_juicefs_secret_name" {
  description = "Name of the JuiceFS config Secret, or null when sandboxes are off."
  value       = one(kubernetes_secret_v1.sandbox_juicefs[*].metadata[0].name)
}

output "resource_quota_keys" {
  description = "Resources the namespace ResourceQuota caps. No limits.* with sandboxes on."
  value       = sort(keys(kubernetes_resource_quota_v1.langsmith.spec[0].hard))
}

output "limit_range_default_limits" {
  description = "Default container limits the namespace LimitRange injects, or null with sandboxes on."
  value       = kubernetes_limit_range_v1.langsmith.spec[0].limit[0].default
}

output "platform_backend_node_ingress" {
  description = "Address prefixes and ports the node-subnet NetworkPolicy admits to platform-backend, or null when this module creates none."
  value = one([
    for p in kubernetes_network_policy_v1.platform_backend_from_nodes : {
      cidrs = [for f in p.spec[0].ingress[0].from : f.ip_block[0].cidr]
      ports = [for port in p.spec[0].ingress[0].ports : "${port.protocol}/${port.port}"]
    }
  ])
}

output "smithdb_cache_disk_tags" {
  description = "The tags parameter of the SmithDB cache StorageClass, which the disk CSI driver puts on each disk it creates. null when SmithDB is off or no tags are set."
  value       = var.enable_smithdb ? lookup(kubernetes_storage_class_v1.smithdb_cache[0].parameters, "tags", null) : null
}

output "keda_images" {
  description = "The three images KEDA's pods pull, keyed by name, composed as the chart composes them from keda_image_registry and keda_image_registry_keeps_source_host. Empty when install_keda is false."
  value       = local.keda_images
}

output "keda_helm_sets" {
  description = "The chart values the mirror settings add to the KEDA release, as name = value. Empty without a mirror."
  value       = local.keda_mirror_sets
}

output "keda_image_pull_secret_name" {
  description = "Pull Secret KEDA's pods use, empty without one."
  value       = var.install_keda ? var.keda_image_pull_secret_name : ""
}

output "keda_chart_repository_authenticated" {
  description = "Whether the KEDA chart fetch sends a username and password. False without them or without KEDA."
  value       = var.install_keda && var.keda_chart_repository_username != ""
}

output "langsmith_image_pull_secret_name" {
  description = "Pull Secret attached to the service accounts in the LangSmith namespace, empty without one."
  value       = var.langsmith_image_pull_secret_name
}

output "langsmith_image_pull_secret_service_accounts" {
  description = "The service accounts in the LangSmith namespace that carry langsmith_image_pull_secret_name as imagePullSecrets. Empty without one."
  value       = local.langsmith_image_pull_secret_service_accounts
}
