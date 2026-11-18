# How a plan is sized

> **Status:** current at chart 0.17.56 and 0.18.0-rc.79, docs commit `f4af8d0`. The tables marked
> generated are written by `make reference` from `params.yaml` and `citations.yaml`, and the tests fail
> when they drift.

Every number in a plan comes from one of five places, and only one of them is this package's own. The
chart and the public docs are canon: the plan reads the chart at the version you install and quotes the
docs by commit, and it never restates either. Your inputs describe the load. Measurements from a running
install are compared with a plan and never stored in it. What is left, the constants no chart value or
docs page gives, are the parameters in `params.yaml`, and each one carries its unit, the reason it exists,
its source, who set it and when.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="figures/how-it-works-dark.png">
  <img alt="How a plan is made. Four sources feed the model: the Helm chart (every default, rendered with helm at the version planned), the public docs (the scale guide, SmithDB's tiers, store requirements, the backfill rate, quoted by commit and checked), your inputs (users, traces a second, runs a trace, retention, where each store runs) and the parameters (the model's own constants in params.yaml, each with its evidence). The model runs eight stages in order: rates, regime, the scale guide's grid, payload, SmithDB, stores, operate and totals. It writes plan.json, values.yaml, stores.json and load-profile.json; the load test sends the profile at the install and compare judges its results against the plan." src="figures/how-it-works-light.png">
</picture>

| Source | Gives | How it is read | When they disagree |
|:--|:--|:--|:--|
| The Helm chart | every default: requests, limits, replica counts, autoscaler blocks, SmithDB's per-tier pod sizes, Redis expiry | rendered with `helm template` at the version planned (`chart.py`) | the chart wins: a parameter that restates a chart value fails `make params` |
| The public docs | the scale guide's five configurations, SmithDB's tiers, store requirements, the backfill rate | quoted by file, commit and exact text in `citations.yaml` | the docs win: a quote the docs no longer carry fails `make citations` |
| Inputs | the load and the shape of the install | flags, the wizard, or a preset in `presets/` | yours win: a flag replaces the preset's value |
| Parameters | the model's own constants, in `params.yaml` | refused at load without unit, why, source, author and date | a parameter may override a chart default only by naming the `chart_key` and saying why |
| Measurements | what a running install reports | `compare` sets a load test's results against the plan | a measurement that should change sizing becomes a parameter, with the run as its source |

