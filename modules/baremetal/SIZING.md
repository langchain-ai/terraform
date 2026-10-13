# Sizing

The sizing profiles are starting points. This page gives the formulas to size for a specific workload. The coefficients
were measured on a small bare-metal cluster (6-core nodes, NVMe, 1 GbE) with chart 0.17.x; treat them as planning
estimates, keep the safety factors, and validate with a load test at your own trace shape before ordering hardware.

## Inputs to collect

| Input | Symbol | Notes |
|---|---|---|
| Traces per month (or per second) | `T` | design rate = monthly ÷ 2,592,000 × 1.25 peak factor |
| Runs per trace | `n` | 1 for a single LLM call; agents often 5–20+. **The most important number to get right** |
| Payload size per run, and how it splits | `p` | inputs/outputs/events/error parts; parts ≥ 20 KB go to blob storage |
| Concurrent UI users, API/SDK read rate | `U`, `A` | reads, not ingest |
| Retention | | object storage |

`R = T × n` is the run rate (runs/s). Most of the sizing scales with `R`, not `T`.

## Redis

Redis keeps every run for `E` = `redisRunsExpirySeconds` after it is ingested.

```
retained_per_run  ≈ Σ payload parts below the blob threshold (compressed) + 0.5–2.5 KB
Redis_steady      ≈ R × retained_per_run × E
maxmemory         ≥ 1.3 × Redis_steady        (+ headroom for bursts the queue hasn't drained yet)
memory limit      = maxmemory ÷ 0.75          (RDB fork and fragmentation)
CPU limit         ≥ 2 cores                   (one thread does the work; it throttles at 1)
```

Measured `retained_per_run`, blob storage on:

| Payload | Redis per run |
|---|---|
| fields above the 20 KB threshold (offloaded) | ~3 KB |
| agent traces with 1–2 MiB payloads | ~11–12 KB (about 100 KB with blob storage off) |
| fields just below the threshold (e.g. 16 KB) | ~23 KB: they stay in Redis |
| small traces (4 KB fields) | ~10 KB |

**Choose `E` deliberately:** at least 3 × the worst ingest backlog age (runs queued past it are dropped without an error),
at least your longest-running run, and no longer than needed. With the 6 h default, Redis at production rates becomes
very large: e.g. 2,000 runs/s × 10 KB × 21,600 s ≈ 430 GB, against ~36 GB at 30 minutes.

## Ingest workers (ingest-queue)

The drain from Redis into SmithDB waits on I/O, so worker count, not CPU, sets its capacity.

```
workers per pod  = GO_INGESTION_CONCURRENCY_PER_CPU × CPU cores of the NODE the pod runs on
drain capacity   ≈ workers × 10–25 runs/s     (~25 with small payloads and blob off; plan ~10 with blob on)
workers needed   ≈ R ÷ 10                     (blob on, with headroom); × 1.5 while dual-writing ClickHouse + SmithDB
backlog age      = pending runs ÷ drain rate  → keep well below E
```

Prefer KEDA on queue depth over CPU autoscaling for ingest-queue: it sits at low CPU while a backlog grows.

## Accept path (platform-backend)

CPU-bound. Plan ~1–1.5 cores per 1,000 runs/s accepted, plus the blob uploads (~2 cores per pod, one pod per ~500
runs/s with large payloads), plus a share for read requests it proxies. Minimum 3 pods in production. In tests, 3 pods
accepted ~1,000 small traces/s at p95 < 80 ms; with offloaded 32 KB fields upload p95 rose to ~650 ms.

## Reads (smithdb-query)

```
read req/s         ≈ U × 1 (UI) + A (API/SDK)
query pods         ≥ read req/s ÷ 30 × 1.5           (one pod served ~30 req/s of a UI mix)
latency at saturation ≈ concurrent readers ÷ 30 s    (32 readers ≈ 1 s median)
```

A request used about one core even on a larger pod, so add **replicas**, not cores. Confirm that replicas share load for
a single workspace in your version: queries are routed per workspace. Reads of a project being written are served by
the ingestion pods; see [SMITHDB.md](SMITHDB.md#reads-of-a-project-being-written).

## SmithDB memory

Payload size drives SmithDB ingestion and compaction-worker memory more than CPU. With MiB-scale payloads, give each at
least 8 GiB of limit, and size the compaction-worker scratch volume generously (merges write temporary files). With
small payloads, SmithDB ingestion used well under one core at 1,000+ runs/s.

## Object storage

```
SmithDB bucket  ≈ traces stored × payload size ÷ compression (plan 3:1, range 2:1–4:1) × 1.3 headroom
blob bucket     ≈ offloaded payload bytes over the retention window (SmithDB keeps its own copy as well)
```

Measure bytes per trace on a test environment with real traces to narrow the compression range.

## Worked example

`T` = 100 traces/s, `n` = 5 → `R` = 500 runs/s; agent payloads with blob storage on (~10 KB/run); `E` = 1,800 s;
20 UI users, 10 API req/s.

| Item | Result |
|---|---|
| Redis | 500 × 10 KB × 1,800 s ≈ 9 GB → maxmemory 12 GiB, memory limit 16 GiB, 2 CPU |
| Ingest workers | 500 ÷ 10 = 50 → 2 ingest-queue pods at 24–32 workers each |
| platform-backend | 3 pods (production minimum) |
| Query | 30 req/s ÷ 30 × 1.5 → 2 pods |
| SmithDB ingestion | 2 pods, memory sized for payloads |

Then check the total against `cluster_nodes`: the budget gate (`make plan`) does this for you.
