# Operating a plan

> **Status:** current. Where each signal is read was taken from the chart's `scaled-object.yaml` and
> `hpa.yaml` templates at both planned charts ([`charts.yaml`](../charts.yaml)); every monitoring endpoint
> was read from a running install on 2026-11-18. The tables marked generated are written by `make
> reference` from `params.yaml`.

Two things keep a plan true once it runs: autoscalers that follow the work waiting, and the install's own
metrics, which say whether the plan held.

## Autoscaling

A LangSmith install's load is not flat. Traces arrive in bursts, people open the UI in working hours, and a
batch job can send a day's feedback in a minute. Sized for the peak at all times, an install pays for its
busiest minute all day; sized for the average, it falls behind at the peak, and in this system falling
behind is not only slow. Runs wait in Redis for ingest, and Redis holds each run for a fixed expiry (six
hours by default). A backlog that outlives the expiry loses runs, silently. An autoscaler is what lets the
plan be cheap at rest and still keep up at the peak, and it works only when it scales on the signal that
shows the work waiting.

### What a plan says about scaling

Each autoscaled workload gets three replica counts, and the plan reports totals at each:

| Count | What it is | What to size by it |
|:--|:--|:--|
| floor | the autoscaler's minimum: what runs at rest | node pools: what you pay for all the time, with a cluster autoscaler able to reach the ceiling |
| sized | the replicas the model sized for the peak | the expected footprint at the busiest hour |
| ceiling | the autoscaler's maximum, never below the chart's own | the namespace quota, plus the largest Helm hook Job: a quota below it blocks the autoscaler exactly when it acts |

`plan.json` holds, per workload under `scale`, the recommended mechanism and signal, what the chart's
autoscaling block can express at the version planned (read from the chart, never assumed), the exact chart
keys `values.yaml` sets, and the gap between them.

### Why queued work, not CPU

CPU is the default signal of a Kubernetes HorizontalPodAutoscaler (HPA), and for a stateless, CPU-bound
service such as the frontend it is the right one. For a worker that drains a queue it is late: the queue
grows first and CPU follows. For a memory-bound pod it can be wrong altogether. SmithDB query pods were
OOM-killed at about 7% CPU while a CPU autoscaler sat at its floor, because the work was queued behind an
admission gate the CPU number never saw. So the plan recommends, per workload, the signal that shows the
work waiting, and uses CPU only where the chart can express nothing better.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="figures/autoscaling-dark.png">
  <img alt="Which signal moves which workload. CPU from metrics-server drives HPAs for frontend, backend and platform-backend; memory drives SmithDB ingestion. platform-backend's ingestion_queue.pending drives ingest-queue through KEDA, backend's queued count drives queue, and the compaction service's pending jobs drive compaction workers. SmithDB query and stats-query on the admission queue, mutations and run-rules on their backlog, and ingestion on pending segments have no chart field yet: the plan applies CPU and reports a chart ask. Below, the floor sizes node pools, sized is the expected peak footprint, and the ceiling plus the largest hook Job sets the namespace quota." src="figures/autoscaling-light.png">
</picture>

### How the chart scales

Two mechanisms, both rendered by the chart from a workload's `autoscaling` block:

- **HPA** on CPU or memory utilization: the metrics-server reports each pod's use, and the HPA keeps the
  average near `targetCPUUtilizationPercentage` (or the memory target) of the request. Requests therefore
  matter twice: they size the node, and they are the denominator of the signal.
- **KEDA** (Kubernetes Event-driven Autoscaling) with its `metrics-api` scaler: KEDA polls a JSON endpoint
  the install serves, reads one value, and scales so that the value a pod stays near the target. The chart
  wires three:

| Workload | KEDA polls | Value read | Target key |
|:--|:--|:--|:--|
| `ingest-queue` | `http://<release>-platform-backend:<port>/metrics?format=json` | `ingestion_queue.pending`, `feedback_queue.pending`, `adhoc_queue.pending` | `ingestQueue.autoscaling.keda.queueTargetSize` |
| `queue` | `http://<release>-backend:<port>/metrics/queue/default` | `queued` | `queue.autoscaling.keda.queueTargetSize` |
| `smithdb-compaction-worker` | `http://<smithdb-compaction>:<port>/metrics/jobs` | `pending` | `smithdb.compactionWorker.autoscaling.keda.pendingJobsThreshold` |

