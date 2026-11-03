#------------------------------------------------------------------------------
# The in-cluster datastores as the root installs them (../../datastores.tf): which instances run, their
# hosts, the chart's values without the passwords, the operators' charts, and the Secrets LangSmith
# reads each store through. Names live here once; the root's resources take them from this module, and
# a tool that hands the same chart to a customer reads the outputs instead of copying them.
#------------------------------------------------------------------------------

locals {
  # Terraform owns this namespace (the root's kubernetes_namespace_v1.langsmith): Helm installs
  # LangSmith and SmithDB into it, and every connection Secret lives there.
  namespace        = "langsmith"
  datastore_label  = { "langsmith.lab/datastore" = "true" }
  instance_label   = "langsmith.lab/datastore-instance"
  operator_runtime = var.datastore_runtime == "operator"

  # Every store the chart can run, by its key in local.datastores (the budget), so a store is in the
  # chart exactly when the budget counts it.
  postgres_instances = { langsmith = "postgres_langsmith", smithdb = "postgres_smithdb" }
  redis_instances    = { langsmith = "redis_langsmith", juicefs = "redis_juicefs" }
  postgres_in_chart  = [for k, d in local.postgres_instances : k if contains(keys(local.datastores), d)]
  redis_in_chart     = [for k, d in local.redis_instances : k if contains(keys(local.datastores), d)]
  # The budget names each store as the chart names its instance.
  datastore_instance_names = { postgres_langsmith = "postgres-langsmith", postgres_smithdb = "postgres-smithdb", redis_langsmith = "redis-langsmith", redis_juicefs = "redis-juicefs", rustfs_smithdb = "rustfs" }
  # Pods per store: Postgres and Redis run datastore_replicas (1 unless the operators run them); RustFS one.
  datastore_pod_replicas = { for k, _ in local.datastores : k => k == "rustfs_smithdb" ? 1 : var.datastore_replicas }
  # Each Sentinel as the OpsTree operator's own replication-with-Sentinel example sizes it (v0.27.0,
  # example/v1beta2/replication_sentinel/redis-replication.yaml): 100m and 128Mi, requests and limits.
  # Three per Redis above one replica, for a quorum of two.
  redis_sentinel = { replicas = 3, cpu_m = 100, mem_mi = 128 }
  sentinel_pods = var.datastore_replicas > 1 ? [
    for k in local.redis_in_chart : { name = "datastore/redis-${k}-sentinel", pool = "workers", replicas = local.redis_sentinel.replicas, cpu_n = local.redis_sentinel.cpu_m / 1000, mem_gi = local.redis_sentinel.mem_mi / 1024, disk_gi = 0 }
  ] : []

  postgres_users = {
    langsmith = { database = "langsmith", username = "langsmith", databases = sort(values(local.standalone_features)) }
    smithdb   = { database = "smithdb_metastore", username = "smithdb", databases = [] }
  }
  # Where each store answers; the root adds the passwords it generates to build the connection Secrets.
  postgres = {
    for k in local.postgres_in_chart : k => {
      host     = "postgres-${k}.${var.datastore_namespace}.svc.cluster.local"
      port     = 5432
      database = local.postgres_users[k].database
      username = local.postgres_users[k].username
    }
  }
  redis = {
    for k in local.redis_in_chart : k => {
      host         = "redis-${k}.${var.datastore_namespace}.svc.cluster.local"
      port         = 6379
      maxmemory_mb = floor(local.datastores[local.redis_instances[k]].lim_mem_mi * 3 / 4)
    }
  }
  rustfs_endpoint = "http://rustfs.${var.datastore_namespace}.svc.cluster.local:9000"
  # With the customer's object store RustFS holds the sandboxes' JuiceFS bucket alone: SmithDB's
  # segments and the blobs go to theirs.
  rustfs_buckets = concat(
    ["smithdb"],
    var.enable_blob_storage && var.object_store_source == "in-cluster" ? [local.blob_bucket] : [],
    var.enable_sandboxes ? [local.juicefs_bucket] : [],
  )
  # The object store SmithDB and the blobs use, without its keys (the root reads or generates those).
  object_store = var.object_store_source == "external" ? {
    endpoint   = var.object_store_endpoint
    region     = var.object_store_region
    path_style = var.object_store_path_style
    smithdb    = var.object_store_buckets.smithdb
    blobs      = var.object_store_buckets.blobs
    } : {
    endpoint   = local.rustfs_endpoint
    region     = "us-east-1" # any value; RustFS ignores it, the SDK needs one
    path_style = true
    smithdb    = "smithdb"
    blobs      = local.blob_bucket
  }

  # The operators, each its own release before the chart's: a custom resource in the same release as
  # its CRD fails the install, since Helm maps every kind before it applies the first.
  operator_charts = {
    postgres = { release = "cnpg", repository = "https://cloudnative-pg.github.io/charts", chart = "cloudnative-pg", version = var.cnpg_chart_version, namespace = "cnpg-system" }
    redis    = { release = "redis-operator", repository = "https://ot-container-kit.github.io/helm-charts", chart = "redis-operator", version = var.redis_operator_chart_version, namespace = "redis-operator" }
  }

  # Every image this module runs outside the LangSmith chart, so a mirror can carry them all.
  images = {
    postgres          = var.postgres_image
    postgres_operator = var.cnpg_postgres_image
    redis             = var.redis_image
    redis_operator    = var.opstree_redis_image
    rustfs            = var.rustfs_image
    aws_cli           = var.aws_cli_image
    local_path        = var.local_path_image
    local_path_helper = var.local_path_helper_image
    cloudflared       = var.cloudflared_image
  }

  datastore_chart_values = {
    runtime            = var.datastore_runtime
    storageClass       = local.storage_classes.retain
    namespace          = var.datastore_namespace
    createNamespaces   = var.datastore_namespace != local.namespace
    allowedNamespaces  = [local.namespace]
    datastoreLabel     = local.datastore_label
    operatorNamespaces = { postgres = local.operator_charts.postgres.namespace, redis = local.operator_charts.redis.namespace }
    postgres = {
      image         = var.postgres_image
      operatorImage = var.cnpg_postgres_image
      instances = merge(
        { for k in keys(local.postgres_instances) : k => { enabled = false } },
        { for k in local.postgres_in_chart : k => {
          enabled        = true
          database       = local.postgres_users[k].database
          username       = local.postgres_users[k].username
          databases      = local.postgres_users[k].databases
          maxConnections = 200
          replicas       = var.datastore_replicas
          resources      = { requests = local.datastores_k8s[local.postgres_instances[k]].requests, limits = local.datastores_k8s[local.postgres_instances[k]].limits }
          volumeSize     = local.datastores_k8s[local.postgres_instances[k]].storage
        } },
      )
    }
    redis = {
      image         = var.redis_image
      operatorImage = var.opstree_redis_image
      sentinelResources = {
        requests = { cpu = "${local.redis_sentinel.cpu_m}m", memory = "${local.redis_sentinel.mem_mi}Mi" }
        limits   = { cpu = "${local.redis_sentinel.cpu_m}m", memory = "${local.redis_sentinel.mem_mi}Mi" }
      }
      instances = merge(
        { for k in keys(local.redis_instances) : k => { enabled = false } },
        { for k in local.redis_in_chart : k => {
          enabled = true
          # The queue Redis snapshots; JuiceFS metadata is a filesystem's and must not be lost.
          persistence     = k == "juicefs" ? "aof" : "rdb"
          maxmemoryPolicy = "noeviction"
          allowedCidrs    = k == "juicefs" ? var.sandbox_source_cidrs : []
          replicas        = var.datastore_replicas
          resources       = { requests = local.datastores_k8s[local.redis_instances[k]].requests, limits = local.datastores_k8s[local.redis_instances[k]].limits }
          volumeSize      = local.datastores_k8s[local.redis_instances[k]].storage
        } },
      )
    }
    # Every key whether or not RustFS runs: Terraform will not unify an object with {} in a conditional.
    rustfs = {
      enabled      = local.rustfs_in_cluster
      image        = var.rustfs_image
      awsCliImage  = var.aws_cli_image
      buckets      = local.rustfs_buckets
      ttlBuckets   = var.enable_blob_storage && var.object_store_source == "in-cluster" ? [local.blob_bucket] : []
      ttlDays      = var.blob_storage_ttl_days
      allowedCidrs = var.enable_sandboxes ? var.sandbox_source_cidrs : []
      resources    = local.rustfs_in_cluster ? { requests = local.datastores_k8s.rustfs_smithdb.requests, limits = local.datastores_k8s.rustfs_smithdb.limits } : null
      volumeSize   = local.rustfs_in_cluster ? local.datastores_k8s.rustfs_smithdb.storage : null
    }
  }

  # The Secrets in LangSmith's namespace the chart can read a store through, with their keys, whether
  # or not this install needs them (datastore_secrets lists those): the root's resources take these
  # names, and a customer applying the chart themselves creates the same. Formats follow chart 0.17:
  # the core Postgres URL has no scheme, Redis's has one, a product's has one.
  secret_names = {
    postgres   = var.postgres_source == "external" ? var.postgres_secret : "langsmith-postgres"
    redis      = var.redis_source == "external" ? var.redis_secret : "langsmith-redis"
    smithdb    = "smithdb-config"
    clickhouse = "langsmith-clickhouse"
    taskdb     = "smithdb-taskdb"
    juicefs    = "langsmith-sandbox-juicefs"
  }
  connection_secrets = merge(
    {
      postgres = { name = local.secret_names.postgres, keys = ["connection_url"] }
      redis    = { name = local.secret_names.redis, keys = ["connection_url"] }
      smithdb  = { name = local.secret_names.smithdb, keys = ["smithdb_metastore_host", "smithdb_metastore_db", "smithdb_metastore_user", "smithdb_metastore_password", "smithdb_s3_access_key", "smithdb_s3_secret_key"] }
      # The customer's, read into smithdb-config when they run the metastore or the object store.
      smithdb_metastore = { name = var.smithdb_metastore_secret, keys = ["smithdb_metastore_host", "smithdb_metastore_db", "smithdb_metastore_user", "smithdb_metastore_password"] }
      object_store      = { name = var.object_store_secret, keys = ["access_key_id", "secret_access_key"] }
    },
    {
      clickhouse = { name = local.secret_names.clickhouse, keys = ["clickhouse_user", "clickhouse_password", "clickhouse_host", "clickhouse_port", "clickhouse_native_port", "clickhouse_db", "clickhouse_tls"] }
      taskdb     = { name = local.secret_names.taskdb, keys = ["postgres_password"] }
      juicefs    = { name = local.secret_names.juicefs, keys = ["name", "metaurl", "storage", "bucket", "access-key", "secret-key"] }
    },
    { for p in keys(local.standalone_feature_flags) : "${p}_postgres" => { name = "langsmith-${p}-postgres", keys = ["postgres_connection_url"] } },
    { for p in keys(local.standalone_feature_flags) : "${p}_redis" => { name = "langsmith-${p}-redis", keys = ["redis_connection_url"] } },
  )

  # Every instance the chart can run, whether this install runs it, and where it answers.
  datastore_instances = merge(
    { for k, d in local.postgres_instances : local.datastore_instance_names[d] => {
      kind     = "postgres"
      enabled  = contains(local.postgres_in_chart, k)
      service  = local.datastore_instance_names[d]
      host     = "${local.datastore_instance_names[d]}.${var.datastore_namespace}.svc.cluster.local"
      port     = 5432
      database = local.postgres_users[k].database
      username = local.postgres_users[k].username
    } },
    { for k, d in local.redis_instances : local.datastore_instance_names[d] => {
      kind     = "redis"
      enabled  = contains(local.redis_in_chart, k)
      service  = local.datastore_instance_names[d]
      host     = "${local.datastore_instance_names[d]}.${var.datastore_namespace}.svc.cluster.local"
      port     = 6379
      database = "0"
      username = ""
    } },
    { rustfs = {
      kind     = "rustfs"
      enabled  = local.rustfs_in_cluster
      service  = "rustfs"
      host     = "rustfs.${var.datastore_namespace}.svc.cluster.local"
      port     = 9000
      database = ""
      username = ""
    } },
  )

  datastores_summary = {
    namespace      = var.datastore_namespace
    instance_label = local.instance_label
    instances      = local.datastore_instances
    secrets        = local.connection_secrets
    buckets        = { smithdb = local.object_store.smithdb, blobs = local.object_store.blobs, juicefs = local.juicefs_bucket }
    # One logical database per product on the shared Redis (Fleet 1, Polly 2, Insights 3), as modules/gcp.
    redis_db = local.redis_db_index
  }
}
