# Sizing

> **Status:** current · **Last verified:** 2026-11-24

What runs on a Lite box and what it costs, how much data a box keeps, how Lite decides a box fits,
and which numbers are measured and which are not. The data is `infra/sizes.yaml`; the arithmetic is
`infra/sizing.tf`; `make plan` prints the result and refuses a box that does not hold it.

## What runs, and what it costs

Every pod on box `s` at its design rate (5 runs/s, 2 readers), as requests; the other boxes scale the
same rows (the `plan` output lists every pod).

| Pod | What it does | Needed for tracing | CPU | Memory |
|:--|:--|:--|--:|--:|
| platform-backend | Go: the ingest API (`/runs`, `/runs/multipart`), auth | yes | 50m | 512 MiB |
| ingest-queue | Go: drains runs from Redis into SmithDB and the blob bucket | yes | 300m | 1126 MiB |
| queue | Python: LangSmith's background worker (the chart has no switch for it) | yes | 167m | 1638 MiB |
| backend | Python: the API the UI reads | yes | 50m | 973 MiB |
| frontend | the UI, and the nginx in front of every request | yes | 66m | 128 MiB |
| SmithDB | one unified pod: ingestion, queries, compaction | yes | 750m | 3072 MiB |
| Postgres | LangSmith's database and SmithDB's metastore | yes | 100m | 512 MiB |
| Redis | the ingest queue's buffer, caches | yes | 50m | 512 MiB |
| RustFS | S3 on the box's disk: SmithDB's segments and the payload blobs | yes | 100m | 768 MiB |
| Prometheus, Grafana, kube-state-metrics, node-exporter, 2 exporters | observability | no; kept so the box can be watched | 190m | 880 MiB |
| Mission Control (2 pods) | health, preflight, diagnostics | no; kept for support | 350m | 384 MiB |
| CoreDNS, metrics-server | k3s's own | yes | 200m | 140 MiB |
| **Total** | | | **2.37 vCPU** | **10.4 GiB** |

Turned off for tracing, each a variable to turn back on:

| Pod | What it does | Off by | Frees |
|:--|:--|:--|:--|
| playground | the UI's prompt playground and experiments, which call model providers | `playground = false` (default) | 50m, 922 MiB |
| ace-backend | runs custom code evaluators | `code_evaluators = false` (default) | 50m, 128 MiB |
| Insights, Polly, Fleet, Deployments, Sandboxes, ClickHouse, operator | products beyond tracing, and the store SmithDB replaces | chart values (`values.tf`) | not deployed at all |

The chart has no switch for playground or ace-backend, so Lite runs each at zero replicas; nothing on
the tracing path calls either. Observability and Mission Control are a quarter of box `s`'s CPU
requests: Mission Control's are its chart's defaults, not a measurement, and are the first to trim
when its use on a running box is known.

## How much data a box keeps

The object store's volume and Redis's limit are derived from the design rate, never a fixed number.
What a run costs, from LangChain's trace payload measurements and load tests of LangSmith 0.17.6 with
SmithDB (2026-11, Dzmitry Dubarau):

| Run size | Share by default | Inputs + outputs | SmithDB's bucket | Blob bucket | Redis until ingested |
|:--|--:|:--|--:|--:|--:|
| small | 70% | 4 + 4 KiB | 3.75 KB | 0 | 9.7 KB |
| medium | 25% | 32 + 32 KiB | 15 KB | 38 KB | 2.9 KB |
| large | 5% | about 1.5 MB | 112 KB | 84 KB | 12 KB |
| **the mix** | | | **12.0 KB** | **13.7 KB** | **8.1 KB** |

