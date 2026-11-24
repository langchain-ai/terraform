# Sizing

> **Status:** current · **Last verified:** 2026-11-24

How Lite sizes every pod and volume from the load and the TTLs, what bounds each store, how it decides a
box fits, and which numbers are measured. The data is `infra/sizes.yaml`, the arithmetic
`infra/sizing.tf`; `make plan` prints the result and refuses a box that does not hold it.

## The whole computation

```
inputs   peak runs/s, readers, short and long TTL, payload mix, storage_factor, run expiry, the machine

# pods: LangSmith's from the measured model, the rest fixed
for each LangSmith service s:                           # off: playground, ace-backend (unless asked)
    s.cpu    = max(50m, (s.idle + s.per_unit x s.work) x 1.5)     # work: runs/s, readers, or nothing
    s.memory = s.measured_peak
stores, SmithDB, observability, Mission Control = per box or fixed (sizes.yaml)

# what a run costs, by the mix (70% small, 25% medium, 5% large by default)
kb = mix-weighted { smithdb: 12.0, blob: 13.7, redis: 8.1 }      # decimal KB a run

# volumes
runs_a_day    = peak / 3 x 86,400                       # storage fills at the average
smithdb_days  = 95% x (short + 5) + 5% x (long + 5)     # SmithDB deletes about 5 days after the TTL
blob_days     = 95% x short + 5% x long                 # 5% of runs on extended retention
object_store  = runs_a_day x (kb.smithdb x smithdb_days + kb.blob x blob_days) x storage_factor x 1.2
redis.limit   = max(box's, peak x kb.redis x expiry / 0.75)     # a stalled ingest, held for the expiry
redis.volume  = max(box's, redis.limit)                 # it snapshots its memory to disk
postgres, smithdb_cache, prometheus = per box

# fit
allowed   = (machine - reserved) x 0.85                 # per CPU and memory; reserved goes to the kubelet
requested = sum of every pod's request                  <= allowed
disk      = sum of every volume + 30 GiB of images      <= the machine's disk
stall     = requested - redis.request + redis.limit     <= machine memory - reserved
```

## What runs, and what it costs

Every pod on box `s` at its design rate (5 runs/s, 2 readers), as requests; the other boxes scale the
same rows (the `plan` output lists every pod).

| Pod | What it does | For tracing | CPU | Memory |
|:--|:--|:--|--:|--:|
| platform-backend | Go: the ingest API (`/runs`, `/runs/multipart`), auth | yes | 50m | 512 MiB |
| ingest-queue | Go: drains runs from Redis into SmithDB | yes | 300m | 1126 MiB |
| queue | Python: LangSmith's background worker (no switch in the chart) | yes | 167m | 1638 MiB |
| backend | Python: the API the UI reads | yes | 50m | 973 MiB |
| frontend | the UI, and the nginx in front of every request | yes | 66m | 128 MiB |
| SmithDB | one unified pod: ingestion, queries, compaction | yes | 750m | 3072 MiB |
| Postgres, Redis, RustFS | the stores (below) | yes | 250m | 1792 MiB |
| Prometheus, Grafana, 4 collectors | observability | kept, to watch the box | 190m | 880 MiB |
| Mission Control (2 pods) | health, preflight, diagnostics | kept, for support | 350m | 384 MiB |
| CoreDNS, metrics-server | k3s's own | yes | 200m | 140 MiB |
| **Total** | | | **2.37 vCPU** | **10.4 GiB** |
| playground | prompt playground and experiments | off; `playground = true` | 50m | 922 MiB |
| ace-backend | custom code evaluators | off; `code_evaluators = true` | 50m | 128 MiB |

The chart has no switch for playground or ace-backend, so Lite runs each at zero replicas; nothing on
the tracing path calls either. Mission Control's requests are its chart's defaults, not a measurement,
and are the first to trim once a running box shows its use.

## Each store: what grows it, what bounds it