The model began as LangChain Professional Services' sizing calculator by Dzmitry Dubarau, and 180 of that
calculator's own outputs are kept as a conformance fixture (`cases/`): the plan must match each field by
field. Where this package departs on purpose (the low regimes' SmithDB layout) the departure is recorded in
the plan under `regime_adjusted` and has a test of its own.

## The published profiles it builds from

### The scale guide

The docs' [scaling guide](https://docs.langchain.com/langsmith/self-host-scale) publishes five
configurations of a reads by writes grid. Reads are counted in concurrent frontend users, writes in traces
a second. These are the replica counts and stores the plan starts from:

<!-- generated:scale-guide -->
| Published configuration | frontend | platform-backend | ingest-queue | backend | Redis GiB | ClickHouse |
|:--|:--|:--|:--|:--|:--|:--|
| Low reads (5 users), Low writes (10 traces/s) | 1 | 3 | 3 | 2 | 8 | 4 vCPU, 16 GiB |
| Low reads (5 users), High writes (1,000 traces/s) | 4 | 20 | 24 | 5 | 26 | 10 vCPU, 32 GiB |
| High reads (50 users), Low writes (10 traces/s) | 2 | 3 | 3 | 40 | 8 | 8 vCPU, 16 GiB |
| Medium reads (20 users), Medium writes (100 traces/s) | 2 | 3 | 6 | 16 | 13 | 16 vCPU, 24 GiB |
| High reads (50 users), High writes (1,000 traces/s) | 4 | 20 | 24 | 50 | 26 | 14 vCPU, 24 GiB |
<!-- /generated:scale-guide -->

The guide publishes five of the grid's nine nodes. The other four are blended from their published
neighbors and then clamped between them, so that no count falls as the load rises: the guide's own
Medium/Medium runs 3 platform-backend replicas where Low reads/High writes runs 20, and a straight blend
would let a heavier load get fewer pods.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="figures/scale-grid-dark.png">
  <img alt="The scale guide's grid of reads (5, 20 and 50 users) by writes (10, 100 and 1,000 traces a second). Five configurations are published: Low/Low, Low reads with High writes, Medium/Medium, High reads with Low writes, and High/High, each with its frontend, platform-backend, ingest-queue and backend replicas and Redis memory. The other four are blended between their published neighbors and held between them, so no count falls as the load rises." src="figures/scale-grid-light.png">
</picture>

### SmithDB's tiers

The docs' [SmithDB scaling page](https://docs.langchain.com/langsmith/self-host-smithdb-scale) publishes
three tiers, each rated at a tested ingest and query rate. The per-pod CPU, memory and cache come from the
chart's tier helper at the version planned (`smithdb.resourceTier`), never from this table; the tier a
load needs is the model's choice, from the peak write rate in runs a second and the read rate.

<!-- generated:smithdb-tiers -->
| Tier | Tested ingest / query QPS (docs) | Peak runs/s (model's band) | ingestion | query | compaction | compaction-worker | cluster-manager | Metastore (docs) |
|:--|:--|:--|:--|:--|:--|:--|:--|:--|
| small | 10 / 10 | below 100 | 1 | 1 | 1 | 1 | 1 | 2 vCPU, 16 GiB |
| medium | 100 / 40 | below 1,000 | 1 | 1 | 1 | 1 | 1 | 4 vCPU, 32 GiB |
| large | 1,000 / 100 | below 10,000 | 2 | 4 | 1 | 4 | 1 | 8 vCPU, 64 GiB |
<!-- /generated:smithdb-tiers -->

The tiers' QPS is batched ingest requests, while every measured limit is in runs a second, so the model
keeps its own band edges in runs a second (`smithdb.peak_runs_bands`), from field cases.

### Every citation

Each figure the plan takes from the docs, with the page it is quoted from. `make citations` fetches each
page at the pinned commit and fails a quote that is gone; CI also runs it weekly against the docs' main
branch, so a docs change shows up as a failing check before anyone quotes a stale number.

<!-- generated:citations -->
| Citation | Docs page | Values it gives |
|:--|:--|:--|
| `scale.read_anchors` | `self-host-scale.mdx` | {low: 5, medium: 20, high: 50, unit: concurrent frontend users, rps: {low: 10, medium: 40, high: 100}} |
| `scale.write_anchors` | `self-host-scale.mdx` | {low: 10, medium: 100, high: 1000, unit: traces/s} |
| `scale.replicas.frontend` | `self-host-scale.mdx` | {ll: 1, lh: 4, hl: 2, mm: 2, hh: 4} |
| `scale.replicas.platform_backend` | `self-host-scale.mdx` | {ll: 3, lh: 20, hl: 3, mm: 3, hh: 20} |
| `scale.replicas.ingest_queue` | `self-host-scale.mdx` | {ll: 3, lh: 24, hl: 3, mm: 6, hh: 24} |
| `scale.replicas.backend` | `self-host-scale.mdx` | {ll: 2, lh: 5, hl: 40, mm: 16, hh: 50} |
| `scale.redis_gib` | `self-host-scale.mdx` | {ll: 8, lh: 26, hl: 8, mm: 13, hh: 26} |
| `scale.clickhouse` | `self-host-scale.mdx` | {cpu: {ll: 4, lh: 10, hl: 8, mm: 16, hh: 14}, mem_gib: {ll: 16, lh: 32, hl: 16, mm: 24, hh: 24}, per_replica: [hl, hh]} |
| `scale.clickhouse_setup` | `self-host-scale.mdx` | {single: 1, replicated: 3, replicated_in: [hl, hh]} |
| `scale.postgres` | `self-host-scale.mdx` | {cpu: 2, memory_gb: 8, storage_gb: 10} |
| `scale.clickhouse_disk.medium` | `self-host-scale.mdx` | {traces_per_second: 100, gi_per_day: 60} |
| `scale.clickhouse_disk.high` | `self-host-scale.mdx` | {traces_per_second: 1000, gi_per_day: 600} |
| `scale.min_replicas.frontend.lh` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.platform_backend.lh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.ingest_queue.lh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.backend.lh` | `self-host-scale.mdx` | 3 |
| `scale.min_replicas.ingest_queue.hl` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.backend.hl` | `self-host-scale.mdx` | 16 |
| `scale.min_replicas.ingest_queue.mm` | `self-host-scale.mdx` | 3 |
| `scale.min_replicas.backend.mm` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.frontend.hh` | `self-host-scale.mdx` | 2 |
| `scale.min_replicas.platform_backend.hh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.ingest_queue.hh` | `self-host-scale.mdx` | 8 |
| `scale.min_replicas.backend.hh` | `self-host-scale.mdx` | 20 |
| `smithdb.tested_qps` | `self-host-smithdb-scale.mdx` | {small: {ingest: 10, query: 10}, medium: {ingest: 100, query: 40}, large: {ingest: 1000, query: 100}} |
| `smithdb.replicas.ingestion` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 2} |
| `smithdb.replicas.query` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 4} |
| `smithdb.replicas.compaction` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 1} |
| `smithdb.replicas.compaction-worker` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 4} |
| `smithdb.replicas.cluster-manager` | `self-host-smithdb-scale.mdx` | {small: 1, medium: 1, large: 1} |
| `smithdb.metastore` | `self-host-smithdb-scale.mdx` | {small: {cpu: 2, memory_gib: 16}, medium: {cpu: 4, memory_gib: 32}, large: {cpu: 8, memory_gib: 64}} |
| `smithdb.metastore_postgres` | `self-host-smithdb-infrastructure.mdx` | {min_major_version: 18} |
| `smithdb.cache_volume` | `self-host-smithdb-infrastructure.mdx` | {min_iops: 7000, min_mib_per_second: 1000} |
| `smithdb.backfill` | `self-host-smithdb-migrate.mdx` | {runs_per_vcpu_day: 5000000} |
| `smithdb.backfill_pod_memory` | `self-host-smithdb-migrate.mdx` | {min_memory_gib: 32} |
| `agent_server.load_levels` | `agent-server-scale.mdx` | {low: 5, medium: 50, high: 500, unit: requests/s a deployment} |
| `agent_server.api_servers` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2, replicas: {ll: 1, lh: 6, hl: 10, mm: 3, hh: 15}} |
| `agent_server.queue_workers` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2, replicas: {ll: 1, lh: 10, hl: 1, mm: 5, hh: 10}} |
| `agent_server.n_jobs_per_worker` | `agent-server-scale.mdx` | {ll: 10, lh: 50, hl: 10, mm: 10, hh: 50} |
| `agent_server.redis` | `agent-server-scale.mdx` | {cpu: 1, memory_gib: 2} |
| `agent_server.postgres` | `agent-server-scale.mdx` | {cpu: {ll: 2, lh: 4, hl: 4, mm: 4, hh: 8}, memory_gib: {ll: 8, lh: 16, hl: 16, mm: 16, hh: 32}} |
| `agent_server.limit_default` | `data-plane.mdx` | {limit_over_request: 2} |
| `agent_server.requires` | `enable-self-hosted-agent-server.mdx` | {requires: [KEDA, an ingress with config.hostname]} |
| `gateway.streams_per_replica` | `llm-gateway-self-hosted.mdx` | {streams: 100} |
| `gateway.stores` | `llm-gateway-self-hosted.mdx` | {stores: [postgres, redis]} |
| `engine.requires_sandboxes` | `engine-self-hosted.mdx` | {requires: [sandboxes]} |
| `engine.shares_insights` | `engine-self-hosted.mdx` | {shares: insights} |
| `fleet.own_stores` | `enable-self-hosted-fleet.mdx` | {postgres: own, redis: own} |
| `insights_chat.keys` | `self-host-insights-chat.mdx` | {key: Fernet} |
| `sandboxes.hosts` | `self-host-sandbox-scaling.mdx` | {formula: ceil(committed_vcpu / (host_vcpu * target)) + headroom} |
| `sandboxes.target` | `self-host-sandbox-scaling.mdx` | {pct: 70} |
| `sandboxes.headroom` | `self-host-sandbox-scaling.mdx` | {hosts: 1} |
| `sandboxes.min_hosts` | `self-host-sandbox-scaling.mdx` | {hosts: 2} |
| `sandboxes.memory` | `self-host-sandbox-scaling.mdx` | {memory_gib_each: 2} |
| `sandboxes.cpu_only` | `self-host-sandbox-scaling.mdx` | {signal: committed vCPU} |
| `sandboxes.host_memory` | `self-host-sandbox-scaling.mdx` | {rule: host memory request covers its guests} |
| `sandboxes.cache` | `enable-self-hosted-sandboxes.mdx` | {cache_gib: 50} |
| `sandboxes.juicefs_redis` | `enable-self-hosted-sandboxes.mdx` | {maxmemory_policy: noeviction} |
| `sandboxes.nodes` | `enable-self-hosted-sandboxes.mdx` | {requires: [dedicated KVM nodes]} |
| `sandboxes.node_arch` | `enable-self-hosted-sandboxes.mdx` | {requires: [x86-64]} |
| `sandboxes.node_cgroup` | `enable-self-hosted-sandboxes.mdx` | {requires: [cgroup v2 with the cpu controller]} |
| `sandboxes.node_devices` | `enable-self-hosted-sandboxes.mdx` | {requires: [/dev/net/tun, /dev/fuse]} |
| `sandboxes.node_nftables` | `enable-self-hosted-sandboxes.mdx` | {requires: [nftables]} |
| `sandboxes.one_host_per_node` | `self-host-sandbox-architecture.mdx` | {host_pods_per_node: 1} |
| `sandboxes.privileged` | `self-host-sandbox-architecture.mdx` | {requires: [privileged pods]} |
| `sandboxes.node_label` | `enable-self-hosted-sandboxes.mdx` | {label: sandbox.langsmith.com/host=true} |
| `gateway.tested_requests` | `llm-gateway-self-hosted.mdx` | {cpu: 1, memory_gib: 1} |
<!-- /generated:citations -->

## The formulas, stage by stage

Each stage is a pure function in `src/langsmith_sizing/model/`: numbers in, numbers out. The worked figures
are the `lite` preset at chart 0.17.56 (5 users, 5 traces/s on average, 15 at the peak, 10 runs a trace),
read from `uv run langsmith-sizing size --chart 0.17.56 --preset lite`.

### 1. Rates

```
runs/s average = traces/s x runs a trace
runs/s peak    = peak traces/s x runs a trace        (when you know your busiest hour)
               = runs/s average x load.peak_factor   (when you do not; the factor is 3)
runs a day     = runs/s average x 86,400
```

`lite` is 50 runs/s on average, 150 at the peak and 4.32 million a day. Storage is sized on the average,
because bytes accumulate at the average rate; Redis, ingest and SmithDB are sized on the peak, because that
is when they fall behind. `model/load.py: run_rates`.

### 2. Regime

The regime is the kind of load, and it decides what the plan turns on. The bands are data in
`params.yaml` and the first that holds wins, tested from the largest down, so a few traces a second of
huge traces is still a large write rate.

<!-- generated:regimes -->
| Regime (tested in this order) | Holds when | Turns on | Unmeasured |
|:--|:--|:--|:--|
| `beyond-tested` | everything else | autoscalers: on, splits: on, redis_cluster: on, queue_partitions: on, separate_node_pools: on, ceilings_above_chart_default: on, scale_out: on, warn_beyond_tested: on, watch_object_store_request_rate: on, payloads_in_redis_when_offload_throttled: on |  |
| `scale-out` | peak at or above 10,000 runs/s | autoscalers: on, splits: on, redis_cluster: on, queue_partitions: on, separate_node_pools: on, ceilings_above_chart_default: on, scale_out: on, watch_object_store_request_rate: on, payloads_in_redis_when_offload_throttled: on |  |
| `large` | peak at or above 1,000 runs/s | autoscalers: on, splits: on, redis_cluster: on, queue_partitions: on, separate_node_pools: on, ceilings_above_chart_default: on |  |
| `extra-lite` | peak at or below 5 traces/s, survives_node_loss is off | autoscalers: off, serving_replicas: 1, clickhouse: off, smithdb_tier: small, smithdb_unified: on, stores_in_cluster: on, one_node: on, short_retention: on, tracing_only: on, hook_jobs_set_node_peak: on, requests_from_measured: on |  |
| `lite` | peak at or below 15 traces/s | autoscalers: on, nodes: 2, smallest_managed_stores: on, smithdb_tier: small, smithdb_unified: on | yes |
| `standard` | everything else | autoscalers: on |  |
<!-- /generated:regimes -->

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="figures/regimes-dark.png">
  <img alt="The five regimes from the smallest peak write rate to the largest: extra-lite (a peak up to 5 traces a second; autoscalers off, one replica, stores in the cluster on one node), lite (up to 15 traces a second on two nodes with the smallest managed stores; unmeasured), standard (everything between), large (a peak from 1,000 runs a second; dedicated SmithDB services, a Redis cluster with queue partitions, separate node pools) and beyond-tested (from 10,000 runs a second; past any load test). The low two keep SmithDB small and scale it out, or run it as one unified pod on 0.18." src="figures/regimes-light.png">
</picture>

`model/regime.py: classify`. The low regimes' edges are peak traces a second; the high ones are peak runs a
second, at SmithDB's band edges.

### 3. The scale guide's replicas

```
position on an axis = 0 at or below Low, 1 at Medium, 2 at or above High, linear between
replicas            = bilinear blend of the four grid nodes around (reads, writes), rounded up once
past High           = the High figure x (users / 50) for frontend and backend,
                                     x (traces/s / 1,000) for platform-backend, ingest-queue and Redis
```

Below Low the plan takes Low: the smallest published configuration is a floor, never scaled down. `lite`
is inside the Low/Low corner, so it takes 1 frontend, 3 platform-backend, 3 ingest-queue and 2 backend
replicas from the guide before the payload model below raises any of them. `model/load.py: build_grid,
grid_profile, profile_for`.

### 4. Payload: what a run costs in each store

LangChain measured three run sizes (8, 64 and 1,500 KiB a run) and what each costs in SmithDB, in the
LangSmith blob bucket, in Redis and in platform-backend pods. Between them the cost follows a power law
(a straight line on log-log axes); outside them it holds the end's value or the end's ratio. A mix of the
three (70% small, 25% medium, 5% large by default) blends them by weight:

```
KB a run, per store = sum over sizes of (share x that size's KB)
```

`lite` blends to 11.975 KB a run in SmithDB, 13.7 KB in the blob bucket and 8.115 KB in Redis. A field
at or above the offload threshold (20 KiB) goes to the blob bucket, and Redis then holds a pointer
instead of the body. `model/payload.py: resolve`; the measurements are `payload.*` in `params.yaml`.

### 5. Ingest queue

```
runs/s a core = run-weighted harmonic mean of the measured rate at each run size
CPUs          = peak runs/s / runs a core x ingest.cpu_headroom (1.25)
pods          = max(ingest.min_pods (2), ceil(CPUs / ingest.pod_cpu (2)))
floor         = the same at the average rate
KEDA ceiling  = the nearest multiple of 5 to pods x 1.5, never below pods
```

The mean is harmonic because a large run holds a core longer: the times add, not the rates. `lite` gets
34.9 runs a second a core, 5.4 CPUs at the peak, 3 pods of 2 vCPU, a floor of 2 and a KEDA ceiling of 5.
The pods run at 2 vCPU, requests equal to limits, where the chart requests 1, because a lab run held lag
under 3 s with three 2-CPU pods where one 1-CPU pod ran 277 s behind. `model/services.py: ingest`.

### 6. platform-backend and backend

```
platform-backend = max(the guide's figure, ceil(peak runs/s / 1,000 x pods a 1,000 runs/s), the chart's default)
backend          = the guide's figure, or the chart's default when SmithDB serves reads
```

The payload term is a floor under the guide, never a cap. When SmithDB serves reads, the Python backend is
off the read path, and the guide's backend curve was measured with ClickHouse serving them, so it does not
apply. `model/services.py: application_replicas`.

### 7. SmithDB

```
write tier  = the first tier whose band the peak runs/s is below
read tier   = the first tier whose tested query QPS covers users x 2 requests/s
tier        = the larger of the two
```

Two requests a second a user is the scale guide's own ratio (100 requests a second at 50 users). From the
medium tier up the query service keeps at least two replicas, so one serves through a rollout; reads raise
the tier, never the query count, because each query pod holds its own cache and more pods split it.

`lite` reads at 10 requests a second, inside small's tested 10, but its 150 peak runs a second is past
small's band of 100, so the bands alone pick medium: two 28 vCPU query pods. The low regimes keep small and
scale it out instead, because one small ingestion pod was measured to hold 86 runs a second (and was
OOM-killed from 113) and at this volume the data fits one query pod's cache:

```
ingestion pods = ceil(peak runs/s / smithdb.small_ingestion_runs_per_pod (86))
query pods     = ceil(query requests/s / small's tested query QPS (10))
unified        = both are 1, the chart has smithdb.topology (0.18), and you did not choose a layout
```

`lite` runs two ingestion pods and one query pod on the small tier. The bands' choice is kept in the plan
under `smithdb.regime_adjusted`, and a tier or layout you give with `--smithdb-tier` or
`--smithdb-topology` is kept as you gave it. `model/smithdb.py: auto_tier, low_regime_layout`.

### 8. Object storage

```
TB             = runs a day x KB a run x 1,000 x days kept x headroom.storage (1.2) / 10^12
SmithDB days   = (1 - extended share) x (base TTL + 5) + extended share x (extended TTL + 5)
blob days      = (1 - extended share) x base TTL + extended share x (extended TTL + base TTL)
```

SmithDB deletes 5 days after a run's TTL (`retention.smithdb_delete_lag_days`). An upgrade to extended
retention writes a second `ttl_l/` copy of an offloaded field beside the `ttl_s/` one, so the extended share
lives for both TTLs in the blob bucket. `lite` (14 days base, 5% extended to 400) needs 2.38 TB for SmithDB
and 2.41 TB for the blob bucket. `model/stores.py: object_storage`.

### 9. Redis

```
bytes    = peak runs/s x Redis KB a run x 1,000 x expiry seconds x headroom.redis (1.3)
shards   = ceil(peak runs/s x (inline share / 850 + offloaded share / 1,700))
alarm at = maxmemory x redis.alarm_pct (70%)
```

Every run stays in Redis for the full expiry (six hours by default), even after it is ingested, so Redis is
sized on the peak and the expiry is never shortened to save memory: a backlog that outlives it loses runs.
`lite` needs 150 x 8.115 x 1,000 x 21,600 x 1.3 = 34.2 GB, so 32 GiB, with the alarm at 22.4 GiB and one
shard. Redis is single-threaded, so the shard count follows the run rate; past one shard or one managed
node's memory (300 GB) it must be a cluster with queue partitions. `model/stores.py: redis_bytes,
redis_shards_for_cpu`.

### 10. Postgres connections

```
connections = (platform-backend + backend pods) x 50 + (queue + ingest-queue pods) x the chart's ASYNCPG_POOL_MAX_SIZE
budget      = max_connections x 0.8
```

`lite` opens 5 x 50 + 4 x 3 = 262 connections. An external instance's `max_connections` is estimated with
the RDS parameter-group formula (memory / 9,531,392, at most 5,000) as a stand-in for every cloud: confirm
it against the instance. `model/stores.py: postgres_connections, postgres_max_connections`.

### 11. Totals and node pools

```
nodes = max(ceil(CPU requests x pools.overhead (1.2) / node vCPU),
            ceil(memory requests x 1.2 / node GiB),
            the pool's floor)
```

Each total is read three times: at the autoscalers' floors, at the sized replicas and at their ceilings.
A pod fits a node only strictly below the node's shape, because the kubelet and system pods take part of
every node. The node shape (8 vCPU, 32 GiB for applications by default) is a counting unit, not a
provisioning instruction: give your own with `--app-node`. `model/totals.py: pool, node_count`.

### 12. A SmithDB backfill

```
vCPUs       = historical runs / 5,000,000 / days to finish     (the docs' migration page)
pods        = ceil(vCPUs / the migration Job's CPU a pod)
pod memory  = at least 32 GiB, whatever the CPU                (the docs' practical minimum)
```

The backfill runs beside the serving pods until it finishes and is sized apart from the tier, and only
when you give `--backfill-runs` and `--backfill-days`. `model/smithdb.py: backfill`.

### 13. Products beside tracing

An install can run Agent Server, Fleet, Insights, Chat (Polly), Engine, the LLM gateway and Sandboxes
beside tracing (`--products`, `PRODUCTS=`, or the wizard's Products question). What each turns on in the
chart, what it requires and what the cluster must have for it is data, in [`products.yaml`](../products.yaml).
Choosing one brings what it requires: Engine brings Sandboxes, as the chart itself refuses Engine without
them. Every product not chosen is switched off in `values.yaml`, because Insights and Chat are on in the
chart by default and would otherwise run pods no plan counted.

Each product's pods are read from a render of the chart with the product on, at the version planned, so a
chart that resizes one (the gateway asks 0.1 vCPU on 0.17 and 1 vCPU on 0.18) is followed without an edit.
Three things the chart cannot say are sized here:

```
unsized pods       Fleet's, Insights' and Chat's API server, queue, Postgres and Redis ship with
                   resources: {}; params products.pods gives each a request (Dzmitry Dubarau's
                   calculator estimates), limit = request x 2, and the values apply them
Agent Server       the operator creates each deployment's pods at run time, so no render shows them:
                   per deployment, the docs' table at its load column (ll, lh, hl, mm, hh):
                   api servers and queue workers of 1 vCPU, 2 GiB, Postgres 2 to 8 vCPU, Redis 1 vCPU,
                   2 GiB; times the deployments. The plan gives the resource_spec to set on each.
gateway replicas   ceil(concurrent streams / 100 streams a replica), the docs' measured figure;
                   the autoscaler's ceiling is raised to at least that
sandbox hosts      hosts = ceil(committed vCPU / (node vCPU x target)) + headroom   (the docs' formula)
                   the same in guest memory, taking the larger, never below the docs' 2
                   target and headroom are the chart's autoscaler settings (70%, 1 host)
                   one host pod a node, so the sandbox pool's nodes are its hosts
                   the host pod's memory request is the chart's plus its share of guest memory
```

Every product pod is counted in the application pool, except the sandbox hosts, which get a KVM pool of
their own (`--sandbox-node`, default 16x64, the smallest host in the docs' scaling table). Sandboxes add a
dedicated JuiceFS metadata Redis to `stores.json`. Each product's needs of the cluster (KEDA and an
ingress for Agent Server; x86-64 KVM nodes, cgroup v2, `/dev/net/tun`, `/dev/fuse`, nftables and a cache
disk for Sandboxes) are listed in the plan with the docs citation for each. `model/products.py`.

Worked example, `--products all --agent-deployments 3 --agent-load mm --gateway-streams 400 --sandboxes 100`
at 0.18: three deployments of 3 API servers and 5 queue workers each; 4 gateway replicas; 100 one-vCPU
sandboxes on 16 vCPU hosts at 70% is ceil(100 / 11.2) + 1 = 10 hosts.

### 14. Past the tiers: scale-out

The docs' SmithDB tiers stop at large and the scale guide at 1,000 traces a second. From the large band's
top (10,000 runs/s) to the 202,700 runs/s a LangChain load test held, the `scale-out` regime scales each
component with the run rate at what that test measured (params `scale_out.measured`, Ben Nagengast):

```
ingest-queue vCPU   = runs/s / 1,000 x 21 x (curve at 128 KB / curve at this mix)   7-vCPU pods
API vCPU            = runs/s / 1,000 x (2.9 offloaded .. 5.0 with payloads in Redis)
SmithDB ingestion   = ceil(runs/s / 4,600)        pods of the large tier's size
compaction workers  = ceil(runs/s / 10,000)
Postgres            = about 1 connection a pod in use; max_connections 2.6x that, PgBouncer in front
```

`cases/scale-test.yaml` holds what ran at 19.6k, 47.1k, 114.6k and 202.7k runs/s, and a test holds every
plan to at least 0.9x and at most 1.6x of it. The calculator's own figures stay under `regime_adjusted`.
Past about 100,000 runs/s the test's object store throttled reads of offloaded payloads, so the plan warns
(`offload-throttled`) to keep payloads in Redis; one busy project's runs concentrate on the same ingestion
pods (`ingestion-hot-project`). `model/scaleout.py`.

At 200,000 runs/s with the test's settings, the plan gives 4,200 ingest vCPU, 1,000 API vCPU, 44 SmithDB
ingestion pods, 21 compaction workers and 236 Redis shards; the test ran 4,235, 1,020, 44, 20 needed and 240.

### 15. Extra-lite on what the pods use

On one node the floor was the chart's requests and the docs' managed-store sizes, not what runs: 17 vCPU and
63 GiB at 0.18. In the extra-lite regime each pod asks what a lab run measured it to use at the plan's load
(params `lite.measured`): idle cores plus cores a run/s or a reader, x 1.5, and memory at its peak x 1.5.
Redis asks its payload's memory without the scale guide's 8 GiB floor. That brings extra-lite at 0.18 to
about 10 vCPU and 37 GiB, one 16 vCPU, 64 GiB node with the hook Jobs; what still keeps it off an 8x32 node
is unmeasured: the unified SmithDB pod at the chart's 4 vCPU and 16 GiB, the in-cluster object store at its
peak from a far heavier run, and six hours of runs held in Redis at the chart's expiry.
`--no-requests-from-measured` (`requests_from_measured: false`) sizes at the chart's requests instead.
`model/lite.py`.

## Every parameter

The model's own constants. The full entry for each, with its reason and the evidence behind it, is in
[`params.yaml`](../params.yaml); a source of `lab` or `load-test` names the runs, and `field` means seen on
self-hosted installs and never named.

<!-- generated:params -->
| Parameter | Value | Unit | Source | By |
|:--|:--|:--|:--|:--|
| `load.peak_factor` | 3 | x | field | Dzmitry Dubarau |
| `load.runs_per_trace` | 10 | runs/trace | measurement | Dzmitry Dubarau |
| `time.seconds_per_month` | 2,626,560 | s | derived | Dzmitry Dubarau |
| `time.seconds_per_year` | 31,536,000 | s | derived | Dzmitry Dubarau |
| `grid.blend` | {ll_mm: 0.5, ll_hl: 0.4, mm_hh: 0.5, hl_hh: 0.5} | ratio | decision | Dzmitry Dubarau |
| `inputs.limits` | (a table: see params.yaml) | per field (KiB, KiB, runs/trace, x, x) | decision | Dzmitry Dubarau |
| `defaults.blob_storage` | on | flag | decision | Dzmitry Dubarau |
| `defaults.redis_expiry_tuned` | on | flag | decision | Dzmitry Dubarau |
| `defaults.compression` | 1 | x | measurement | Dzmitry Dubarau |
| `payload.mix_default` | {small: 70, medium: 25, large: 5} | % of runs | measurement | Dzmitry Dubarau |
| `payload.bucket_kib` | (a table: see params.yaml) | KiB per field | decision | Dzmitry Dubarau |
| `payload.smithdb_kb_per_run` | {small: 3.75, medium: 15, large: 112} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.blob_kb_per_run` | {small: 0, medium: 38, large: 84} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.redis_kb_per_run` | {small: 9.7, medium: 2.9, large: 12} | KB per run (decimal) | load-test | Dzmitry Dubarau |
| `payload.partial_inline_share` | 0.5 | share of runs held in Redis | decision | Dzmitry Dubarau |
| `payload.platform_backend_pods_at_reference` | {small: 3, medium: 6, large: 10} | pods | measurement | Dzmitry Dubarau |
| `payload.reference_traces_per_year` | 10,000,000,000 | traces/year | measurement | Dzmitry Dubarau |
| `payload.tested_traces_per_second` | 300 | traces/s | load-test | Dzmitry Dubarau |
| `retention.extended_share_default_pct` | 5 | % of runs | decision | Dzmitry Dubarau |
| `retention.smithdb_delete_lag_days` | 5 | days | measurement | Dzmitry Dubarau |
| `headroom.storage` | 1.2 | x | measurement | Dzmitry Dubarau |
| `headroom.redis` | 1.3 | x | measurement | Dzmitry Dubarau |
| `headroom.redis_untuned_expiry` | 1.3 | x | measurement | Dzmitry Dubarau |
| `keda.max_factor` | 1.5 | x | decision | Dzmitry Dubarau |
| `keda.round_to` | 5 | replicas | decision | Dzmitry Dubarau |
| `ingest.runs_per_core_points` | [[8, 55], [190, 12.6]] | [KB per run, runs/s per core] | field | Dzmitry Dubarau |
| `ingest.cpu_headroom` | 1.25 | x | field | Dzmitry Dubarau |
| `ingest.pod_cpu` | 2 | vCPU | lab | Dzmitry Dubarau |
| `ingest.pod_memory_gib` | 4 | GiB | field | Dzmitry Dubarau |
| `ingest.min_pods` | 2 | pods | decision | Dzmitry Dubarau |
| `go.min_cpu_limit` | 2 | vCPU | lab | Dzmitry Dubarau |
| `availability.min_replicas` | 2 | replicas | decision | Dzmitry Dubarau |
| `redis.alarm_pct` | 70 | % of maxmemory | field | Dzmitry Dubarau |
| `redis.runs_per_shard` | {inline: 850, offloaded: 1700} | runs/s per shard | load-test | Dzmitry Dubarau |
| `redis.cluster_shard_cap` | 250 | shards | decision | Dzmitry Dubarau |
| `redis.single_node_max_gb` | 300 | GB | decision | Dzmitry Dubarau |
| `redis.expiry_retry_hours` | 3.5 | hours | field | Dzmitry Dubarau |
| `redis.queue_partitions` | {runs_per_partition: 12000, min_on_cluster: 2} | runs/s per partition | field | Dzmitry Dubarau |
| `postgres.pool_api_pod` | 50 | connections per pod | measurement | Dzmitry Dubarau |
| `postgres.connection_budget` | 0.8 | share of max_connections | decision | Dzmitry Dubarau |
| `postgres.max_connections_in_cluster` | 100 | connections | decision | Dzmitry Dubarau |
| `postgres.bytes_per_connection` | 9,531,392 | bytes | derived | Dzmitry Dubarau |
| `postgres.max_connections_cap` | 5,000 | connections | derived | Dzmitry Dubarau |
| `smithdb.peak_runs_bands` | {small: 100, medium: 1000, large: 10000} | peak runs/s | field | Dzmitry Dubarau |
| `smithdb.small_ingestion_runs_per_pod` | 86 | peak runs/s a pod | lab | Reed Bender |
| `smithdb.query_floor_replicas` | 2 | replicas | field | Dzmitry Dubarau |
| `smithdb.mutations_replicas` | 2 | replicas | field | Dzmitry Dubarau |
| `smithdb.splits_from_tier` | large | tier | field | Dzmitry Dubarau |
| `clickhouse.inline_payload_factor` | 5 | x | decision | Dzmitry Dubarau |
| `clickhouse.floor_gi_per_day` | 5 | GiB per TTL day | decision | Dzmitry Dubarau |
| `clickhouse.floor_up_to_traces_per_second` | 20 | traces/s | decision | Dzmitry Dubarau |
| `load.feedback_per_trace` | 0.5 | feedback writes per trace | decision | Hari Narayan |
| `load.read_mix` | (a table: see params.yaml) | relative weight per read | decision | Reed Bender |
| `load.heavy_window_days` | 30 | days | field | Reed Bender |
| `slo.stored_within_seconds` | {p99: 30} | s from send to readable | field | Ben Nagengast |
| `slo.trace_load_seconds` | {p99: 5} | s | field | Ben Nagengast |
| `regimes` | (a table: see params.yaml) | regime bands, first match wins: peak_runs_per_second_above (peak runs/s strictly above), peak_band_min (peak runs/s at or above that SmithDB band's upper edge), peak_traces_per_second_max (the busiest rate at or below; the low regimes' figures are busiest rates), requires (input facts that must hold: one replica cannot survive a node's loss) | decision | Reed Bender |
| `scale.signals` | (a table: see params.yaml) | signal -> the autoscaling field that expresses it (null: none does) | decision | Reed Bender |
| `scale.fallback` | {mechanism: hpa, signal: cpu} | mechanism and signal | decision | Reed Bender |
| `scale.workloads` | (a table: see params.yaml) | workload -> chart values key, where the plan sizes it, recommended mechanism and signals | decision | Reed Bender |
| `configure.queue_priorities` | (a table: see params.yaml) | asynq queue weight (higher runs first) | decision | Reed Bender |
| `configure.partition_env` | (a table: see params.yaml) | environment variable names | decision | Reed Bender |
| `watch.metrics_smithdb` | (a table: see params.yaml) | metric names, by export mode | lab | Reed Bender |
| `watch.metrics_other` | (a table: see params.yaml) | metric names | lab | Reed Bender |
| `watch.items` | (a table: see params.yaml) | items: id, workload, metric, where, threshold, meaning, action | decision | Reed Bender |
| `pools.overhead` | 1.2 | x | decision | Dzmitry Dubarau |
| `pools.app_node` | {cpu: 8, memory_gib: 32} | vCPU, GiB per node | decision | Dzmitry Dubarau |
| `pools.smithdb_node` | (a table: see params.yaml) | vCPU, GiB per node, by SmithDB tier | decision | Dzmitry Dubarau |
| `pools.app_min_nodes` | 2 | nodes | decision | Dzmitry Dubarau |
| `pools.smithdb_min_nodes` | 2 | nodes | decision | Dzmitry Dubarau |
| `pools.datastores_min_nodes` | 1 | nodes | decision | Reed Bender |
| `pools.clickhouse_node_shapes` | [{cpu: 16, memory_gib: 64}, {cpu: 32, memory_gib: 128}] | vCPU, GiB per node, smallest first | decision | Dzmitry Dubarau |
| `datastores.operator_instances` | {survives_node_loss: 3, otherwise: 1} | instances | decision | Dzmitry Dubarau |
| `datastores.limit_factor` | 2 | x requests | lab | Reed Bender |
| `datastores.redis_maxmemory_share` | 0.75 | share of the container's memory limit | lab | Reed Bender |
| `datastores.redis_sentinel` | {replicas: 3, cpu: 0.1, memory_gib: 0.125} | pods, vCPU and GiB each | lab | Reed Bender |
| `datastores.object_store_pod` | (a table: see params.yaml) | vCPU and GiB, by SmithDB tier | lab | Reed Bender |
| `datastores.object_store_measured_traces_per_second` | 80 | traces/s | lab | Reed Bender |
| `smithdb.metastore_disk_gib` | 50 | GiB | decision | Dzmitry Dubarau |
| `products.pods` | (a table: see params.yaml) | vCPU, GiB requested a pod | decision | Dzmitry Dubarau |
| `products.limit_over_request` | 2 | x | decision | Reed Bender |
| `agent_server.load_default` | ll | read/write column of the docs' Agent Server table | decision | Reed Bender |
| `sandboxes.concurrent_default` | 10 | sandboxes running at once | decision | Reed Bender |
| `sandboxes.vcpu_each` | 1 | vCPU a sandbox | decision | Reed Bender |
| `pools.sandbox_node` | {cpu: 16, memory_gib: 64} | vCPU, GiB per node | decision | Reed Bender |
| `sandboxes.juicefs_redis` | {cpu: 2, memory_gib: 5} | vCPU, GiB | decision | Dzmitry Dubarau |
| `scale_out.measured` | (a table: see params.yaml) | requested vCPU per 1,000 runs/s; runs/s per pod or partition; connections per pod; runs/s | load-test | Ben Nagengast |
| `lite.measured` | (a table: see params.yaml) | cores idle (base) and per unit of work (offered or processed runs/s, concurrent readers); GiB a pod; headroom x | lab | Reed Bender |
<!-- /generated:params -->

## Where the public docs are stale or disagree

The model cites the docs as canon, so where they are stale or contradict each other it says which reading
it takes. To revisit with the docs team; none of these changes a citation until the docs do.

| Point | What the docs say | Where it disagrees | The model reads |
|:--|:--|:--|:--|
| The scale guide's top configuration | 1,000 traces/s, 24 ingest replicas, 26 GiB Redis | framed for an older release; installs past it run far more | it as published, and `beyond-published` past it |
| SmithDB tiers | "not throughput limits", Small to Large | nothing above Large; field installs past it are sized by measurement | `beyond-tiers` past the large band |
| Redis run expiry | an example of 3,600 s | the chart's default is 21,600 s; other pages and modules give other values | the chart's value at the version planned |
| A delayed backlog | "delayed rather than dropped" | a run waiting longer than the Redis expiry is dropped | the expiry as the limit (`backlog_tolerance_hours`) |
| Redis sizing | no formula, no `maxmemory-policy` guidance | an eviction loses a run silently | its own formula, and `noeviction` |
| Queue partitions | default 1 | the whole queue then sits on one shard of a Redis cluster | partitions from the run rate when a cluster is needed |
| Autoscaling triggers | KEDA named for ingest-queue and queue only | what each scaler reads is not documented | the chart's templates ([autoscaling.md](autoscaling.md)) |
| Insights and Chat | each its own deployment with its own stores | the Insights and Engine pages say Insights and Engine share one | the newer pages and the chart's render |
| Engine air-gapped | the image-mirroring page says it cannot run | the Engine pages say it can from chart 0.17.0 with your own model providers | the Engine pages |
| Architecture diagram | shows ClickHouse | SmithDB is the trace store for a new install | SmithDB |
| Valkey | supported version 8 | newer versions run in the field | the docs' version |

## What the model does not do

- Past 202,700 runs/s, the highest rate a load test held, nothing is measured (`beyond-tested`), and one
  managed Redis cluster caps near 250 shards. The scale-out rates are from one synthetic test: 128 KB a run,
  no read load, the top rate held four minutes. SmithDB query pods past the tiers are not measured.
- Extra-lite's requests come from a lab run on several nodes; no whole install has been measured on one
  node, and the unified SmithDB pod keeps the chart's request.
- The products beside tracing have no load inputs of their own except Agent Server's deployments and
  load, the gateway's streams and the sandboxes'. Fleet's, Insights' and Chat's pods run at fixed sizes:
  the chart ships none, and the requests here are estimates no load test has read.
- It names vCPU and GiB, never an instance type or a price: picking the instance is provisioning.
- Past about 300 traces a second, where the payload measurements stop, every figure is extrapolated and
  the plan warns `beyond-tested`.
- The `lite` regime is unmeasured: its figures are what to observe on a run, not a promise.
