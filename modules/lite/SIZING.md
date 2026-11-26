# Sizing

> **Status:** current · **Last verified:** 2026-11-25 (plan output at each size; `m` measured on a box)

Every pod and volume follows from two choices: the load (`box`, or `runs_per_second`) and the retention
(`short_ttl_days`, `long_ttl_days`). The data is [`infra/sizes.yaml`](infra/sizes.yaml), the arithmetic
[`infra/sizing.tf`](infra/sizing.tf), whose blocks follow this page's computation in order and by name.
`make plan` prints the result and refuses a machine that cannot hold it, before any machine exists.

## The computation

```
inputs   peak runs/s, readers, short and long TTL, extended %, payload mix, storage_factor, the machine

# pods: LangSmith's from the measured model; the rest per box, or fixed
for each LangSmith service s:                               # ace-backend only with code_evaluators
    s.cpu = max(50m, (s.idle + s.per_unit x s.work) x 1.5)  # work: runs/s, or readers
    s.mem = s.measured_peak x 1.2                           # limit: 2x, at least 256 MiB above
SmithDB, Postgres, RustFS = per box                         # Redis below; observability, Mission Control fixed

# what a run costs (decimal KB), weighted by the mix: 70% small, 25% medium, 5% large
kb = { smithdb: 12.0, blob: 13.7 + attachments, redis: 8.1 }

# the volumes: storage fills at the average, and keeps each run its TTL
runs_a_day      = peak / 3 x 86,400
smithdb_days    = 95% x (short + 5) + 5% x (long + 5)       # SmithDB deletes about 5 days after the TTL
blob_days       = 95% x short + 5% x long                   # extended_retention_pct = 5
object_store    = runs_a_day x (kb.smithdb x smithdb_days + kb.blob x blob_days) x storage_factor x 1.2
smithdb_cache   = max(10 GiB, runs_a_day x kb.smithdb x query_hot_days x 1.2)
redis.maxmemory = max(256 MiB, peak x kb.redis x run expiry x 1.3)   # a stalled ingest, the whole expiry
redis.memory    = maxmemory / 0.75                          # request = limit: reserved
postgres.max_connections = round up to 50 of (2 API pods x 50 + 2 workers x 3 + 20) / 0.8, at least 100

# the fit
allowed   = (machine - reserved for k3s) x 0.85             # CPU and memory
requested = every pod's request                            <= allowed
volumes   = object_store + cache + Redis + Postgres + Prometheus
          <= 80% of the data disk, or volumes + 40 GiB system <= 80% of the one disk
                                                            # k3s evicts under 15% free, cleans images at 80%
peak      <= 50 runs/s                                      # past it: a full deployment
```

## The sizes

<img alt="Each of the four sizes against its machine, at its design rate and the default retention. xs, 1 run a second on 2 vCPU, 16 GiB and 100 GiB: 1.27 of 1.36 vCPU, 8.6 of 12.8 GiB, 76 of 80 GiB of disk. s, 5 runs a second on 4 vCPU, 32 GiB and 200 GiB: 2.37 of 2.98 vCPU, 12.4 of 25.9 GiB, 147 of 160 GiB. m, 25 runs a second on 8 vCPU, 64 GiB and 640 GiB: 5.37 of 6.16 vCPU, 25.1 of 52.7 GiB, 508 of 512 GiB. l, 50 runs a second on 16 vCPU, 64 GiB and 1,280 GiB: 9.73 of 12.75 vCPU, 43.7 of 51.8 GiB, 984 of 1,024 GiB. CPU comes nearest its allowance at xs, s and m, memory at l. The allowance is 85% of what k3s leaves allocatable for CPU and memory, and 80% of the disk for the volumes and the system's 40 GiB." src="diagrams/sizes.png">

At the default TTLs (14 days, 30 extended), each size at its design rate:

| `box` | Machine | Peak runs/s | Runs a day | Requests of allowed | Volumes | Object store | Redis maxmemory |
|:--|:--|--:|--:|:--|--:|--:|--:|
| `xs` | 2 vCPU, 16 GiB, 100 GiB | 1 | 28,800 | 1.27 of 1.36 vCPU, 8.6 of 12.8 GiB | 36 GiB | 15 GiB | 256 MiB |
| `s` | 4 vCPU, 32 GiB, 200 GiB | 5 | 144,000 | 2.37 of 2.98 vCPU, 12.4 of 25.9 GiB | 107 GiB | 71 GiB | 1.1 GiB |
| `m` | 8 vCPU, 64 GiB, 640 GiB | 25 | 720,000 | 5.37 of 6.16 vCPU, 25.1 of 52.7 GiB | 468 GiB | 354 GiB | 5.3 GiB |
| `l` | 16 vCPU, 64 GiB, 1,280 GiB | 50 | 1,440,000 | 9.73 of 12.75 vCPU, 43.7 of 51.8 GiB | 944 GiB | 708 GiB | 10.6 GiB |

