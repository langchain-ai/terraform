#------------------------------------------------------------------------------
# Trace store: ClickHouse beside SmithDB, and SmithDB's three LangSmith gates.
#
# The inputs carry the names the cloud modules use
# (clickhouse_source, enable_smithdb, smithdb_{ingestion,migration,query}_enabled),
# so a customer moving between a cloud and bare metal sees one set. The defaults are
# SmithDB-only: no ClickHouse, no migration.
#
# The staged rollout is the one in SMITHDB.md and the SmithDB docs: SmithDB up,
# dual-write (ingestion on while ClickHouse takes writes too), backfill
# (migration), switch reads (query). Each stage is one change to these inputs
# and one make deploy. Retiring ClickHouse afterwards goes through LangChain
# Support (SMITHDB.md).
#------------------------------------------------------------------------------

variable "clickhouse_source" {
  type        = string
  default     = "off"
  description = "ClickHouse for the trace store. off: SmithDB-only, the default. in-cluster: the chart's ClickHouse StatefulSet on local-path, where customers on ClickHouse start a SmithDB migration from (dev/POC grade: one pod, no replication). An external ClickHouse is not an input yet."

  validation {
    condition     = contains(["off", "in-cluster"], var.clickhouse_source)
    error_message = "clickhouse_source must be off or in-cluster."
  }
}

variable "clickhouse_storage_gi" {
  type        = number
  default     = 50
  description = "Volume of the in-cluster ClickHouse (clickhouse_source = in-cluster), when the retained traces and not the chart's default should set it: about 60 GiB a day of TTL at 100 traces/s (docs self-host-scale). The budget counts it against the node's disk; local-path does not enforce it, and a running StatefulSet keeps its claim. 50: the chart's default (values.yaml clickhouse.statefulSet.persistence.size)."

  validation {
    condition     = var.clickhouse_storage_gi >= 1 && floor(var.clickhouse_storage_gi) == var.clickhouse_storage_gi
    error_message = "clickhouse_storage_gi must be a whole number of GiB, 1 or more."
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
  description = "The historical backfill Job (ClickHouse to SmithDB), with its chart-managed TaskDB. Needs ClickHouse and SmithDB ingestion. Turning it off deletes TaskDB, its volume and the Job's progress, so only after the Job reports Complete."
}

variable "smithdb_query_enabled" {
  type        = bool
  default     = true
  description = "Reads come from SmithDB instead of ClickHouse."
}

variable "smithdb_tier" {
  type        = string
  default     = ""
  description = "SmithDB's resource tier (minimal, small, medium), when the load and not the sizing profile should set it: the SmithDB scale docs give each tier its ingest and query QPS, and production's medium tier asks 28 cores a query pod whatever the load. Empty: the sizing profile's tier."

  validation {
    condition     = contains(["", "minimal", "small", "medium"], var.smithdb_tier)
    error_message = "smithdb_tier must be empty, minimal, small or medium."
  }
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

resource "terraform_data" "trace_store" {
  input = {
    clickhouse = var.clickhouse_source
    smithdb    = { enabled = module.values.smithdb_values.smithdb.enabled, langsmith = module.values.smithdb_values.smithdb.langsmith }
  }

  lifecycle {
    precondition {
      condition     = length(module.values.problems.trace_store) == 0
      error_message = "Trace store: ${join("; ", module.values.problems.trace_store)}."
    }

    precondition {
      condition     = module.values.problems.clickhouse_sized
      error_message = "The ${var.sizing_profile} sizing file sets no clickhouse.statefulSet.resources.requests. The budget can't account for ClickHouse."
    }
  }
}

resource "random_password" "clickhouse" {
  count   = var.clickhouse_source == "in-cluster" ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "langsmith_clickhouse" {
  count = var.clickhouse_source == "in-cluster" ? 1 : 0
  metadata {
    name      = module.values.secret_names.clickhouse
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
    name      = module.values.secret_names.taskdb
    namespace = kubernetes_namespace_v1.langsmith.metadata[0].name
  }
  data = {
    postgres_password = random_password.smithdb_taskdb[0].result
  }
  type = "Opaque"
}