```
runs a day      = runs_per_second / 3 x 86,400             storage fills at the average; the design rate is the peak
SmithDB's days  = 95% x (short TTL + 5) + 5% x (long TTL + 5)   SmithDB deletes about 5 days after the TTL
blob days       = 95% x short TTL + 5% x long TTL               5% of runs on extended retention
object store    = runs a day x (12.0 KB x SmithDB's days + 13.7 KB x blob days) x storage_factor x 1.2 headroom
Redis's limit   = runs_per_second x 8.1 KB x redis_runs_expiry_hours / 0.75
```

At the default TTLs (14 days, 30 extended) and `storage_factor = 1`:

| `box` | Peak runs/s | Runs a day | Object store | Redis limit (6 h of stalled ingest) | All volumes |
|:--|--:|--:|--:|--:|--:|
| `s` | 5 | 144,000 | 71 GiB | 1.5 GiB | 115 GiB |
| `m` | 25 | 720,000 | 354 GiB | 5.4 GiB | 456 GiB |
| `l` | 80 | 2,304,000 | 1,133 GiB | 17.4 GiB | 1,355 GiB |

Storage is linear in the rate, the retention and the payload: halve any of them and the object store
halves. The measured payloads compress well; real text can take 2 to 5 times the storage, which
`storage_factor` says. `payload_mix_pct` sets a different mix. Redis's limit holds a stalled ingest for
the whole expiry, so runs are dropped only by their expiry, never by a full Redis refusing writes; its
request stays small, since a healthy ingest keeps it nearly empty.

## The fit

```
allowed   = (machine - reserved) x max_request_ratio        per CPU and memory
requested = every pod's request                             must be <= allowed
disk      = every volume + 30 GiB for images and logs        must be <= the machine's disk
stall     = requested - Redis's request + Redis's limit      must be <= the machine's memory - reserved
```

`reserved` is what k3s, the kubelet and the OS keep, passed to the kubelet as `system-reserved`, so
Kubernetes' allocatable is what the plan assumed. `max_request_ratio` (0.85) leaves room for bursts
above requests and for an upgrade's hook Jobs, which Helm runs one at a time for a minute or two; a box
runs nothing else, so it is higher than a shared cluster's 0.7.

| `box` | Machine | Requested of allowed | Disk used |
|:--|:--|:--|:--|
| `s` | 4 vCPU, 16 GiB, 160 GiB | 2.4 of 3.0 vCPU (79%), 10.4 of 12.3 GiB (84%) | 90% |
| `m` | 8 vCPU, 32 GiB, 512 GiB | 5.4 of 6.2 vCPU (87%), 18.1 of 25.5 GiB (71%) | 94% |
| `l` | 16 vCPU, 64 GiB, 1,536 GiB | 12.0 of 12.8 vCPU (93%), 30.6 of 51.8 GiB (59%) | 90% |

Each preset's design rate is what its CPU holds; its disk is what that rate's traces need for the
default TTLs. A smaller rate or a shorter TTL fits on less disk, and `make plan` says by how much.

## LangSmith's pods: the measured model

Each of LangSmith's own pods is sized from what it was measured to use on the bare-metal lab (3 runs a
trace, about 180 KiB a run, 5 s samples over ten minutes; 2026-10-31 and 2026-11-01, Reed Bender):

```
cpu    = max(50m, (idle + per_unit x work) x 1.5)
memory = its sampled peak
```

| Pod | Work | Idle (cores) | Per unit | Memory | CPU limit |
|:--|:--|--:|--:|--:|--:|
| ingest-queue | runs/s processed | 0.025 | 0.035 | 1126 MiB | 2 |
| queue | runs/s processed | 0.082 | 0.0058 | 1638 MiB | 1 |
| platform-backend | runs/s offered | 0.003 | 0.0045 | 512 MiB | 2 |
| frontend | readers | 0.001 | 0.0214 | 128 MiB | 0.5 |
| backend | readers | 0.013 | 0.0012 | 973 MiB | 2 |
| playground | none | 0.005 | | 922 MiB | 1 |
| ace-backend | none | 0.001 | | 128 MiB | 0.25 |