| Store | Holds | Grows with | The TTLs | Bounded by | Size |
|:--|:--|:--|:--|:--|:--|
| RustFS, blob bucket | payloads of 20 KiB or more | runs a day x 13.7 KB | kept exactly the short or long TTL | its expiry rules on `ttl_s/` and `ttl_l/` | derived: `object_store` |
| RustFS, SmithDB's bucket | SmithDB's segments | runs a day x 12.0 KB | kept the TTL plus about 5 days | SmithDB's own deletes, in compaction | derived: `object_store` |
| SmithDB's query cache | recent segments, so reads skip RustFS | what people read | none | `SMITHDB__DISK_LIMIT`, from its volume | per box: 20, 50, 100 GiB |
| Redis | runs waiting for ingest-queue; queues; caches | the rate x the run expiry | none: the run expiry, not the TTL | `maxmemory` at `noeviction` | derived: `redis.limit` |
| Postgres, LangSmith's database | orgs, projects, datasets, rules, keys | use, not trace traffic | none | nothing | per box: 10, 20, 50 GiB |
| Postgres, SmithDB's metastore | metadata for every retained segment | the rate x the retention | proportional | SmithDB's compaction removes expired metadata | in Postgres's volume; unmeasured |
| Prometheus | metrics | its retention | `prometheus_retention_days` | `retentionSize`, four fifths of its volume | per box: 10, 20, 40 GiB |

Kubernetes reserves CPU and memory through requests, but no disk: every volume is a folder on the box's
disk (local-path), not a quota. The plan keeps their sum within the disk; each store but Postgres keeps
itself within its size.

## What a box keeps

What a run costs, from LangChain's trace payload measurements and load tests of LangSmith 0.17.6 with
SmithDB (2026-11, Dzmitry Dubarau):

| Run size | Share | Inputs + outputs | SmithDB's bucket | Blob bucket | Redis until ingested |
|:--|--:|:--|--:|--:|--:|
| small | 70% | 4 + 4 KiB | 3.75 KB | 0 | 9.7 KB |
| medium | 25% | 32 + 32 KiB | 15 KB | 38 KB | 2.9 KB |
| large | 5% | about 1.5 MB | 112 KB | 84 KB | 12 KB |
| **the mix** | | | **12.0 KB** | **13.7 KB** | **8.1 KB** |

At the default TTLs (14 days, 30 extended):

| `box` | Machine | Peak runs/s | Runs a day | Object store | Redis limit | All volumes | Requests of allowed |
|:--|:--|--:|--:|--:|--:|--:|:--|
| `s` | 4 vCPU, 16 GiB, 160 GiB | 5 | 144,000 | 71 GiB | 1.5 GiB | 115 GiB | 2.4 of 3.0 vCPU, 10.4 of 12.3 GiB |
| `m` | 8 vCPU, 32 GiB, 512 GiB | 25 | 720,000 | 354 GiB | 5.4 GiB | 456 GiB | 5.4 of 6.2 vCPU, 18.1 of 25.5 GiB |
| `l` | 16 vCPU, 64 GiB, 1,536 GiB | 80 | 2,304,000 | 1,133 GiB | 17.4 GiB | 1,355 GiB | 12.0 of 12.8 vCPU, 30.6 of 51.8 GiB |

Each preset's rate is what its CPU holds, and its disk what that rate keeps. The TTLs are the largest
lever on the disk; the object store at box `s` (box `m` is five times each):

| TTLs, days (short / extended) | 7 / 14 | 14 / 30 | 14 / 90 | 30 / 90 | 14 / 400 | 90 / 400 |
|:--|--:|--:|--:|--:|--:|--:|
| Object store | 40 GiB | 71 GiB | 83 GiB | 146 GiB | 147 GiB | 446 GiB |

The measured payloads compress well; real text can take 2 to 5 times the storage, which
`storage_factor` says. The chart's own long TTL is 400 days; Lite's 30 keeps one box's disk bounded, and
the chart refuses a long TTL under 14 days, as does the plan.

## LangSmith's services: the measured model

Measured on the bare-metal lab (3 runs a trace, about 180 KiB a run, 5 s samples over ten minutes;
2026-10-31 and 2026-11-01, Reed Bender):

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
Michael Frederick). A request past that limit lifts the limit with it, since Kubernetes refuses a limit
below its request. Memory limits are twice the request, at least 256 MiB above it.

