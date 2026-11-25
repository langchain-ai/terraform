#------------------------------------------------------------------------------
# Trace store: ClickHouse beside SmithDB, and SmithDB's three LangSmith gates
# (the root's trace_store.tf has the inputs and checks the combination).
#------------------------------------------------------------------------------

locals {
  clickhouse_in_cluster = var.clickhouse_source == "in-cluster"
  smithdb_writes        = var.enable_smithdb && var.smithdb_ingestion_enabled
  smithdb_reads         = var.enable_smithdb && var.smithdb_query_enabled

  # The chart's own rules (charts/langsmith templates/validate.yaml), checked at
  # plan so a bad combination fails before anything is created, not mid helm upgrade.
  trace_store_problems = compact([
    !local.clickhouse_in_cluster && !local.smithdb_writes ? "nothing takes writes: ClickHouse is off and SmithDB ingestion is off" : "",
    !local.clickhouse_in_cluster && !local.smithdb_reads ? "nothing serves reads: ClickHouse is off and SmithDB query is off" : "",
    !var.enable_smithdb && (var.smithdb_ingestion_enabled || var.smithdb_migration_enabled || var.smithdb_query_enabled) ? "smithdb_ingestion_enabled, smithdb_migration_enabled and smithdb_query_enabled need enable_smithdb" : "",
    var.smithdb_migration_enabled && !(local.clickhouse_in_cluster && local.smithdb_writes) ? "smithdb_migration_enabled reads ClickHouse and needs SmithDB ingestion on" : "",
  ])

  # Requests come from the sizing file Helm deploys, as for the app pods.
  clickhouse_requests = try(local.app_values.clickhouse.statefulSet.resources.requests, null)

  # The backfill Job and TaskDB. chart: the chart's defaults (0.17.26 values.yaml).
  # minimal (minimum, lab): small enough for a 6-core node.
  # The minimal sizes are unmeasured: size them from the first backfill's peak.
  smithdb_migration_sizes = {
    minimal = {
      job    = { requests = { cpu = "1", memory = "2Gi", "ephemeral-storage" = "20Gi" }, limits = { cpu = "2", memory = "4Gi", "ephemeral-storage" = "20Gi" } }
      taskdb = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" }, storage = "10Gi" }
    }
    chart = {
      job    = { requests = { cpu = "8", memory = "32Gi", "ephemeral-storage" = "100Gi" }, limits = { cpu = "8", memory = "32Gi", "ephemeral-storage" = "100Gi" } }
      taskdb = { requests = { cpu = "2", memory = "4Gi" }, limits = { cpu = "4", memory = "8Gi" }, storage = "50Gi" }
    }
  }
  smithdb_migration_size = local.smithdb_migration_sizes[local.smithdb_tier_name == "minimal" ? "minimal" : "chart"]

  # Pods the budget adds for the trace store, in string_pods' shape. The Job and
  # TaskDB go where SmithDB's compute pods go, as the smithdb Jobs are pinned there.
  trace_store_pods = concat(
    local.clickhouse_in_cluster ? [{
      name     = "clickhouse/statefulset"
      pool     = "workers"
      replicas = 1
      cpu      = tostring(try(local.clickhouse_requests.cpu, "0"))
      memory   = tostring(try(local.clickhouse_requests.memory, "0"))
      disk     = "${var.clickhouse_storage_gi}Gi"
    }] : [],
    var.smithdb_migration_enabled ? [
      {
        name     = "smithdb/migration"
        pool     = local.smithdb_pool.compute
        replicas = var.smithdb_migration_parallelism
        cpu      = local.smithdb_migration_size.job.requests.cpu
        memory   = local.smithdb_migration_size.job.requests.memory
        disk     = local.smithdb_migration_size.job.requests["ephemeral-storage"]
      },
      {
        name     = "smithdb/taskdb"
        pool     = local.smithdb_pool.compute
        replicas = 1
        cpu      = local.smithdb_migration_size.taskdb.requests.cpu
        memory   = local.smithdb_migration_size.taskdb.requests.memory
        disk     = local.smithdb_migration_size.taskdb.storage
      },
    ] : [],
  )

  # The chart's ClickHouse reads its connection from a Secret Terraform makes,
  # like every other datastore here, instead of the chart's default password.
  clickhouse_values = local.clickhouse_in_cluster ? {
    clickhouse = {
      enabled               = true
      disableSecretCreation = true
      external              = { existingSecretName = local.secret_names.clickhouse }
      statefulSet = {
        persistence = {
          enabled          = true
          size             = "${var.clickhouse_storage_gi}Gi"
          storageClassName = local.storage_classes.retain
        }
      }
    }
  } : {}

  smithdb_gate_values = {
    enabled = var.enable_smithdb
    langsmith = {
      ingestion = { enabled = var.smithdb_ingestion_enabled }
      query     = { enabled = var.smithdb_query_enabled }
      migration = { enabled = var.smithdb_migration_enabled }
    }
  }

  smithdb_migration_values = var.smithdb_migration_enabled ? {
    migration = {
      job = {
        parallelism = var.smithdb_migration_parallelism
        resources   = local.smithdb_migration_size.job
      }
      taskdb = {
        postgres = {
          maxConnectionsPerMigrationPod = 10
          auth = {
            existingSecretName = local.secret_names.taskdb
            passwordSecretKey  = "postgres_password"
          }
          statefulSet = {
            resources   = { requests = local.smithdb_migration_size.taskdb.requests, limits = local.smithdb_migration_size.taskdb.limits }
            persistence = { enabled = true, size = local.smithdb_migration_size.taskdb.storage, storageClassName = local.storage_classes.delete }
          }
        }
      }
    }
  } : {}
}
