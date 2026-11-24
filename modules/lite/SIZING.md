# Sizing

> **Status:** current · **Last verified:** 2026-11-23

How Lite sizes every pod, how it decides a box fits, and which numbers are measured and which are not.
The data is `infra/sizes.yaml`; the arithmetic is `infra/sizing.tf`; `make plan` prints the result
(the `plan` output) and refuses a box that does not hold it.

## The fit

```
allowed   = (machine - reserved) x max_request_ratio        per CPU and memory
requested = every pod's request                             must be <= allowed
disk      = every volume + 30 GiB for images and logs        must be <= the machine's disk
```

`reserved` is what k3s, the kubelet and the OS keep, and is passed to the kubelet as
`system-reserved`, so Kubernetes' allocatable is what the plan assumed. `max_request_ratio` (0.85)
leaves room for pods to burst above their requests, and for an upgrade's hook Jobs (the migrations),
which Helm runs one at a time for a minute or two; a box runs nothing else, so it is higher than a
shared cluster's 0.7.

Requests are what the scheduler reserves and what the fit adds up; limits are a ceiling for bursts and
are not counted. Memory limits are twice the request (at least 256 MiB above it); CPU limits are per
pod (below).

## LangSmith's pods: a measured model

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
with it, since Kubernetes refuses a limit below its request.

## The stores and SmithDB: per box

| `box` | SmithDB (one unified pod) | Postgres | Redis | RustFS |
|:--|:--|:--|:--|:--|
| `s` | 0.75 CPU, 3 GiB; cache 20 GiB | 0.1 CPU, 512 MiB; 10 GiB | 0.05 CPU, 512 MiB; 2 GiB | 0.1 CPU, 768 MiB; 40 GiB |
| `m` | 2 CPU, 8 GiB; cache 50 GiB | 0.25 CPU, 1.5 GiB; 20 GiB | 0.1 CPU, 1 GiB; 4 GiB | 0.25 CPU, 2 GiB; 100 GiB |
| `l` | 4 CPU, 16 GiB; cache 100 GiB | 0.5 CPU, 3 GiB; 50 GiB | 0.25 CPU, 2 GiB; 8 GiB | 0.5 CPU, 4 GiB; 250 GiB |

Limits are in `sizes.yaml`. RustFS's 6 GiB limit on `m` is the bare-metal lab profile's: at 2 GiB it
was killed for memory 9 times under about 70 to 80 traces/s of SmithDB's flushes, and each kill failed
SmithDB's writes. Redis's `maxmemory` is three quarters of its limit, at `noeviction`.

The observability stack, Mission Control (its chart's own requests), the exporters and what k3s runs
with requests (CoreDNS, metrics-server) are fixed sizes, in `sizes.yaml` under `fixed`.

## What is not measured

- **SmithDB as one pod.** Chart 0.18's smallest tier for the unified pod asks 4 CPU and 16 GiB, the
  whole of box `s`. Lite's sizes are the bare-metal module's tested minimal tier for the query,
  ingestion and compaction pods the unified pod replaces, not a measurement of it. The first install
  of each box measures it.
- **The model above about 100 runs/s.** The lab runs reached about 93 traces/s at 3 runs a trace; box
  `l` at 80 runs/s is inside that, `runs_per_second` above it is extrapolation.
- **Postgres connections.** `max_connections` is 200; the plan does not count each pod's pool. The
  Postgres dashboard shows connections in use; raise `postgres_max_connections` before they reach it.
- **The object store's growth.** `object_store_gi` is a preset, not derived from the rate and the
  retention; the RustFS volume's use, in Grafana's node dashboard and `make status`, says when to grow
  it.

A measured size replaces a computed one with `resources` (keyed as the plan output's `pods`); cite the
run beside it in your tfvars.

## Retention and payloads

| Setting | Default | Drives |
|:--|:--|:--|
| `short_ttl_days` | 14 | LangSmith's short TTL; the blob bucket's `ttl_s/` expiry |
| `long_ttl_days` | 30 | LangSmith's long TTL; SmithDB's long-term retention; the blob bucket's `ttl_l/` expiry |
| `max_payload_mb` | 25 | The frontend's request body limit (a batch of runs, or one run with attachments) |
| `blob_min_kb` | 20 | Payloads at or above it go to RustFS rather than SmithDB's rows |
| `redis_runs_expiry_hours` | 6 | How long a run waits in Redis for the workers before it is dropped |
| `prometheus_retention_days` | 15 | Days of metrics |

The chart's own long TTL is 400 days; Lite's 30 keeps one box's disk bounded. The chart refuses a long
TTL under 14 days, and so does the plan.