## The stores and SmithDB, per box

| `box` | SmithDB (one pod) | Postgres | Redis (request) | RustFS |
|:--|:--|:--|:--|:--|
| `s` | 0.75 CPU, 3 GiB; cache 20 GiB | 0.1 CPU, 512 MiB; 10 GiB | 0.05 CPU, 512 MiB | 0.1 CPU, 768 MiB |
| `m` | 2 CPU, 8 GiB; cache 50 GiB | 0.25 CPU, 1.5 GiB; 20 GiB | 0.1 CPU, 1 GiB | 0.25 CPU, 2 GiB |
| `l` | 4 CPU, 16 GiB; cache 100 GiB | 0.5 CPU, 3 GiB; 50 GiB | 0.25 CPU, 2 GiB | 0.5 CPU, 4 GiB |

Limits are in `sizes.yaml`. RustFS's 6 GiB limit on `m` is the bare-metal lab profile's: at 2 GiB it
was killed for memory 9 times under about 70 to 80 traces/s of SmithDB's flushes.

## Beside the sizing calculator

The sizing calculator (`utils/langsmith-sizing`, on `feat/sizing-canon`) at the same loads:

| | Calculator | Lite |
|:--|:--|:--|
| LangSmith's services | the measured model | the same model, the same numbers |
| Payload costs, peak factor, storage headroom | measured | the same |
| Extended TTL | the chart's 400 days | 30 days: half the calculator's volumes at box `s` |
| SmithDB | the chart's smallest tier, 4 CPU and 16 GiB: one pod is unmeasured | below it, per box |
| Metastore | the docs' 2 CPU and 16 GiB, apart | a second database in the one Postgres |
| Redis | requests its whole payload memory, with 1.3 headroom | a small request; the limit holds a stall |
| Postgres connections | 50 an API pod plus each worker's pool, within 80% of `max_connections` | a fixed 200 |
| One machine | up to 5 traces/s at peak (50 runs/s); above, two nodes | box `l` at 80 runs/s |
| Box `s` in total | 7.0 vCPU, 31.6 GiB, 317 GiB | 2.4 vCPU, 10.4 GiB, 115 GiB |

The last four rows are open: PROPOSALS.md says what Lite takes from the calculator and why.

## What is not measured

- **SmithDB as one pod**, below the chart's smallest tier, at each box. The first install of each box
  measures it.
- **The SmithDB metastore's growth** in Postgres, per GB SmithDB stores.
- **The payload costs at chart 0.18**: measured on 0.17.6. 0.18 deletes large fields from Redis once
  saved, which can only lower Redis's share.
- **Postgres connections**, Mission Control's use, and the observability stack's.
- **The model above about 280 runs/s** (the lab's 93 traces/s at 3 runs a trace).

A measured size replaces a computed one with `resources` (keyed as the plan output's `pods`), and a
measured volume with `volumes`; cite the run beside it in your tfvars.

## Settings

| Setting | Default | Drives |
|:--|:--|:--|
| `box`, `machine` | `s`, the preset's | the machine, the design load, every per-box size |
| `runs_per_second`, `readers` | the preset's | LangSmith's pods, the object store, Redis |
| `short_ttl_days`, `long_ttl_days` | 14, 30 | LangSmith's TTLs, SmithDB's retention, the expiry rules, the object store |
| `payload_mix_pct`, `storage_factor` | 70/25/5, 1 | the object store and Redis |
| `redis_runs_expiry_hours` | 6 | how long a run waits for ingest before it is dropped; Redis's limit |
| `max_payload_mb`, `blob_min_kb` | 25, 20 | the largest request body; the size a payload goes to RustFS at |
| `prometheus_retention_days` | 15 | days of metrics |
| `playground`, `code_evaluators` | off | the two services beyond tracing |
| `resources`, `volumes`, `max_request_ratio` | none, none, 0.85 | a measured size in place of a computed one; the share of the box pods may request |
