#------------------------------------------------------------------------------
# What this root hands to the next steps and to you. init-values.sh and
# deploy.sh read langsmith_helm_values, smithdb_helm_values, values_files
# (helm_values.tf) and features; the rest describe what was built: the budget
# breakdown, add-on releases, StorageClasses, the MetalLB pool, the Gateway, the
# tunnel, where each datastore lives and how it is sized, and the images and
# charts installed outside LangSmith's. Every value but the add-ons' comes from
# modules/values. Outputs carry Secret names, never secret values.
#------------------------------------------------------------------------------

output "langsmith_admin_email" {
  description = "Initial LangSmith organization admin email used in Helm values (empty: from infra/.secrets.env)"
  value       = var.langsmith_admin_email
}

output "budget" {
  description = "Requested resources for sizing_profile vs the ceiling from cluster_nodes (no secrets)."
  value       = module.values.budget
}

output "metrics_server" {
  description = "metrics-server Helm release."
  value       = var.install_metrics_server ? module.metrics_server[0].release : null
}

output "storage_classes" {
  description = "StorageClasses: delete (default) and retain (datastores); the cluster's own when install_local_path = false."
  value = {
    default   = module.values.storage_classes.delete
    retain    = module.values.storage_classes.retain
    node_path = var.install_local_path ? module.local_path[0].node_path : null
  }
}

output "metallb" {
  description = "MetalLB LoadBalancer IP pool."
  value = var.install_metallb ? {
    namespace = module.metallb[0].namespace
    addresses = module.metallb[0].addresses
  } : null
}

output "gateway" {
  description = "Gateway the LangSmith chart attaches HTTPRoutes to (gateway.name / gateway.namespace) and its LAN IP."
  value       = local.gateway
}

output "cloudflare_tunnel" {
  description = "Cloudflare Tunnel connector. Paste origin_service_url as the public hostname's service (type HTTP) in the dashboard."
  value = {
    enabled            = var.enable_cloudflare_tunnel
    namespace          = var.enable_cloudflare_tunnel ? module.cloudflared[0].namespace : null
    origin_service_url = var.install_envoy_gateway ? module.envoy_gateway[0].proxy_service.url : null
    lan_route          = var.langsmith_domain != ""
  }
}

output "postgres" {
  description = "Postgres instances (no passwords; read them from the Secrets)."
  value = {
    langsmith = var.postgres_source == "external" ? { host = null, database = null, secret = "langsmith/${var.postgres_secret}" } : { host = module.values.postgres.langsmith.host, database = module.values.postgres.langsmith.database, secret = "langsmith/${kubernetes_secret_v1.langsmith_postgres[0].metadata[0].name}" }
    smithdb   = { host = var.smithdb_metastore_source == "external" ? null : module.values.postgres.smithdb.host, database = var.smithdb_metastore_source == "external" ? null : module.values.postgres.smithdb.database, secret = "langsmith/${kubernetes_secret_v1.smithdb_config.metadata[0].name}" }
  }
}

output "redis" {
  description = "Redis instance (no password; read it from the Secret)."
  value = {
    langsmith = var.redis_source == "external" ? { host = null, maxmemory_mb = null, secret = "langsmith/${var.redis_secret}" } : { host = module.values.redis.langsmith.host, maxmemory_mb = module.values.redis.langsmith.maxmemory_mb, secret = "langsmith/${kubernetes_secret_v1.langsmith_redis[0].metadata[0].name}" }
  }
}

output "object_store" {
  description = "SmithDB object store (no keys; they're in the smithdb-config Secret)."
  value = {
    endpoint = module.values.object_store.endpoint
    bucket   = module.values.object_store.smithdb
    buckets  = var.object_store_source == "external" ? [module.values.object_store.smithdb, module.values.object_store.blobs] : module.values.rustfs.buckets
    secret   = "langsmith/${kubernetes_secret_v1.smithdb_config.metadata[0].name}"
  }
}

output "features" {
  description = "Enabled features and their wiring (init-values.sh / deploy.sh read this; no secrets)."
  value       = module.values.features
}

output "pods" {
  description = "Every pod the budget counts, as numbers: name, pool, replicas, cpu_n (cores), mem_gi, disk_gi. The datastores Terraform creates are here and nowhere in the chart, so a tool checking where each pod fits reads them from this. No secrets."
  value       = module.values.pods
}

output "datastore_values" {
  description = "The values charts/datastores is installed with, as YAML, without the passwords and S3 keys (a second values file holds those): what a customer applying the chart with their own Helm or Argo CD starts from."
  value       = yamlencode(module.values.datastore_values)
}

output "datastore_secrets" {
  description = "The Secrets LangSmith's namespace must hold before Helm runs, space-separated: the module's, or the customer's for each store they run. deploy.sh checks each."
  value       = join(" ", module.values.datastore_secrets)
}

output "datastore_sizes" {
  description = "The datastores' size table (modules/values/datastore-sizes.yaml) as read: each profile's stores, the products' increments on the shared instances, and the JuiceFS Redis. No secrets."
  value       = module.values.datastore_sizes
}

output "datastores" {
  description = "The in-cluster stores: their namespace, the label selecting each instance, every instance with its host and port, the Secrets LangSmith reads them through with their keys, the buckets, and each product's Redis database. No secrets."
  value       = module.values.datastores
}

output "images" {
  description = "Every image the module runs outside the LangSmith chart, by role: what a registry mirror must carry besides the chart's."
  value       = module.values.images
}

output "operator_charts" {
  description = "The datastore operators' Helm charts (release, repository, chart, version, namespace), installed before the datastores chart with datastore_runtime = operator."
  value       = module.values.operator_charts
}
