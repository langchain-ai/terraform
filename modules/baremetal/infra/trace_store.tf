#------------------------------------------------------------------------------
# Trace store: ClickHouse beside SmithDB, and SmithDB's three LangSmith gates.
#
# The inputs carry the names modules/aws and modules/azure use
# (clickhouse_source, enable_smithdb, smithdb_{ingestion,migration,query}_enabled),
# so a customer moving between a cloud and bare metal sees one set. Defaults keep
# this module's install as it was: SmithDB-only, no ClickHouse, no migration.
#
# The staged rollout is the one in SMITHDB.md and the SmithDB docs: SmithDB up,
# dual-write (ingestion on while ClickHouse takes writes too), backfill
# (migration), switch reads (query), then ClickHouse off. Each stage is one
# change to these inputs and one make deploy.
#------------------------------------------------------------------------------

variable "clickhouse_source" {
  type        = string
  default     = "off"
  description = "ClickHouse for the trace store. off: SmithDB-only, this module's install so far. in-cluster: the chart's ClickHouse StatefulSet on local-path, where customers on ClickHouse start a SmithDB migration from (dev/POC grade: one pod, no replication). An external ClickHouse is not an input yet."

  validation {
    condition     = contains(["off", "in-cluster"], var.clickhouse_source)
    error_message = "clickhouse_source must be off or in-cluster."
  }
}

variable "enable_smithdb" {
  type        = bool
  default     = true
  description = "SmithDB's services. false leaves ClickHouse as the only trace store (needs clickhouse_source = in-cluster); the metastore Postgres and RustFS are still created, since blob storage shares RustFS."
}

variable "smithdb_ingestion_enabled" {
  type        = bool
  default     = true
  description = "New writes go to SmithDB. With ClickHouse on, they go to both (dual ingest)."
}

variable "smithdb_migration_enabled" {
  type        = bool
  default     = false
  description = "The historical backfill Job (ClickHouse to SmithDB), with its chart-managed TaskDB. Needs ClickHouse and SmithDB ingestion. Turning it off deletes TaskDB and the Job's progress, so only after the Job reports Complete."
}

variable "smithdb_query_enabled" {
  type        = bool
  default     = true
  description = "Reads come from SmithDB instead of ClickHouse."
}

variable "smithdb_migration_parallelism" {
  type        = number
  default     = 1
  description = "Migration pods running at once (the chart's smithdb.migration.job.parallelism). The budget counts every one."

  validation {
    condition     = var.smithdb_migration_parallelism >= 1 && floor(var.smithdb_migration_parallelism) == var.smithdb_migration_parallelism
    error_message = "smithdb_migration_parallelism must be a whole number, 1 or more."
  }
}

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

  # The chart's ClickHouse volume, set explicitly so the budget and the
  # StatefulSet agree (the chart's default, values.yaml clickhouse.statefulSet.persistence.size).
  clickhouse_storage_gi = 50
  # Requests come from the sizing file Helm deploys, as for the app pods.
  clickhouse_requests = try(local.app_values.clickhouse.statefulSet.resources.requests, null)

  # The backfill Job and TaskDB. chart: the chart's defaults (0.17.26 values.yaml).
  # minimal (minimum, lab): small enough for a 6-core node.
  # ponytail: minimal is unmeasured until the first lab backfill; size it from that run's peak.
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
      disk     = "${local.clickhouse_storage_gi}Gi"
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
      external              = { existingSecretName = kubernetes_secret_v1.langsmith_clickhouse[0].metadata[0].name }
      statefulSet = {
        persistence = {
          enabled          = true
          size             = "${local.clickhouse_storage_gi}Gi"
          storageClassName = module.local_path.storage_class_retain
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
            existingSecretName = kubernetes_secret_v1.smithdb_taskdb[0].metadata[0].name
            passwordSecretKey  = "postgres_password"
          }
          statefulSet = {
            resources   = { requests = local.smithdb_migration_size.taskdb.requests, limits = local.smithdb_migration_size.taskdb.limits }
            persistence = { enabled = true, size = local.smithdb_migration_size.taskdb.storage, storageClassName = module.local_path.storage_class_delete }
          }
        }
      }
    }
  } : {}
}

resource "terraform_data" "trace_store" {
  input = {
    clickhouse = var.clickhouse_source
    smithdb    = local.smithdb_gate_values
  }

  lifecycle {
    precondition {
      condition     = length(local.trace_store_problems) == 0
      error_message = "Trace store: ${join("; ", local.trace_store_problems)}."
    }

    precondition {
      condition     = !local.clickhouse_in_cluster || local.clickhouse_requests != null
      error_message = "The ${var.sizing_profile} sizing file sets no clickhouse.statefulSet.resources.requests. The budget can't account for ClickHouse."
    }
  }
}

resource "random_password" "clickhouse" {
  count   = local.clickhouse_in_cluster ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "langsmith_clickhouse" {
  count = local.clickhouse_in_cluster ? 1 : 0
  metadata {
    name      = "langsmith-clickhouse"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  # The keys the chart reads (templates/clickhouse/secrets.yaml). The host is the
  # chart's own Service for release "langsmith" (helm/scripts/deploy.sh).
  data = {
    clickhouse_user        = "default"
    clickhouse_password    = random_password.clickhouse[0].result
    clickhouse_host        = "langsmith-clickhouse.${kubernetes_namespace_v1.langsmith.metadata[0].name}.svc.cluster.local"
    clickhouse_port        = "8123"
    clickhouse_native_port = "9000"
    clickhouse_db          = "default"
    clickhouse_tls         = "false"
  }
  type = "Opaque"
}

# The chart-managed TaskDB needs a password or a Secret; without one chart 0.17
# fails to render the migration (seen on the Azure module, fixed there the same way).
resource "random_password" "smithdb_taskdb" {
  count   = var.smithdb_migration_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "smithdb_taskdb" {
  count = var.smithdb_migration_enabled ? 1 : 0
  metadata {
    name      = "smithdb-taskdb"
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    postgres_password = random_password.smithdb_taskdb[0].result
  }
  type = "Opaque"
}