KEDA must be installed in the cluster for these; without it the chart's HPA blocks are the only autoscalers.
Each KEDA scaled object also carries CPU and memory triggers, and KEDA scales on whichever asks for the
most replicas.

### Each workload's trigger

<!-- generated:autoscaling -->
| Workload | Mechanism | Signal, and where it is read | Chart field | Why this signal |
|:--|:--|:--|:--|:--|
| `frontend` | hpa | metrics-server: pod CPU over its request | `targetCPUUtilizationPercentage` | Stateless and CPU-bound; floors from the scale guide. |
| `backend` | hpa | metrics-server: pod CPU over its request | `targetCPUUtilizationPercentage` | Stateless and CPU-bound; floors from the scale guide. |
| `platform-backend` | hpa | metrics-server: pod CPU over its request | `targetCPUUtilizationPercentage` | A Go service whose work follows CPU, with a CPU limit of at least go.min_cpu_limit so CPU stays a usable signal. |
| `ingest-queue` | keda | platform-backend /metrics?format=json: ingestion_queue.pending | `queueTargetSize` | Run backlog is the work waiting; CPU lags it, and a feedback flood must not drive ingest. |
| `queue` | keda | backend /metrics/queue/default: queued | `queueTargetSize` | The Python queue worker's work is its backlog. |
| `smithdb-query` | hpa | each SmithDB query pod /metrics: query_admission_queue_length | no field (a chart ask) | Query pods were OOM-killed at about 7% CPU with a CPU autoscaler pinned at its floor; queued work shows load that CPU does not. No replica count saves one huge query, so per-operation memory limits are configured too (configure). |
| `smithdb-stats-query` | hpa | each SmithDB query pod /metrics: query_admission_queue_length | no field (a chart ask) | One large stats query saturated CPU and runtime threads in a dev test; queued work is the signal, per-operation memory limits the guard. |
| `smithdb-mutations` | hpa | the service's own backlog: no endpoint the chart reads | no field (a chart ask) | Feedback writes are queued work; CPU follows it late. |
| `smithdb-run-rules` | hpa | the service's own backlog: no endpoint the chart reads | no field (a chart ask) | Rule evaluations are queued work; the model does not size this service, the chart leaves it off. |
| `smithdb-ingestion` | hpa | metrics-server: pod memory over its request; each SmithDB ingestion pod /metrics: ingest_pending_segment_entry_count | `targetMemoryUtilizationPercentage`, no field (a chart ask) | Ingestion holds segments in memory until flushed; memory and pending segments show a falling-behind flush that CPU hides. |
| `smithdb-compaction-worker` | keda | smithdb-compaction /metrics/jobs: pending | `pendingJobsThreshold` | Pending compaction jobs are the work waiting. |
| `smithdb` | none | none | - | The unified topology is one pod sized by the tier; the chart gives it no autoscaler. |
<!-- /generated:autoscaling -->

Not every workload is listed: `playground` and `ace-backend` stay at the chart's counts.

### What the chart cannot express yet

A recommended trigger with no field in the chart's autoscaling block is a **chart ask**. The plan never
pretends the trigger exists. It applies the nearest thing the chart supports (a CPU HPA with the plan's
floors and ceilings), records the gap under `scale.<workload>.gap`, and prints a `chart-ask:<workload>`
warning naming both. At both chart versions planned these are open:

- SmithDB query and stats-query on `query_admission_queue_length`.
- SmithDB ingestion on memory and on `ingest_pending_segment_entry_count`.
- SmithDB mutations and run-rules on their own backlog.
- `ingest-queue` on the run backlog alone: its scaled object fires on the feedback and adhoc backlogs
  against the same target, so a feedback flood can scale ingest. Until the chart has a switch, the plan
  sets `GO_INGESTION_QUEUE_PRIORITY=6` and `GO_FEEDBACK_QUEUE_PRIORITY=1` so runs drain first.

