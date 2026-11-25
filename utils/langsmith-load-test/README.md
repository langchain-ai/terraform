# LangSmith load test

> **Status:** current. How far any plan has been checked is in the [sizing README](../langsmith-sizing/README.md).

Sends a self-hosted LangSmith instance the load a sizing plan was sized for, reads it back, and checks the
two things a plan promises: how long a sent run takes to become readable, and whether every run sent is
stored. It calls no model provider, so it incurs no model charges; your usual infrastructure costs apply.

It is the last step of the loop in [`../langsmith-sizing`](../langsmith-sizing/README.md): size, deploy,
load test, compare. That package writes the load profile this tool reads (payload mix, runs a trace,
feedback, read rate and read mix, targets), so the load exists once, in its `params.yaml`. The load test
needs neither `helm` nor a chart.

## Set up

You need Python 3.11+, [uv](https://docs.astral.sh/uv/getting-started/installation/) 0.13.4 or later, and
an API key for the instance. `helm` and a chart pull are needed only by `langsmith-sizing`, not here; to
read the install while the load runs (`--namespace`, below) you also need `kubectl` on your PATH with a
context for the cluster. From this folder:

```bash
make setup               # once
cp .env.example .env     # then edit it
```

| Setting | What to enter |
| --- | --- |
| `LANGSMITH_TRACING` | `true` to upload traces. `false` generates payloads locally, with no uploads or feedback. |
| `LANGSMITH_ENDPOINT` | Your self-hosted API URL, such as `https://langsmith.example.com/api/v1`. |
| `LANGSMITH_API_KEY` | A key created in the target instance that can create projects, traces and feedback. |
| `LANGSMITH_PROJECT` | The project to create or reuse, such as `load-test`. |
| `LANGSMITH_WORKSPACE_ID` | The workspace ID from **Settings > General**. Set it only when the key can access several workspaces. |

The key identifies the organization and the workspace ID selects the workspace within it; no organization
ID is needed. Keep `.env` private: the script loads it from this folder, and its values take precedence
over the same names exported in your shell. When tracing is enabled the script prints the resolved project
and workspace before it starts.

Use a project that only this test writes to: project statistics and trace listings cover the whole
project, and the heavy filter and the stored count filter on the test's id. With `--projects N` the test
writes to `<LANGSMITH_PROJECT>-000` and on instead, creating each.

## Run it

A small test first. `make smoke` sends 10 traces in 30 seconds; open the project and confirm they appear
before you raise the load.

Then verify a plan. From `../langsmith-sizing`, `make plan NAME=acme PRESET=production` saves a sizing with its
`out/acme/load-profile.json`, and `make load NAME=acme` sends it with reads for 600 seconds after a 60 second
ramp, saving `results.json` beside the plan; `make compare NAME=acme` judges it. Here, `make run NAME=acme`
does the same, or `make run PROFILE=<load-profile.json>`; `DURATION=`, `RAMP=`, `PEAK=1` and `ARGS=` apply. The
plain command:

```bash
uv run load-test --profile ../langsmith-sizing/out/acme/load-profile.json --read \
  --duration-seconds 600 --ramp-up-seconds 60 --results results.json
```

`--peak` sends the profile's peak rate instead of its average. `--traces-per-second 50` sends the model's
default load at a rate you choose, with no profile. The run prints a header, a progress line every
`--progress-seconds`, and the results as tables: what was sent and stored, each read class's latency,
send-to-readable lag, and one verdict per target. The results record the LangSmith app version the install
reports, so `compare` can say whether it is the one the plan was sized for.

The first `uv run` creates `.venv` here and installs the dependencies.

## Does it work, and what does it hold

Three commands answer the questions an install's owner asks after a deploy, for any install the test can
reach through `kubectl`: a cloud module's, a bare-metal cluster's, LangSmith Lite's (whose `make verify`
and `make soak` run these).