LangSmith's services ask their sampled memory peak x 1.2 and their CPU x 1.5, and the box lets requests
reach 85% of what k3s leaves allocatable, so a request is the buffer on a measurement and the box keeps
15% more on top. Memory binds before CPU, so `s` and `m` are memory-optimized machines (8 GiB a vCPU); on
4 GiB a vCPU, `s` could not hold Mission Control beside the buffered services. A run is one span: a trace
of 10 LLM and tool calls at one trace a second is 10 runs/s. `l` stops at 50 runs/s, LangChain's sizing
calculator's limit for one machine; past it the plan refuses and points at a full deployment
([`../aws`](../aws), [`../gcp`](../gcp), [`../azure`](../azure), [`../baremetal`](../baremetal)). `xs`
runs no observability stack or Mission Control of its own (an install a fleet watches from one stack),
which is what fits it in 2 vCPU.

## The cost

On AWS, at us-east-1 on-demand list prices (`infra/sizes.yaml`, read 2026-11), a month of 730 hours:

```
instance  = the size's type, hourly x 730               # or aws_hourly_usd, a negotiated price
disks     = (40 GiB system + data disk) x $0.08 gp3     # data disk = the volumes / 0.8, rounded up to 10 GiB
snapshots = the volumes x $0.05                         # incremental; the volumes bound them
address   = $0.005 x 730                                # the instance's fixed public address
```

| `box` | Instance | Instance | Disks | Snapshots | Address | Total |
|:--|:--|--:|--:|--:|--:|--:|
| `xs` | r7i.large | $96.58 | $7.20 | $1.80 | $3.65 | about $110 |
| `s` | r7i.xlarge | $193.16 | $14.40 | $5.35 | $3.65 | about $217 |
| `m` | r7i.2xlarge | $386.32 | $50.40 | $23.40 | $3.65 | about $464 |
| `l` | m7i.4xlarge | $588.67 | $97.60 | $47.20 | $3.65 | about $738 |

`make plan` prints the same for the box it plans, rounded up to the dollar. A machine of your own, or one
in another cloud, costs what you pay for it.

## What runs on box `s`

<img alt="Box s to scale, at 5 runs a second and 14 and 30 days of retention. Memory: 12.4 of its 32 GiB requested, against 25.9 GiB allowed; SmithDB, queue, Redis and ingest-queue are the largest requests. CPU: 2.37 of its 4 vCPU requested, against 2.98 allowed; SmithDB's is the largest, then Mission Control's and ingest-queue's. Disk: 147 of its 200 GiB, the system's 40, the object store's 71 for SmithDB's segments and the payloads, and 36 for the other volumes, against the 160 GiB the plan fills to. Colours mark the namespace: LangSmith's, the stores', observability's and k3s's own." src="diagrams/the-box.png">

| Pod | What it does | CPU | Memory (limit) |
|:--|:--|--:|--:|
| platform-backend | Go: the ingest API and auth | 50m | 615 MiB (1.2 GiB) |
| ingest-queue | Go: runs from Redis into SmithDB | 300m | 1.3 GiB (2.6 GiB) |
| queue | Python: LangSmith's background worker | 167m | 1.9 GiB (3.8 GiB) |
| backend | Python: the API the UI reads | 50m | 1.1 GiB (2.3 GiB) |
| frontend | the UI, and the nginx in front of every request | 66m | 154 MiB (410 MiB) |
| SmithDB | one pod: ingestion, queries, compaction | 750m | 3 GiB (6 GiB) |
| Redis | runs waiting for ingest-queue, the queues | 50m | 1.4 GiB, reserved |
| Postgres | LangSmith's database and SmithDB's metastore | 100m | 768 MiB, reserved |
| RustFS | the object store: SmithDB's bucket and the blob bucket | 100m | 768 MiB (3 GiB) |
| Prometheus, Grafana, 4 collectors | observability | 190m | 880 MiB |
| Mission Control (2 pods) | health and diagnostics; strictly read-only | 350m | 384 MiB |
| CoreDNS, metrics-server | k3s's own | 200m | 140 MiB |
| **Total** | | **2.37 vCPU** | **12.4 GiB** |
| ace-backend | custom code evaluators | off: `code_evaluators = true` runs it | |

