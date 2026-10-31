# SmithDB on bare metal

SmithDB is LangSmith's trace store. It writes traces as columnar (Vortex) files to S3-compatible object storage and
indexes them in a PostgreSQL metastore. By default this example runs it **without ClickHouse**; the inputs below
run it beside ClickHouse for a migration, as the cloud modules do.

This page covers only what is specific to running SmithDB on self-managed Kubernetes. For everything else, see the
official [SmithDB troubleshooting](https://docs.langchain.com/langsmith/self-host-smithdb-troubleshooting) guide. Behavior described here was observed
with LangSmith chart 0.17.x (SmithDB 0.17.33); later versions may differ.

## Beside ClickHouse: dual ingest and migration

The same inputs the cloud modules use (`smithdb_migration_parallelism` as in `modules/azure` and `modules/gcp`; `off` for
`clickhouse_source` is this module's own value, for its SmithDB-only default), in `infra/terraform.tfvars`. The defaults are SmithDB-only, the
install this page describes.

| Input | Default | Does |
|:--|:--|:--|
| `clickhouse_source` | `off` | `in-cluster`: the chart's ClickHouse StatefulSet on local-path (one pod, no replication: what a customer on ClickHouse starts a migration from, not a production store). Its connection is the `langsmith-clickhouse` Secret Terraform makes, not the chart's default password |
| `enable_smithdb` | `true` | SmithDB's services; `false` leaves ClickHouse alone (needs `clickhouse_source = "in-cluster"`) |
| `smithdb_ingestion_enabled` | `true` | new writes go to SmithDB; with ClickHouse on, to both |
| `smithdb_migration_enabled` | `false` | the backfill Job and its chart-managed TaskDB (the `smithdb-taskdb` Secret); needs ClickHouse and ingestion |
| `smithdb_query_enabled` | `true` | reads come from SmithDB |
| `smithdb_migration_parallelism` | `1` | backfill pods at once; the budget counts each |

Before starting, contact LangChain through the Support Portal, as the install guide's prerequisites ask. A migration
is one change per stage, each followed by `make apply` and `make deploy`, in the order of the
[install guide](https://docs.langchain.com/langsmith/self-host-smithdb-install):

1. Customer state: `clickhouse_source = "in-cluster"`, `enable_smithdb = false` and the three gates `false`.
2. SmithDB up: `enable_smithdb = true`. Wait for every smithdb pod and the metastore migration Job.
3. Dual write: `smithdb_ingestion_enabled = true`. `/api/v1/info` shows `sdb_ingestion_enabled` true.
4. Backfill: `smithdb_migration_enabled = true`. Wait for the migration Job to report `Complete`; turning it off
   earlier deletes TaskDB, its volume and the Job's progress.
5. Switch reads: `smithdb_query_enabled = true`, `smithdb_migration_enabled = false`.
6. Retiring ClickHouse is a separate procedure: contact LangChain through the Support Portal first
   ([self-host-smithdb-install](https://docs.langchain.com/langsmith/self-host-smithdb-install)). When it says to,
   `clickhouse_source = "off"` removes the StatefulSet; its volume stays until you delete it ([TEARDOWN.md](TEARDOWN.md)).

A combination the chart refuses (a backfill without ClickHouse, nothing taking writes or reads, a gate without
SmithDB) fails `terraform plan` with the reason, before anything changes. At `minimum` and `lab` the backfill Job
and TaskDB are sized down to fit 6-core nodes (1 CPU / 2Gi and 250m / 512Mi); those sizes are not yet measured
against a real backfill. Plan tests: `infra/tests/trace_store.tftest.hcl`.

## Components

| Component | Role | Scales with |
|---|---|---|
| `cluster-manager` | routes each project to ingestion pods by heartbeat; must be up before ingestion starts | — |
| `ingestion` | receives runs from ingest-queue over gRPC, writes small L0 files every ~500 ms per project, merges them into larger L1 files, **and serves reads of not-yet-merged data** | write rate, payload size (memory) |
| `query` | answers reads: metastore lookup, then object store through memory + disk caches | read requests (about one core per request) |
| `compaction` | scheduler: plans merges, retention (TTL), deletes and garbage collection | data volume (light) |
| `compaction-worker` | executes merges; uses a scratch volume | data volume, payload size (memory) |
| metastore (Postgres 18) | index of every file in the bucket | segment count |
| object store (RustFS, bucket `smithdb`) | the data | stored traces |

## Tiers in this module

| Profile | Tier | Notes |
|---|---|---|
| `minimum`, `lab` | **minimal** | ~1 CPU / 2 GiB requests per component (limits 2 / 4 GiB), `emptyDir` caches (20 / 10 / 10 GiB), one pod each |
| `dev` | chart `small` | 4–8 CPU / 8–16 GiB per component, per-pod PVC caches (200 / 100 / 100 GiB) |
| `production`, `production-large` | chart `medium` | per the chart; review CPU vs memory in [SIZING.md](SIZING.md) |

An explicit `resources` block doesn't change cache size: the module sets caches through `deployment.volumes`.

## Recommended settings

Copy [langsmith-values-local.yaml.example](helm/values/langsmith-values-local.yaml.example) to
`langsmith-values-local.yaml` and adjust. Each item, and why:

| Setting | Recommendation | Why |
|---|---|---|
| Blob storage | **on** (`enable_blob_storage`, Terraform default) | large run payloads go to object storage instead of Redis: Redis per run drops several times for agent-sized traces |
| `config.settings.redisRunsExpirySeconds` | set explicitly (e.g. 1800) | the 6 h default needs very large Redis at production rates; too short drops runs when the queue backs up |
| `GO_INGESTION_CONCURRENCY_PER_CPU` on ingest-queue | 4 on 6–8 core nodes | workers default to one per **node** core, and the drain waits on I/O, not CPU |
| `ENABLE_EVALUATE_EXPIRED_EXPERIMENTS=false` on platform-backend | until fixed upstream | on SmithDB-only installs, feedback on recent runs falls back to ClickHouse and fails ingest batches under load |
| SmithDB ingestion replicas | 2 | spreads each project's writes and removes a single point of failure |
| Gateway route timeout | 60 s (`envoy_gateway_route_timeout`, Terraform default) | Envoy's 15 s default returns 504 on slow reads |
| containerd `LimitNOFILE` | 1048576 on every node, then recreate pods | at the default soft limit (1,024) the query disk cache silently fails to build |
| Redis `hz 50`, `active-expire-effort 5` | set (module default) | with Redis defaults, expired keys pile up under LangSmith's key churn |


## Reads of a project being written

Reads of a project that is receiving traces are slower than reads of idle projects (typically 2–4× while writing, worse
with large SDK payloads). The cause:

1. Each ingestion pod writes a small L0 file per project every ~500 ms.
2. L0 files merge into L1 only after internal buffers flush (60–120 s by default) and ~25,000 rows accumulate, or after
   the project has been idle for 10 minutes (+ up to 3 minutes of jitter).
3. Until then, **every read of that project asks the ingestion pod to scan and sort all of its L0 files**, with no row
   limit, on a small share of the pod's CPU.

Idle projects have no L0 files, so they're unaffected, and adding query pods doesn't help. Reads return to normal
speed once the project's files are merged, about 10–13 minutes after writing stops with the default settings. If it
matters for your workload, raise it with LangChain support: SmithDB behavior is part of the LangSmith application, which
is covered by your agreement.

## Operational risks

| Risk | Symptom | What to do |
|---|---|---|
| Ingest backlog older than `redisRunsExpirySeconds` | runs missing, no error anywhere; Redis keys without a TTL accumulate | size ingest workers ([SIZING.md](SIZING.md)); alert on oldest ingest task age vs the expiry |
| SmithDB pods out of memory with large payloads | `OOMKilled` restarts of ingestion or compaction-worker | memory limits scale with payload size, not CPU; alert on any SmithDB restart |
| Fresh segments left behind after an ingestion restart | one project reads 10× or more slower than others its size | in the metastore: `run_segments` with `writer_server_id` set and `created_at` older than 30 min |
| A compaction job that keeps killing the worker | compaction-worker restarts about hourly; a project never compacts or expires | usually follows an ingestion OOM that left hundreds of tiny segments; deleting the project clears it (see below) |
| Object store or metastore loss | traces unreadable | back up the metastore and the bucket **together**, to the same point in time |

## Deleting a project

Deleting a project in LangSmith is asynchronous in SmithDB:

1. LangSmith records the delete in the metastore (`session_ttl_config.deleted_at`). The project disappears from the UI.
2. The compaction scheduler polls every 60 s and processes deletes older than the **recovery window** (1 h by default,
   12 h with `smithdb.recoveryStrategy` enabled).
3. It soft-deletes the project's segments, queues its files for deletion, and garbage collection removes them later.

So storage and compaction work on a deleted project continue for at least an hour. Check progress with
`select deleted_at, processed_at from session_ttl_config where session_id = '<project id>';` on the metastore.

## Retention

Traces expire per their tier's TTL, applied by the compaction scheduler. The chart's long-lived retention (400 days by
default) and SmithDB's own cap (180 days) differ; confirm the effective retention for your version before relying on it.
The `langsmith-blobs` bucket expires `ttl_s/` and `ttl_l/` payloads as the cloud modules do (`blob_storage_ttl_days`,
14 and 400 days by default); match them to your trace TTLs. The `smithdb` bucket has no lifecycle rules: SmithDB
manages its own segments.