| Command | Asks | Exit 1 when |
|:--|:--|:--|
| `make verify NAMESPACE=langsmith` (`load-test-verify`) | Do traces flow end to end? Ten traces, each polled until readable, the install read as they go; then one line a hop: accepted by the API, Redis's ingestion queue drained, SmithDB flushed, readable by a query. On the first hop that fails, that workload's last log lines. | a hop failed |
| `make soak NAMESPACE=langsmith TPS=5` (`load-test` then `load-test-judge`) | Does it hold this load? The rate with reads for `DURATION`, then every target, whether ingestion kept up, and each watch item against its alarm level. | it did not hold |
| `make step NAMESPACE=langsmith TPS=5` (`load-test-step`) | What does it hold? The rate x 0.5, 1, 1.5, 2, 3 and 4 in turn, until one does not hold, and what crossed its alarm level there. | never; it reports |

A run holds its load when every target passed, nothing was lost, and the ingestion backlog was not still
climbing at the window's end. A watch item past its level is observed, not failed: an autoscaler scales on
a backlog over its target, so crossing says where to look. The levels are a sizing's (`--plan`), or
without one those `params.yaml` sets itself; a level read from a chart or a plan is unknown without them,
and that item is observed. A hop or a level not read is shown as not read, never as passing.
`--data-namespace` (Redis and Postgres in a namespace of their own) and `--kube-context` pass through.

## What it sends

Each trace is a root run with child runs, `runs_per_trace` of them (a fractional value alternates, so 7.5
gives 7 and 8), built directly with the SDK's `RunTree`. Each run draws a size from the payload mix, by
default 70% small (4 KiB in, 4 out), 25% medium (32, 32) and 5% large (750, 750), from Dzmitry Dubarau's
trace payload measurements. Its input and output are fresh text of that size, so storage and compression
behave like unique data. The text comes from a 10,000-word vocabulary with English's Zipf frequency,
seeded by `--data-seed`; `tests/test_text.py` holds its zlib compression ratio to a band for English
prose. Every run carries the test's unique id in its metadata.

Feedback is `feedback_per_trace` writes a trace (default 0.5, and it can exceed one), spread evenly. It is
sent from its own threads so a slow server does not slow the trace schedule, and drained after the load.

### The payload's shape

