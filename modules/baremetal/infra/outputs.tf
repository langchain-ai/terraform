#------------------------------------------------------------------------------
# What this root hands to the next steps and to you. init-values.sh and
# deploy.sh read langsmith_helm_values, smithdb_helm_values (helm_values.tf)
# and features; the rest describe what was built: the budget breakdown, add-on
# releases, StorageClasses, the MetalLB pool, the Gateway, the tunnel, and
# where each datastore lives. Outputs carry Secret names, never secret values.
#------------------------------------------------------------------------------

output "budget" {
  description = "Requested resources for sizing_profile vs the ceiling from cluster_nodes (no secrets)."
  value       = local.budget_summary
}

output "metrics_server" {
  description = "metrics-server Helm release."
  value       = module.metrics_server.release
}

output "storage_classes" {
  description = "local-path StorageClasses: delete (default) and retain (datastores)."
  value = {
    default   = module.local_path.storage_class_delete
    retain    = module.local_path.storage_class_retain
    node_path = module.local_path.node_path
  }
}

output "metallb" {
  description = "MetalLB LoadBalancer IP pool."
  value = {
    namespace = module.metallb.namespace
    addresses = module.metallb.addresses
  }
}

output "gateway" {
  description = "Gateway the LangSmith chart attaches HTTPRoutes to (gateway.name / gateway.namespace) and its LAN IP."
  value       = module.envoy_gateway.gateway
}

output "cloudflare_tunnel" {
  description = "Cloudflare Tunnel connector. Paste origin_service_url as the public hostname's service (type HTTP) in the dashboard."
  value = {
    enabled            = var.enable_cloudflare_tunnel
    namespace          = var.enable_cloudflare_tunnel ? module.cloudflared[0].namespace : null
    origin_service_url = module.envoy_gateway.proxy_service.url
    lan_route          = var.langsmith_domain != ""
  }
}

output "postgres" {
  description = "Postgres instances (no passwords; read them from the Secrets)."
  value = {
    langsmith = { host = module.postgres_langsmith.host, database = module.postgres_langsmith.database, secret = "langsmith/${kubernetes_secret_v1.langsmith_postgres.metadata[0].name}" }
    smithdb   = { host = module.postgres_smithdb.host, database = module.postgres_smithdb.database, secret = "langsmith/${kubernetes_secret_v1.smithdb_config.metadata[0].name}" }
  }
}

output "redis" {
  description = "Redis instance (no password; read it from the Secret)."
  value = {
    langsmith = { host = module.redis_langsmith.host, maxmemory_mb = module.redis_langsmith.maxmemory_mb, secret = "langsmith/${kubernetes_secret_v1.langsmith_redis.metadata[0].name}" }
  }
}

output "object_store" {
  description = "SmithDB object store (no keys; they're in the smithdb-config Secret)."
  value = {
    endpoint = module.rustfs_smithdb.endpoint
    bucket   = module.rustfs_smithdb.bucket
    buckets  = module.rustfs_smithdb.buckets
    secret   = "langsmith/${kubernetes_secret_v1.smithdb_config.metadata[0].name}"
  }
}

output "features" {
  description = "Enabled features and their wiring (init-values.sh / deploy.sh read this; no secrets)."
  value = {
    deployments  = var.enable_deployments
    blob_storage = var.enable_blob_storage
    keda         = local.install_keda
    sso_oidc     = var.enable_sso_oidc
    standalone = {
      for name, db in local.standalone_features : name => {
        database        = db
        redis_db        = local.redis_db_index[name]
        postgres_secret = "langsmith/langsmith-${name}-postgres"
        redis_secret    = "langsmith/langsmith-${name}-redis"
      }
    }
  }
}