The Go services keep a 2-CPU limit: Go sets `GOMAXPROCS` from the limit, and under a 1-CPU limit
ingest-queue was throttled in 98% of periods at 4.3 traces/s on the lab (2026-10-22; terraform#513,
Michael Frederick). Past the measured rates a request can exceed that limit, and the limit then rises
with it, since Kubernetes refuses a limit below its request. Memory limits are twice the request, at
least 256 MiB above it.

## The stores and SmithDB, per box

| `box` | SmithDB (one unified pod) | Postgres | Redis (request) | RustFS |
|:--|:--|:--|:--|:--|
| `s` | 0.75 CPU, 3 GiB; cache 20 GiB | 0.1 CPU, 512 MiB; 10 GiB | 0.05 CPU, 512 MiB | 0.1 CPU, 768 MiB |
| `m` | 2 CPU, 8 GiB; cache 50 GiB | 0.25 CPU, 1.5 GiB; 20 GiB | 0.1 CPU, 1 GiB | 0.25 CPU, 2 GiB |
| `l` | 4 CPU, 16 GiB; cache 100 GiB | 0.5 CPU, 3 GiB; 50 GiB | 0.25 CPU, 2 GiB | 0.5 CPU, 4 GiB |

Limits are in `sizes.yaml`. RustFS's 6 GiB limit on `m` is the bare-metal lab profile's: at 2 GiB it
was killed for memory 9 times under about 70 to 80 traces/s of SmithDB's flushes, and each kill failed
SmithDB's writes. Redis's volume holds its whole `maxmemory`, which it snapshots to disk.

## What is not measured

- **SmithDB as one pod.** Chart 0.18's smallest tier for the unified pod asks 4 CPU and 16 GiB, the
  whole of box `s`. Lite's sizes are the bare-metal module's tested minimal tier for the query,
  ingestion and compaction pods the unified pod replaces, not a measurement of it. The first install
  of each box measures it.
- **The model above about 100 runs/s.** The lab runs reached about 93 traces/s at 3 runs a trace; box
  `l` at 80 runs/s is inside that, `runs_per_second` above it is extrapolation.
- **The payload costs at chart 0.18.** They were measured on 0.17.6 with SmithDB; 0.18 deletes large
  fields from Redis once saved, which can only lower Redis's share.
- **Postgres connections.** `max_connections` is 200; the plan does not count each pod's pool. The
  Postgres dashboard shows connections in use; raise `postgres_max_connections` before they reach it.
- **Mission Control's and the observability stack's use.** Their charts' requests, until a running box
  shows what they use.

A measured size replaces a computed one with `resources` (keyed as the plan output's `pods`), and a
measured object store with `volumes`; cite the run beside it in your tfvars.

## Retention and payloads

| Setting | Default | Drives |
|:--|:--|:--|
| `short_ttl_days` | 14 | LangSmith's short TTL; the blob bucket's `ttl_s/` expiry; the object store's size |
| `long_ttl_days` | 30 | LangSmith's long TTL; SmithDB's long-term retention; the blob bucket's `ttl_l/` expiry |
| `payload_mix_pct` | 70, 25, 5 | The share of small, medium and large runs; the object store's and Redis's size |
| `storage_factor` | 1 | Times the measured storage your runs take: 2 to 5 for real text |
| `max_payload_mb` | 25 | The frontend's request body limit (a batch of runs, or one run with attachments) |
| `blob_min_kb` | 20 | Payloads at or above it go to RustFS rather than SmithDB's rows |
| `redis_runs_expiry_hours` | 6 | How long a run waits in Redis for the workers before it is dropped; Redis's limit |
| `prometheus_retention_days` | 15 | Days of metrics, within four fifths of Prometheus's volume |

The chart's own long TTL is 400 days; Lite's 30 keeps one box's disk bounded. The chart refuses a long
TTL under 14 days, and so does the plan.