A run's size is not the only thing that moves what ingest costs a core, so the shape is a profile field
(`write.payload`, defaults in `langsmith-sizing`'s params `load.payload_shape`) and each part has a flag
that replaces it for one run:

| Flag | Default | Why it can change the cost |
|:--|:--|:--|
| `--fields-per-side N` | 1 | Offload to the bucket is decided per field: ten 4 KiB fields stay inline where one 40 KiB field is offloaded. |
| `--content text\|json\|base64` | text | Prose, a message list and encoded bytes compress differently in Redis and in storage. |
| `--send post_then_patch\|post_once` | post_then_patch | A run created and then updated is two requests; a finished run is one. |
| `--attachment-kib K` | the profile's (0) | Attachments go to the LangSmith bucket at the bytes sent; `langsmith-sizing --attachment-kib-per-run` sizes them. |
| `--projects N` | 1 | SmithDB partitions by project: one busy project concentrates its runs on the same ingestion pods. |
| `--project-skew S` | 1.0 | How unevenly traces spread over the projects (Zipf over rank; 0 is even). |
| `--metadata-keys K` | 0 | SmithDB indexes metadata; every fifth key is a per-trace id, as a thread or user id is. |
| `--batch-runs R` | 100 | The most runs the SDK sends a request; fewer runs a request is more requests and more object-store writes. |

To learn what one of them costs, hold everything else and change one flag between two runs that read the
install (below), with the same rate, duration and ramp:

```bash
uv run load-test --traces-per-second 200 --duration-seconds 900 --ramp-up-seconds 120 --namespace langsmith --results a.json
uv run load-test --traces-per-second 200 --duration-seconds 900 --ramp-up-seconds 120 --namespace langsmith --results b.json --send post_once
```

Then set `cluster.coefficients.ingest-queue.runs_per_core` (and platform-backend's and SmithDB ingestion's)
of `b.json` against `a.json`'s, after checking `cluster.kept_up` in both: a run whose backlog was still
climbing measured a queue filling, not what the workers carry. `write.payload_shape` in each result says
what was sent. To send a load shaped like LangChain's 200,000 runs/s test, add `--projects 200
--metadata-keys 34` and a run size near its 130 KB average.

## The install under the load

With `--namespace` the test also reads the install while it runs, through `kubectl` alone, every
`--sample-seconds` (default 15):

- the queue depths the chart's autoscalers read (platform-backend `/metrics?format=json`, backend
  `/metrics/queue/default`, SmithDB compaction `/metrics/jobs`);
- every SmithDB pod's `/metrics`, the families the plan watches;
- the age of the oldest queued task (platform-backend `/metrics`, `langsmith_asynq_queue_latency_seconds`);
- Redis `INFO` (memory, evictions, connected clients) and Postgres's connections in use, when each runs
  in the cluster (a managed one is read through its cloud's monitoring), found by component label or, as
  the bare-metal datastores chart labels them, by name; `--data-namespace` reads them where they run when
  that is not LangSmith's namespace (LangSmith Lite runs them in `<namespace>-data`);
- each autoscaler's replicas against its maximum, restarts and OOM kills;
- each container's CPU, throttling and working-set memory from its node's cAdvisor, or, with
  `--prometheus NS/SERVICE:PORT`, from that Prometheus's `/federate` through `services/proxy`, for a context
  without `nodes/proxy` (LangSmith Lite's);
- once a minute, the bytes in each persistent volume a store's pod mounts, with `du` in the pod: a local
  volume reports no usage to the kubelet;
- at the end, the runs ingest-queue logged as skipped because their payload had expired in Redis.

SmithDB's series keep their `status`, `level` and `job_kind` labels: a compaction backlog counts pending
jobs, not ones in flight, and an ingestion backlog counts `level=l0` segments, since `l1` ones wait for a
scheduled flush by design.

The results gain two sections:

- `metrics`: one reading per watch item of the plan, keyed as the plan names it (a peak and an end, or a
  count, a mean or a share, with its unit). `langsmith-sizing compare` prints each with the side of the
  plan's alarm level it reached; a watch item is `observed`, never pass or fail, because a backlog over an
  autoscaler's target is what makes it scale. `make compare` saves them in `verdicts.json`.
- `cluster`: what the install did in the window after the ramp, to the end of the load.
  - `kept_up` is true when a backlog (the ingestion queue, pending compaction jobs) was no larger at the
    window's end than its largest in the first half; false means it was still climbing; null, not read.
  - `coefficients.<workload>.cores_used` is the CPU it used on average, from cAdvisor, not what it requested;
    `runs_per_core` is the runs sent a second over those cores, on the ingest path only. Set ingest-queue's
    against the field curve `langsmith-sizing` sizes from (params `ingest.runs_per_core_points`) and the
    plan's `regime.measured.ingest_cores_by`: that is the figure the two ingest models disagree on.
  - `coefficients.<workload>.memory_peak_mib` is the most memory its containers held together in a sample.
  - `disk_bytes_per_run` is the bytes each volume gained a run sent, between the window's first and last
    disk readings; with `write.payload_kib_per_run`, the bytes generated a run, it is what a run costs
    each store.
  - `smithdb_rows_flushed_per_second` is the rate SmithDB wrote, to set beside the rate sent.
  - `unread` names what could not be read in some sample; a missing reading is unknown, never zero.

Every sample is kept beside the results (`<results>.metrics.jsonl`). `uv run load-test-plot <results>.json
--plan <sizing>/plan.json` (or `make plot`) writes `<results>.html` beside them, `--out` elsewhere: one chart
a signal, the window after the ramp shaded, and with `--plan` each watch item's alarm level as a line.

`uv run load-test-report OUT RUN_DIR...` reads every finished run in the folders and writes
`OUT/report.html`, each figure as `OUT/figures/<figure>-light.png` and `-dark.png` for a deck,
`OUT/stats.json` and `OUT/stats.csv` with every number a figure shows, and `OUT/runs/` with each run's own
files. A figure's title is computed from the runs, never typed. The figures are `langsmith-sizing`'s pages
in the LangChain brand, its faces and logos read from `--fonts` and `--logos`; `--draft` draws without
them, each figure labelled a draft. `--design` says a rate as a multiple of the install's design rate.

Read a run only once its backlogs settle: after an upgrade that rebuilds SmithDB's data, compaction runs
behind for a while by design, and a coefficient read then measures the catch-up, not the load.

The kubectl context needs these permissions; `kubectl auth can-i` checks each:

```yaml
# In the LangSmith namespace (a Role)
- apiGroups: [""]
  resources: [pods, services]
  verbs: [get, list]
- apiGroups: [""]
  resources: [pods/proxy, services/proxy, pods/log]
  verbs: [get]
- apiGroups: [""]
  resources: [pods/exec]                 # Redis INFO, Postgres's connection count and du of each store's volume
  verbs: [create]
- apiGroups: [autoscaling]
  resources: [horizontalpodautoscalers]
  verbs: [get, list]
# Cluster-wide (a ClusterRole): each node's cAdvisor; not needed with --prometheus
- apiGroups: [""]
  resources: [nodes/proxy]
  verbs: [get]
```

```bash
kubectl auth can-i get nodes/proxy                       # yes: CPU and throttling are read
kubectl -n langsmith auth can-i create pods/exec        # yes: in-cluster Redis and Postgres are read
```

## Rate mode and users mode

- **Rate mode** (`--traces-per-second X`, or `--profile`, whose rate is its average) starts traces on a
  schedule whatever happens to earlier ones (open loop). `--ramp-up-seconds` raises the rate from zero to
  X linearly. `--max-in-flight` caps unfinished traces: a start due over the cap is dropped and counted,
  never delayed. The results report the achieved rate, the schedule lag (how late each start was) and the
  dropped starts, so a generator that cannot keep up shows as lag and drops, not as a lower rate hidden in
  the average. One process generates about 70 MiB of text a second at the default mix, roughly 70 traces
  a second; beyond that run several processes against the same project.
- **Users mode** (`--users N`, the default when no rate is given) is a closed loop: each user starts its
  next trace after the last finishes. Its offered rate falls as the server slows, so it measures a
  server's capacity, not a plan.

## Reads

`--read` sends reads at the profile's `read.requests_per_second` (or `--reads-per-second`), each class
drawn by its weight in `read.mix`, from the same open-loop scheduler. Three of the classes (`list_traces`, `read_trace`, `heavy_filter`), and the lag polls, use the pinned
`langsmith` 0.14.0 SDK's v2 resources (`/api/v2/traces/query`, `/api/v2/traces/{trace_id}/runs`,
`/api/v2/runs/query`), so the instance must serve those endpoints; an instance that does not answers not
found, and those reads count as errors.

| Class | SDK call | Exercises |
| --- | --- | --- |
| `list_traces` | `client.traces.query(project_id, min_start_time, page_size=20)` | query |
| `read_trace` | `client.traces.list_runs(trace_id, project_id, ...)` on a trace sent at least `--read-min-age-seconds` ago | query |
| `project_stats` | `client.read_project(project_id, include_stats=True)` | stats-query |
| `feedback_stats` | `client.get_run_stats(project_ids, is_root=True, filter=feedback_key)` | stats-query |
| `heavy_filter` | `client.runs.query(project_ids, filter=<test id>, min_start_time=now - heavy_window_days)` | query |

The SDK has no feedback-statistics method, so `feedback_stats` uses the run-statistics endpoint over runs
that carry the test's feedback key. Results give each class's count, errors, skipped (a `read_trace` with
no old enough trace yet), p50, p95 and p99.

## Lag and loss

`--lag-sample` (default 5%) marks that share of traces. Each is polled every `--lag-poll-seconds`
(`client.runs.query` by id) until it is readable or `--lag-deadline-seconds` passes. The lag runs from the
moment the test starts sending the trace, so SDK batching counts, and it is an upper bound within one poll
interval. The report gives p50, p95, p99 and max, and the count never readable by the deadline.

After the load the SDK is flushed, then the test counts runs stored for its id (`client.get_run_stats`)
every few seconds until they reach runs sent or `--settle-seconds` ends. Runs sent minus runs stored is the
missing count. A count that cannot be read is reported as unknown and fails the run.

## Targets, results and exit codes

The profile's targets (the model's `slo.*` without a profile) are checked: the lag p99 against
`stored_within_seconds.p99` (more than 1% never readable fails it) and the `read_trace` p99 against
`trace_load_seconds.p99`. A target with nothing measured, such as the read target without `--read`, is "not
measured" and does not fail the run.

`--results FILE` writes schema `langsmith-load-results/1`: the profile used, the settings, achieved write
rate, errors, feedback, reads per class, lag, sent, stored and missing, the verdicts, and the start and end
times. Every field, with its type, unit and meaning, is in [docs/results-fields.md](docs/results-fields.md). `--json` prints it to stdout with logs on stderr. `langsmith-sizing compare` sets it against the plan.

| Exit | Meaning |
| --- | --- |
| `0` | every measured target met, nothing missing, no errors |
| `1` | a failed target, missing runs, a run, feedback, upload or read error, a stored count that could not be read, or a breached `--latency-limit-seconds` (the p95 time to hand a trace to the SDK) |
| `2` | invalid settings or a setup failure |

## Options

`uv run load-test --help` lists every option with its default.

| Group | Options |
| --- | --- |
| load | `--profile`, `--traces-per-second`, `--peak`, `--users`, `--duration-seconds` (10), `--ramp-up-seconds` (0), `--run-limit`, `--max-in-flight` (256), `--pause-seconds` (0), `--simulated-delay-ms` (0), `--feedback-per-trace`, `--data-seed` |
| payload shape | `--fields-per-side`, `--content`, `--send`, `--attachment-kib`, `--projects`, `--project-skew`, `--metadata-keys`, `--batch-runs` |
| the install's own metrics | `--namespace`, `--release` (langsmith), `--kube-context`, `--sample-seconds` (15) |
| reads | `--read`, `--reads-per-second`, `--read-min-age-seconds` (60) |
| lag and loss | `--lag-sample` (0.05), `--lag-deadline-seconds` (120), `--lag-poll-seconds` (2), `--settle-seconds` (60) |
| output | `--results`, `--json`, `--latency-limit-seconds`, `--progress-seconds` (10), `--feedback-drain-seconds` (60) |

## Limits

One process generates about 70 traces a second; the stored count reads the test's projects, so use projects
only this test writes to. Without `--namespace` it sees what a client sees and reports no server metric;
with it, a managed Redis or Postgres is still read through its cloud's monitoring, and the expired-run
count reads every ingest-queue pod's logs once at the end, which is slow at hundreds of pods.

## Tests

```bash
uv run python -m unittest discover -s tests
uvx ruff@0.17.3 check src tests
```

Both are offline and need no instance. `make check` here runs them, and `make check` in the sizing folder runs them with the sizing gates.

## Files

Every module under `src/loadtest/` is listed here; `tests/test_readme.py` fails when the list and the tree differ.

- `cli.py`: options, profile resolution, connection and summary.
- `profile.py`: the load profile and the model's defaults, read from `langsmith-sizing`.
- `runner.py`: trace sending in both modes, and the report.
- `feedback.py`: feedback on its own threads, drained after the load.
- `schedule.py`: the open-loop scheduler and ramp.
- `draw.py`: the weighted draw of a read class, and the even spread of a fractional count such as feedback a trace.
- `stats.py`: percentiles by nearest rank.
- `reads.py`: the read classes.
- `lag.py`: the send-to-readable lag.
- `verify.py`: runs stored against runs sent.
- `judge.py`: verify, judge and step: each hop a trace crosses, whether a run held its load, and the rate an install holds.
- `results.py`: the results document and target verdicts.
- `cluster.py`: reads the install through kubectl while the load runs, and turns the samples into watch readings and cores used.
- `plot.py`: draws a run's samples as one HTML page (`load-test-plot`).
- `report.py`: a set of runs as branded figures, their numbers as JSON and CSV, and the runs' own files (`load-test-report`).
- `fields.py`: the unit and meaning of every results field; [docs/results-fields.md](docs/results-fields.md) is generated from it (`make reference` in `../langsmith-sizing`).
- `payloads/`: payload sizes from the mix and the English-like text.

## Credits

Hari Narayan wrote this tool and its feedback design. The payload model and its
measurements are Dzmitry Dubarau's, read through `langsmith-sizing`; his review capped
the feedback threads. The read mix and heavy filter are Reed Bender's, and the targets Ben Nagengast's, as
recorded in `langsmith-sizing/params.yaml`.

See [self-hosted API setup](https://docs.langchain.com/langsmith/self-host-usage) and
[API keys and workspace selection](https://docs.langchain.com/langsmith/create-account-api-key).
