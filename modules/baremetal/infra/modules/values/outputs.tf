#------------------------------------------------------------------------------
# What the root installs, computed with no provider. The first group is what
# the root hands on as its own outputs (and what a tool needing the module's
# values reads by planning this module alone); the second is what the root's
# resources and checks take. No secrets: Secret names and keys only.
#------------------------------------------------------------------------------

output "langsmith_values" {
  description = "Environment overrides for the LangSmith chart (hostname, gateway, features, trace store, products' resources)."
  value       = local.langsmith_values
}

output "smithdb_values" {
  description = "SmithDB values for the sizing profile (resources, cache, rollout, object store, metastore keys)."
  value       = local.smithdb_values
}

output "datastore_values" {
  description = "The values charts/datastores is installed with, without the passwords and S3 keys."
  value       = local.datastore_chart_values
}

output "features" {
  description = "Enabled features and their wiring (init-values.sh and deploy.sh read the root's copy)."
  value = {
    deployments  = var.enable_deployments
    smithdb      = var.enable_smithdb
    blob_storage = var.enable_blob_storage
    keda         = local.install_keda
    sso_oidc     = var.enable_sso_oidc
    sandboxes    = var.enable_sandboxes
    engine       = var.enable_engine
    # deploy.sh makes the engine-model-gateway Secret from ENGINE_GATEWAY_API_KEY.
    engine_gateway = local.engine_gateway
    standalone = {
      for name, db in local.standalone_features : name => {
        database        = db
        redis_db        = local.redis_db_index[name]
        postgres_secret = "${local.namespace}/langsmith-${name}-postgres"
        redis_secret    = "${local.namespace}/langsmith-${name}-redis"
      }
    }
  }
}

output "pods" {
  description = "Every pod the budget counts, as numbers: name, pool, replicas, cpu_n (cores), mem_gi, disk_gi."
  value       = local.pods_parsed
}

output "budget" {
  description = "Requested resources for sizing_profile against the ceiling from cluster_nodes."
  value       = local.budget_summary
}

output "datastore_sizes" {
  description = "datastore-sizes.yaml as read: each profile's stores (cpu_m, mem_mi, lim_cpu_m, lim_mem_mi, storage_gi), what each extra product adds to the shared instances by feature class, and the JuiceFS Redis."
  value       = local.datastore_size_table
}

output "datastores" {
  description = "Where the in-cluster stores run and how LangSmith reaches them: the data namespace, the label selecting each instance, every instance the chart can run (enabled, service, host, port, database, username), the Secrets in LangSmith's namespace with their keys, the buckets, and the Redis database index of each product."
  value       = local.datastores_summary
}

output "images" {
  description = "Every image the module runs outside the LangSmith chart, by role."
  value       = local.images
}

output "operator_charts" {
  description = "The datastore operators' Helm charts (release, repository, chart, version, namespace), installed with datastore_runtime = operator before the datastores chart."
  value       = local.operator_charts
}

output "values_files" {
  description = "The values files deploy.sh hands Helm, in order (last wins), by name under helm/values/; the optional langsmith-values-local.yaml goes after them."
  value       = local.values_files
}

output "datastore_secrets" {
  description = "The Secrets LangSmith's namespace must hold before Helm runs: the module's, or one created by hand for each external store."
  value       = local.datastore_secrets
}

output "langsmith_url" {
  description = "URL to open LangSmith."
  value       = local.langsmith_url
}

# -- for the root's resources and checks ----------------------------------------------------------

output "namespace" {
  description = "LangSmith's namespace, which the root creates."
  value       = local.namespace
}

output "secret_names" {
  description = "The names of the Secrets the root writes in LangSmith's namespace."
  value       = local.secret_names
}

output "storage_classes" {
  description = "StorageClass names: delete (default) and retain (datastores)."
  value       = local.storage_classes
}

output "gateway" {
  description = "The Gateway the chart attaches its HTTPRoutes to (name, namespace)."
  value       = local.gateway
}

output "addon_pods" {
  description = "The add-ons the root installs, sized as the budget counts them."
  value       = local.addon_pods
}

output "install_keda" {
  description = "Whether the root installs KEDA (with Deployments)."
  value       = local.install_keda
}

output "sized_datastores" {
  description = "Each store the chart runs, in numbers (cpu_m, mem_mi, lim_cpu_m, lim_mem_mi, storage_gi)."
  value       = local.datastores
}

output "postgres" {
  description = "Each in-chart Postgres instance: host, port, database, username."
  value       = local.postgres
}

output "redis" {
  description = "Each in-chart Redis instance: host, port, maxmemory_mb."
  value       = local.redis
}

output "rustfs" {
  description = "Whether RustFS runs, its endpoint and buckets."
  value       = { enabled = local.rustfs_in_cluster, endpoint = local.rustfs_endpoint, buckets = local.rustfs_buckets }
}

output "object_store" {
  description = "The object store SmithDB and the blobs use, without its keys."
  value       = local.object_store
}

output "standalone_features" {
  description = "Each enabled product with a database of its own: name -> database."
  value       = local.standalone_features
}

output "redis_db_index" {
  description = "The Redis database each product takes on the shared instance."
  value       = local.redis_db_index
}

output "postgres_in_chart" {
  description = "The Postgres instances the chart runs (langsmith, smithdb)."
  value       = local.postgres_in_chart
}

output "redis_in_chart" {
  description = "The Redis instances the chart runs (langsmith, juicefs)."
  value       = local.redis_in_chart
}

output "juicefs_bucket" {
  description = "The sandboxes' JuiceFS bucket on RustFS."
  value       = local.juicefs_bucket
}

output "smithdb_dedicated_nodes" {
  description = "Nodes given a SmithDB role: name -> the label and taint key."
  value       = local.smithdb_dedicated_nodes
}

output "pool_stats" {
  description = "Per node pool: what its pods request against what its nodes give, and the largest pod and node."
  value       = local.pool_stats
}

output "problems" {
  description = "What the root's checks refuse, by area; each list is empty when the inputs hold together."
  value = {
    app_requests_missing = local.app_requests_missing
    trace_store          = local.trace_store_problems
    clickhouse_sized     = !local.clickhouse_in_cluster || local.clickhouse_requests != null
    sandboxes            = local.sandbox_problems
    platform             = local.platform_problems
  }
}