You can close a gap yourself before the chart does, with a KEDA `prometheus` scaler on the SmithDB metric
(where each is served is under [Monitoring](#monitoring)). Then read the matching watch item to see
whether it helps.

### Rules the plan applies with the autoscalers

- **A ceiling is never below the chart's.** An autoscaler pinned at the plan's own count could not absorb
  what the model did not foresee. A ceiling above the chart's default is listed in the
  `ceilings-above-chart-default` warning.
- **Go pods keep a CPU limit of at least 2.** platform-backend and ingest-queue are Go services; at a 1 CPU
  limit a lab pod was throttled in 98% of its CFS windows, and a throttled Go pod freezes for the rest of
  the window, so CPU stops being a usable signal (`go.min_cpu_limit`).
- **More SmithDB query pods are not always better.** Each holds its own cache, and eight query pods meant
  eight cold caches; from the medium tier up the plan keeps two and raises the tier for reads instead.
- **The extra-lite regime turns autoscalers off.** At a few traces a second on one node, every serving pod
  runs one replica; an autoscaler there only adds pods the node cannot hold.
- **SmithDB's unified pod has no autoscaler.** On a 0.18 chart, a load one pod carries runs as the single
  `smithdb all` pod, sized by its tier.

## Monitoring

A plan is a prediction, and the install's own metrics are how you find out whether it held. LangSmith
reports itself in three ways: JSON queue depths that the autoscalers read, Prometheus text from every
SmithDB pod, and the standard Kubernetes and Redis series. Each item in a plan's `watch` list names one of
these metrics, where to read it, what a bad reading means and what to do. It carries an alarm level only
where a parameter, the chart or the plan gives one; the rest are `observe`, because no measurement backs a
number for them yet, and an invented threshold is worse than none.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="figures/metrics-dark.png">
  <img alt="Where a running install reports itself. platform-backend serves every Go queue's depth at /metrics?format=json, backend the Python queue's at /metrics/queue/default, and SmithDB compaction its pending jobs at /metrics/jobs, which the KEDA autoscalers read. Every SmithDB pod serves Prometheus text at /metrics on its http port, annotated for scraping; Redis reports through INFO and Kubernetes through metrics-server, kube-state-metrics and cAdvisor. The chart exports only SmithDB's critical metrics by default; five of the watched metrics need METRICS__MODE=all." src="figures/metrics-light.png">
</picture>

### The endpoints

#### Queue depths, as JSON

platform-backend serves every Go queue's depth at `/metrics?format=json` on its service port. This is what
the `ingest-queue` autoscaler polls. On an idle install it reads:

```json
{"ingestion_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "ingestion_vip_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "feedback_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "upgrades_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "adhoc_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "experiment_queue":{"pending":0,"active":0,"scheduled":0,"retry":0},
 "webhooks_queue":{"pending":0,"active":0,"scheduled":0,"retry":0}}
```

`pending` is the work waiting, and `ingestion_queue.pending` is the one number that says whether ingest is
keeping up. backend serves the Python queue's depth at `/metrics/queue/default` (`{"queued":0,"active":0,
"scheduled":14}`), and SmithDB's compaction service serves its pending jobs at `/metrics/jobs`
(`{"pending":0}`). To read one by hand:

```bash
kubectl -n <namespace> get --raw "/api/v1/namespaces/<namespace>/services/<release>-platform-backend:<port>/proxy/metrics?format=json"
```

Prometheus does not scrape JSON. Either read these through KEDA, whose operator exports the value each
scaler last read as `keda_scaler_metrics_value`, or run a JSON exporter against the three URLs.

#### SmithDB, as Prometheus text

Every SmithDB pod serves `/metrics` on its `http` port and is annotated for discovery:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8050"     # the component's http containerPort: 8050 ingestion, 8060 query,
prometheus.io/path: /metrics   # 8070 compaction, 9000 compaction worker, 8090 cluster manager
```

A Prometheus that discovers pods by these annotations (the common `kubernetes-pods` scrape job) collects
them with no further setup. The 0.18 chart also adds a headless `<component>-metrics` Service per SmithDB
component, so that each pod has its own DNS record; LangSmith's queue scrapes them for the telemetry it
sends to LangChain when `config.telemetry.metrics` is on.

**The chart exports only SmithDB's critical metrics.** It sets `<SERVICE>__METRICS__MODE=critical` on
every SmithDB pod (for example `SMITHDB_INGESTION__METRICS__MODE`), which serves a fixed list of
operational families and drops the rest. A watch item that reads a metric outside that list says so in its
`needs` field. To export everything from one component, set the variable to `all` in the component's extra environment:

```yaml
smithdb:
  ingestion:
    deployment:
      extraEnv:
        - name: SMITHDB_INGESTION__METRICS__MODE
          value: all
```

Two more behaviors catch people reading these for the first time. A family appears only after its pod has
observed something: an idle ingestion pod serves `server_requests_duration`, `sys_jemalloc_resident_bytes`
and the two semaphore families, and no `ingest_*` family until the first write. And a missing family is
therefore not a zero; a dashboard that reads it as zero is wrong exactly when nothing is flowing.

#### Redis and Kubernetes

Redis reports through `INFO`: `used_memory` against `maxmemory`, and `evicted_keys`. A `redis_exporter`
publishes them as `redis_memory_used_bytes`, `redis_memory_max_bytes` and `redis_evicted_keys_total`; a
managed Redis publishes the same through its cloud's monitoring. From Kubernetes the plan reads
kube-state-metrics (`kube_horizontalpodautoscaler_status_current_replicas` against the HPA's maximum,
`kube_pod_container_status_last_terminated_reason`) and cAdvisor (`container_cpu_cfs_throttled_periods_total`
over `container_cpu_cfs_periods_total`).

### What to watch

Every plan carries this list, with the alarm levels resolved for that plan (the per-autoscaler item becomes
one item per autoscaler, at its ceiling). An item for another SmithDB topology is dropped.

<!-- generated:watch -->
| Item | Metric | Where it is read | Alarm level | Action |
|:--|:--|:--|:--|:--|
| `redis-memory` | `used_memory` | Redis INFO memory: used_memory over maxmemory | `param:redis.alarm_pct` | Add Redis memory before the backlog; never lower the run expiry to save it. |
| `redis-evictions` | `evicted_keys` | Redis INFO stats: evicted_keys | 0 (evicted keys, any) | Set maxmemory-policy noeviction (configure.redis) and add memory. |
| `redis-clients` | `connected_clients` | Redis INFO clients: connected_clients | observe | Fewer, larger pods, or a Redis with a higher client limit. |
| `postgres-connections` | `pg_stat_activity` | Postgres: rows in pg_stat_activity against max_connections | observe | Raise max_connections to the plan's (stores.postgres) and put PgBouncer in front. |
| `run-backlog-at-ceiling` | `ingestion_queue.pending` | platform-backend /metrics?format=json, ingestion_queue.pending | `chart:ingestQueue.autoscaling.keda.queueTargetSize` | Raise the ceiling, then the pod CPU; if Redis memory also climbs, the install is past its sizing. |
| `feedback-backlog` | `feedback_queue.pending` | platform-backend /metrics?format=json, feedback_queue.pending | observe | Turn on the dedicated mutations service (smithdb.mutations.enabled). |
| `oldest-queued-task` | `langsmith_asynq_queue_latency_seconds` | platform-backend /metrics (Prometheus text), by queue | 60 (seconds the oldest task has waited) | Raise ingest-queue's ceiling or its CPU; if Redis memory climbs too, the install is past its sizing. |
| `expired-runs` | `log:Skipping run as it has expired` | ingest-queue logs: Skipping run as it has expired | 0 (runs skipped, any) | Keep redisRunsExpirySeconds above the worst backlog and give Redis the memory to hold it (configure.redis). |
| `index-failures` | `log:Index construction failed` | SmithDB's logs: Index construction failed | 0 (segments, any) | Read the error in SmithDB's log, and offer it upstream with the run that failed: SmithDB's source calls it a bug. |
| `pending-segments` | `ingest_pending_segment_entry_count` | each smithdb-ingestion pod /metrics | observe | Add ingestion pods or memory; check object store latency (object-store-latency). |
| `compaction-jobs` | `compaction_queue_job_count` | each smithdb pod /metrics | `chart:smithdb.compactionWorker.autoscaling.keda.pendingJobsThreshold` | Raise the worker ceiling or the object store's request budget. |
| `compaction-oldest-pending` | `compaction_queue_oldest_pending_created_at_seconds` | each smithdb pod /metrics | observe | Add compaction workers. |
| `compaction-completions` | `compaction_jobs_executed` | each smithdb pod /metrics, by job kind | observe | If pending jobs grow while completions stay flat, read the compaction workers' logs before adding workers. |
| `metastore-flush` | `metastore_batch_flush_duration` | each smithdb-ingestion pod /metrics. Needs SMITHDB_INGESTION__METRICS__MODE=all in smithdb.ingestion.deployment.extraEnv: the chart exports the critical set only | observe | Size the metastore (smithdb.metastore) and check its connections. |
| `admission-queue` | `query_admission_queue_length` | each smithdb-query and smithdb-stats-query pod /metrics | 0 (queued queries, sustained) | Add query pods only if the cache hit rate allows; otherwise raise the tier or the per-operation memory limit. |
| `query-fanout` | `query_fanout_limit_exceeded_total` | each smithdb pod /metrics | 0 (queries refused, any) | Read compaction first: many small uncompacted segments raise every scan's partitions. Then narrow the query's time range, or raise the tier. |
| `object-store-latency` | `object_store_op_duration` | each smithdb pod /metrics | observe | Check the object store's request rate limits. |
| `autoscaler-at-ceiling` | `kube_horizontalpodautoscaler_status_current_replicas` | kube-state-metrics, per HorizontalPodAutoscaler | the plan's ceiling, per autoscaler | Raise the ceiling after reading the workload's own item. |
| `oom-killed` | `kube_pod_container_status_last_terminated_reason` | kube-state-metrics, reason="OOMKilled", per container | 0 (OOM kills, any) | Read the workload's own item first; then raise its memory, scale it out, or for SmithDB raise the tier. |
| `go-cpu-throttling` | `container_cpu_cfs_throttled_periods_total` | cAdvisor: throttled periods over container_cpu_cfs_periods_total | observe | Keep the CPU limit at go.min_cpu_limit or above. |
<!-- /generated:watch -->

### What matters at each size

The same list applies at every size, but what fails first moves as the load grows.

- **One node (extra-lite) and two (lite).** Memory is the limit. Watch `oom-killed` and `redis-memory`:
  a single node has no room for a pod to move, and Helm's hook Jobs run beside the serving pods during an
  install or upgrade, so the node's peak is during an upgrade, not under load. The `lite` regime is
  unmeasured: read every item on a load test before quoting its figures.
- **Standard.** The autoscalers now carry the peak, so watch `autoscaler-at-ceiling` with
  `run-backlog-at-ceiling`: a backlog that holds while ingest is at its ceiling means the ceiling, not the
  load, is the limit. `pending-segments` is SmithDB ingestion falling behind its flushes.
- **Large and beyond.** Redis becomes a cluster, and its CPU binds before its memory: one shard carries
  about 850 inline runs a second. The object store's request rate starts to limit flushes, compaction and
  cold reads, so watch `object-store-latency`, `compaction-jobs` and `compaction-oldest-pending`, and the
  plan's `postgres-connections` warning, which counts the connections every pod opens.
- **Past the tiers (scale-out).** Each pod holds Redis and Postgres connections, so `redis-clients` and
  `postgres-connections` near their limits stop the install before CPU does. `oldest-queued-task` says the
  workers are behind before the backlog count does. Pending compaction jobs alone cannot tell a backlog
  draining slowly from stuck workers: read `compaction-completions` beside `compaction-jobs`.

Whatever the size, three readings mean data is at risk rather than slow: any `redis-evictions` (an evicted
run is gone), any `expired-runs` (a run whose payload expired before ingest reached it, skipped with no
error), and a run backlog that lasts longer than the plan's `stores.redis.backlog_tolerance_hours`: 2.5 hours
at the default six-hour expiry, once feedback retries are counted.

SmithDB's own reference for these metrics, with what each label means, is the public
[SmithDB observability](https://docs.langchain.com/langsmith/self-host-smithdb-observability) page.

### Checking a plan against a running install

Run the load test with the install's namespace (`make load NAME=acme NAMESPACE=langsmith`) and it reads
every item above through kubectl while the load runs, and writes each reading into its results under
`metrics`, keyed by the item's id ([the load test's README](../../langsmith-load-test/README.md#the-install-under-the-load)
says how, and the permissions it needs). `make compare` then prints each item as "observed", with its
reading and whether it went past the plan's alarm level; never pass or fail, because a backlog over an
autoscaler's target is what makes it scale. An item it could not read (a managed Redis, say) stays "not
measured by the load test": read it from your own monitoring. `make plot` draws the run.