The other sizes scale the same rows; `make plan` lists every pod.

## What the chart runs, and what Lite keeps

At chart 0.18, the chart's defaults against what Lite renders (`make render`; the plan lists the sizes):

| Chart default | Lite | Why |
|:--|:--|:--|
| platform-backend x3, ingest-queue x3, backend x2, frontend, queue | one each, sized from the rate or the readers | the tracing path; one box has no second node to spread onto |
| ClickHouse | off | SmithDB is the trace store at 0.18 |
| SmithDB as separate services (ingestion, query, compaction and its workers, a cluster manager, and stats-query, mutations and run rules where enabled) at the `small` tier | one unified pod, below that tier | one process for one machine's load; measured at `m` ([Where the numbers come from](#where-the-numbers-come-from)) |
| Insights and Polly, each with its own Postgres and Redis | off | products beyond tracing |
| playground | 0 replicas, always | prompts against model providers, not tracing |
| ace-backend | 0 replicas; `code_evaluators = true` runs it | runs custom code evaluators only; nothing on the tracing path calls it |
| the operator, Fleet's tool and trigger servers | off | LangGraph deployments and Fleet |
| the chart's e2e test pod | off | the chart's own CI |
| migrations, auth bootstrap, backfill check (Jobs) | kept | they set up the database and the first admin |

Kept and worth watching once a box has been measured, in order of what they would save on box `s`:

- **Mission Control** (350m, 384 MiB, about 15% of `s`'s CPU requests): strictly read-only now, it is a
  health view and a diagnostics bundle. `mission_control = false` drops it; the health dashboard covers
  the same signals.
- **queue** (167m, 1.9 GiB): LangSmith's Python background worker. The chart has no switch for it, so it
  stays; its memory, measured at the lab's load, is the largest app request after ingest-queue and the
  first to revisit once `make soak` reads it at `s`.
- **The observability stack** (190m, 880 MiB): what makes the alerts. `observability = false` drops it, as
  `xs` and a cluster do, when a shared stack watches the box.
- **SmithDB's query cache**: `query_hot_days` (7) sizes it; 3 days halves it where traces are read soon
  after they arrive.

## Each store

| Store | Holds | Grows with | Bounded by | Size |
|:--|:--|:--|:--|:--|
| RustFS, SmithDB's bucket | SmithDB's segments | runs a day x 12.0 KB | SmithDB's deletes, about 5 days after the TTL | `object_store` |
| RustFS, blob bucket | payloads of 20 KiB or more, attachments | runs a day x 13.7 KB | expiry rules on `ttl_s/`, `ttl_l/`; abandoned uploads aborted | `object_store` |
| SmithDB's query cache | recent segments, so reads skip RustFS | `query_hot_days` of writes | its volume | `smithdb_cache` |
| Redis | runs until ingested; queues | the rate x the run expiry | `maxmemory`, `noeviction` | `redis.maxmemory` |
| Postgres | orgs, projects, keys; SmithDB's segment metadata | use; the rate x the retention | compaction removes expired metadata | per box: 10, 10, 20, 50 GiB |
| Prometheus | metrics | `prometheus_retention_days` | `retentionSize`, four fifths of its volume | per box: none, 10, 20, 40 GiB |

Every volume is a folder on the data disk (k3s's local-path), not a quota; the plan keeps their sum
within 80% of the disk (the computation, the fit), and the health dashboard turns orange at 80% of each
disk and alerts at 90% ([OPERATE.md, Watching it](OPERATE.md#watching-it)).

## The retention

The TTLs size the disk more than anything else, so `make up` asks for them, and a plan made without them
says so on every run. The object store at box `s` (box `m` is five times each, `l` ten):

<img alt="The object store at box s's design rate for each pair of TTLs, short and extended: 41 GiB at 7 and 14 days, 71 GiB at the default 14 and 30, 84 GiB at 14 and 90, 146 GiB at 30 and 90, 148 GiB at 14 and 400, 446 GiB at 90 and 400: eleven times from the shortest to the longest." src="diagrams/retention.png">

| TTLs, days (short / extended) | 7 / 14 | 14 / 30 | 14 / 90 | 30 / 90 | 14 / 400 | 90 / 400 |
|:--|--:|--:|--:|--:|--:|--:|
| Object store | 41 GiB | 71 GiB | 84 GiB | 146 GiB | 148 GiB | 446 GiB |

Every number assumes 5% of traces on extended retention (`extended_retention_pct`). The measured
payloads compress well; real text can take 2 to 5 times the storage (`storage_factor`). The chart
refuses a long TTL under 14 days, and so does the plan.

## Where the numbers come from

| Number | Source |
|:--|:--|
| LangSmith's services (idle and per-unit cores, memory) | the bare-metal lab: 3 runs a trace, about 180 KiB a run, 5 s samples over ten minutes (2026-10-31, 2026-11-01, Reed Bender) |
| The 2-CPU limit on the Go services | ingest-queue throttled in 98% of periods under 1 CPU at 4.3 traces/s (2026-10-22; terraform#513, Michael Frederick) |
| What a run costs in each store | LangChain's trace payload measurements and load tests of LangSmith 0.17.6 with SmithDB (2026-11, Dzmitry Dubarau) |
| Peak factor 3, headroom 1.2, Redis 1.3, the connection budget, 50 runs/s on one machine | LangChain's sizing calculator ([`utils/langsmith-sizing`](../../utils/langsmith-sizing)) |
| SmithDB, Postgres, RustFS per box | the bare-metal module's tested profiles; RustFS's 6 GiB limit at `m` from the lab, where 2 GiB was OOM-killed 9 times at 70 to 80 traces/s (about 210 to 240 runs/s, far past `m`'s 25): headroom, not a measured need |

Lite and the calculator share the services model, the payload costs, the peak factor, Redis's
reservation and headroom, the connection formula and the single-machine limit. They differ on purpose
in two places: Lite's extended TTL is 30 days, not the chart's 400 (a single disk stays bounded), and
SmithDB runs as one pod below the chart's smallest tier, with the metastore a second database in the
one Postgres.

**First measured, at `m` on magus (2026-11-25, chart 0.18.3, the load test's default payload mix, five
runs from 12.5 to 75 runs/s):** every run stored at every rate; SmithDB used 1.5 to 1.6 cores whatever
the rate; the services the plan sizes by rate used about a fifth of what it budgets them (ingest-queue
0.0066 cores a run/s against 0.035 planned); Redis kept 1.6 KiB a run at every rate, against the 8 KB
the payload costs plan, as 0.18 frees saved payloads from Redis. These are one size and a few hours of
history: the plan's numbers stay until `make experiment` has measured every size, and a size changes
only with its runs cited.

**Not yet measured:** each size other than `m`, the bytes a run costs on disk, the metastore's growth,
and Mission Control's and the observability stack's own use; `make experiment` reads each. A measured
size then replaces a computed one through `resources` (keyed as the plan lists the pods) or `volumes`,
with the run cited beside it in the tfvars.

## Settings

| Setting | Default | Drives |
|:--|:--|:--|
| `box`, `machine` | `s`, the size's | the design load and every per-box size; `machine` for a box of another shape |
| `runs_per_second`, `readers` | the size's | LangSmith's pods, the object store, Redis |
| `short_ttl_days`, `long_ttl_days` | asked; 14 and 30 | LangSmith's TTLs, SmithDB's retention, the bucket's expiry rules, the object store |
| `extended_retention_pct` | 5 | the share of traces kept for the long TTL |
| `payload_mix_pct`, `storage_factor`, `attachment_kib_per_run` | 70/25/5, 1, 0 | what a run costs |
| `query_hot_days` | 7 | SmithDB's query cache |
| `redis_runs_expiry_hours` | 6 | how long a run waits for ingest before it is dropped; Redis's memory |
| `postgres_max_connections` | derived (200) | Postgres's connection limit |
| `max_payload_mb`, `blob_min_kb` | 25, 20 | the largest request; the size a payload goes to RustFS at |
| `prometheus_retention_days` | 15 | days of metrics |
| `observability`, `mission_control` | on, but off at `xs` and on a cluster | the stack on the box |
| `code_evaluators` | off | ace-backend, for custom code evaluators |
| `resources`, `volumes`, `max_request_ratio` | none, none, 0.85 | a measured size in place of a computed one; the share of the machine pods may request |
| `emulate_machine` | off | bare metal: every pod together held to the size's machine less its reservation, to measure a smaller size on a larger box (`make experiment` sets it for its own installs) |
