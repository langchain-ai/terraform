# Autoscaling

> **Status:** current at chart 0.17.56 and 0.18.0-rc.79. The table marked generated is written by
> `make reference` from `params.yaml`; where each signal is read was taken from the chart's
> `scaled-object.yaml` and `hpa.yaml` templates at both versions.

A LangSmith install's load is not flat. Traces arrive in bursts, people open the UI in working hours, and a
batch job can send a day's feedback in a minute. Sized for the peak at all times, an install pays for its
busiest minute all day; sized for the average, it falls behind at the peak, and in this system falling
behind is not only slow. Runs wait in Redis for ingest, and Redis holds each run for a fixed expiry (six
hours by default). A backlog that outlives the expiry loses runs, silently. An autoscaler is what lets the
plan be cheap at rest and still keep up at the peak, and it works only when it scales on the signal that
shows the work waiting.

## What a plan says about scaling

Each autoscaled workload gets three replica counts, and the plan reports totals at each:

| Count | What it is | What to size by it |
|:--|:--|:--|
| floor | the autoscaler's minimum: what runs at rest | node pools: what you pay for all the time, with a cluster autoscaler able to reach the ceiling |
| sized | the replicas the model sized for the peak | the expected footprint at the busiest hour |
| ceiling | the autoscaler's maximum, never below the chart's own | the namespace quota, plus the largest Helm hook Job: a quota below it blocks the autoscaler exactly when it acts |

`plan.json` holds, per workload under `scale`, the recommended mechanism and signal, what the chart's
autoscaling block can express at the version planned (read from the chart, never assumed), the exact chart
keys `values.yaml` sets, and the gap between them.

## Why queued work, not CPU

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

## How the chart scales

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

## Each workload's trigger

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

## What the chart cannot express yet

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
(see [monitoring.md](monitoring.md) for where each is served). Then read the matching watch item to see
whether it helps.

## Rules the plan applies with the autoscalers

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
