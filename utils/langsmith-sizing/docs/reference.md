# Reference

Every command and flag, how totals and node pools are counted, where each store runs, what each output is
for, and the warning ids. Every field of every output, with its type, unit and meaning, is in
[fields.md](fields.md), which `make reference` generates from real plans.

## Commands

```
uv run langsmith-sizing wizard        [inputs] --out DIR [--yes]   ask, show the plan, save the sizing folder
uv run langsmith-sizing plan          [inputs] --out DIR           the same, asking nothing
uv run langsmith-sizing show          --out DIR                    draw a saved sizing again
uv run langsmith-sizing list          [--root DIR]                 every saved sizing
uv run langsmith-sizing presets                                    the named loads
uv run langsmith-sizing size          [inputs]    plan as JSON on stdout
uv run langsmith-sizing values        [inputs]    chart values (YAML)
uv run langsmith-sizing stores        [inputs]    store specs (JSON)
uv run langsmith-sizing load-profile  [inputs]    the load the plan was sized for (JSON)
uv run langsmith-sizing compare       --plan plan.json --results results.json [--save verdicts.json]
uv run langsmith-sizing profile-report --chart X.Y.Z [--root DIR]
uv run langsmith-sizing check-params  [--chart X.Y.Z]
uv run langsmith-sizing check-citations [--ref BRANCH_OR_COMMIT]
uv run langsmith-sizing chart-info    --chart X.Y.Z [--key a.b.c]
```

The chart is pulled once per version into `~/.cache/langsmith-sizing` (`LANGSMITH_SIZING_CACHE` moves
it). `helm` must be on `PATH`. An error prints `error <what>` and exits 1. Output for a person is drawn
with [rich](https://github.com/Textualize/rich): plain text when piped or when `NO_COLOR` is set. `size`,
`values`, `stores` and `load-profile` print only their document, for a tool to read.

### Inputs

`wizard`, `plan`, `size`, `values`, `stores` and `load-profile` take the same inputs: `--preset NAME`, a
saved sizing's `--preset DIR/inputs.yaml`, or `--users` with a rate (`--traces-per-second` or
`--traces-per-month`). `--chart` takes an exact version, a line (`0.18`, its newest) or `latest`, and defaults
to a saved sizing's chart, else the newest release in the chart repository.
`wizard` and `plan` start from `DIR/inputs.yaml` when it exists and no preset is given. Any flag replaces the
preset's value. A traces flag replaces the average and leaves the preset's peak where it was, so overriding a
preset's rate means giving its peak too; a peak below the average is refused.

| Flag | Meaning |
|:--|:--|
| `--users` | concurrent frontend users at the busiest time |
| `--traces-per-second`, `--traces-per-month` | the average rate |
| `--peak-traces-per-second` | the busiest hour's rate, when known; otherwise the average times the model's peak factor of 3 |
| `--runs-per-trace`, `--retention-days` | the shape of a trace and how long it is kept |
| `--trace-store` | `smithdb`, `dual` or `dual-replicated`: SmithDB alone, or beside the deprecated ClickHouse during a migration |
| `--survives-node-loss` / `--no-survives-node-loss` | serving pods keep at least two replicas |
| `--requests-from-measured` / `--no-requests-from-measured` | pods ask what a lab run measured them to use, not the chart's requests; default the regime's (on in extra-lite) |
| `--postgres`, `--redis`, `--smithdb-metastore`, `--clickhouse` | where each store runs: `external`, `statefulset` or `operator` |
| `--object-store` | `external` (a bucket) or `in-cluster` |
| `--datastores-on` | `app` (in-cluster stores share the application pool) or `dedicated` |
| `--app-node`, `--smithdb-node`, `--datastore-node` | the node shape the pool is counted in, as `8x32` (vCPU x GiB) |
| `--smithdb-tier`, `--smithdb-topology` | SmithDB's tier (`small`, `medium`, `large`) and layout (`cluster`, or `unified` on a chart with `smithdb.topology`); default the load's, and the regime's for a low one |
| `--products` | what runs besides tracing, comma separated or `all`: `agent_server`, `fleet`, `insights`, `polly`, `engine`, `gateway`, `sandboxes`; a product brings what it requires |
| `--agent-deployments`, `--agent-load` | Agent Server: how many deployments, and each one's read then write load as the docs' table column (`ll`, `lh`, `hl`, `mm`, `hh`) |
| `--gateway-streams` | LLM gateway: concurrent streams at the busiest time |
| `--sandboxes`, `--sandbox-vcpu`, `--sandbox-memory-gib`, `--sandbox-node` | Sandboxes: how many run at once, each one's size, and the KVM node (one host a node) |
| `--backfill-runs`, `--backfill-days` | ClickHouse history to copy into SmithDB, and the days to copy it in; both or neither |
| `--attachment-kib-per-run` | attachment KiB a run carries on average (images, audio, files); sized into the LangSmith bucket, so it needs blob storage |

Blob storage is required from chart 0.18 (the self-hosted changelog), so an `inputs.yaml` with
`blob_storage: false` is refused on 0.18 and later, and with any attachments on every chart.

### Chart versions

Two versions are easy to confuse. The **chart version** is the Helm chart's own: what `helm upgrade --version`
takes and what `--chart` names. The **app version** is the LangSmith release the chart deploys: its
`appVersion`, the images' tag, and what a running install reports at `/api/info`. A chart pins one app
version, but an install can override image tags, so the two can drift. The plan records both (`chart`,
`app_version`); the load test reads the install's app version and `compare` sets it against the plan's.

| `--chart` | Sizes on |
|:--|:--|
| unset, or `latest` | a saved sizing's own chart, else the newest release in the chart repository |
| a line, `0.18` | the newest of that line: its newest release, else its newest release candidate |
| exact, such as `0.17.60` | that version, without reading the repository's index |

A saved sizing keeps its chart, so `make plan NAME=acme` sizes it again on the same one and `CHART=latest`
moves it. The versions CI renders are in [`charts.yaml`](../charts.yaml). The index is read at most once a day.

### The sizing folder

`make wizard NAME=x` and `make plan NAME=x` save `out/x/` (`OUT=` moves it; `NAME` defaults to `PRESET`); the
files are listed in the [README](../README.md#the-sizing-folder). `make load` adds `results.json` (and with
`NAMESPACE=`, `results.metrics.jsonl`, the install's readings over the run), `make compare` adds
`verdicts.json` (one verdict a promise, the watch items with their readings), and `make plot` adds
`results.html`. Each file is written whole and then moved into place, so a failed run never
leaves half a plan for `compare` to read.

`make` takes the common inputs as variables (`PRESET`, `USERS`, `TRACES_PER_SECOND`, `TRACES_PER_MONTH`,
`PEAK_TRACES_PER_SECOND`, `RUNS_PER_TRACE`, `RETENTION_DAYS`, `CHART`) and any other flag as `ARGS`;
`make load` takes `NAMESPACE`, and its `ARGS` go to the load test. The load test's flags are in
[its README](../../langsmith-load-test/README.md).

### What each command does

- `values` prints every workload's replicas, requests, limits and autoscaler, SmithDB's tier, topology
  and services, `commonEnv`, Redis's policy and the switches that point the chart at external stores
  (`postgres.external`, `redis.external`, `clickhouse.external`, `config.blobStorage`). What the plan
  cannot know is a `<placeholder>`, listed as `# fill:` lines at the top.
- `profile-report` reads each module's `langsmith-values-sizing-<name>.yaml` for `aws`, `gcp`, `azure`
  and `baremetal` from the repository root, and prints a table per preset of replicas and requests,
  marking each figure that differs from the plan's. It covers four presets (`minimum`, `dev`, `production`, `production-large`), the ones that have module profiles. It writes nothing to the modules.
- `check-params` fails a parameter without its evidence; with `--chart` it also fails one that gives a
  chart setting the value the chart already has.
- `check-citations` fetches the docs and fails a cited quote that is gone, at the pinned commit or at
  `--ref`.
- `chart-info` prints values from the chart at a version: handy for seeing a default the model reads.

## Totals and node pools

`plan["totals"]` and `plan["pools"]` say what the namespace asks for and how many nodes carry it. There is one
set of figures.

`plan["totals"]` holds `floor`, `sized` and `ceiling` (requests, limits and volume GiB at the autoscalers'
minimum, at the sized replicas and at their maximum), `overhead` (the factor nodes are counted with) and
`hooks` (the chart's hook Jobs, and `peak`: the namespace at its `base` of ceiling plus the largest Job).
`plan["pools"]` has `app`, `smithdb` and, with `--datastores-on dedicated`, `datastores`. Each pool holds
`floor`, `sized` and `ceiling`, each with its `nodes` and sums, and `node_cpu`, `node_mem_gib`, `node_floor`
and `node_from` (the node shape and where it came from), `largest_pod` with its size, whether it fits, and
`pods`; the one-node regime adds `single_node`. Each field is in [fields.md](fields.md).

Nodes are `max(ceil(cpu x overhead / node vCPU), ceil(mem x overhead / node GiB), floor)`; a pod fits a
node only strictly below it. The default shapes are in `params.yaml` (application 8 vCPU / 32 GiB, SmithDB
by tier 16 / 64, 32 / 128, 64 / 256, a floor of two nodes each). In-cluster stores share the application pool,
or get their own with `--datastores-on dedicated`.

Hook Jobs are read from the chart rendered with the plan's values: Helm runs them one at a time, so the peak
is the ceiling plus the largest Job. The one-node regime also gets `pools.single_node`: whether everything
plus that Job fits one node.

## Where each store runs

Each store is placed: `postgres`, `redis`, `smithdb_metastore` and `clickhouse` (only while the trace
store is dual) as `external`, `statefulset` or `operator`; `object_store` as `external` or `in-cluster`.
`plan["stores"][name]` gains `placement` and `spec`. The pods the cluster runs for a store are named
`postgres`, `redis`, `smithdb-metastore`, `object-storage`, `clickhouse` and `redis-sentinel`, and sit in
`stores.<store>.spec` as `instances`, `per_instance` and `extra`.

| Placement | Spec |
|:--|:--|
| external | an instance to provision: vCPU, GiB, disk, Postgres connections, Redis shards and maxmemory policy, the buckets with their lifecycle rules |
| statefulset | the pod: the chart's own StatefulSet values, with the model's figure where it sizes one (Redis memory and a volume never below the dataset, ClickHouse disk, Postgres disk per the guide) |
| operator | the same pod as instances: three where the install must survive a node's loss, one otherwise (Dzmitry Dubarau, 2026-11-03), and three Sentinels with a Redis |

The SmithDB metastore is sized by the docs' tier table and runs PostgreSQL 18 or later. Every SmithDB cache
volume needs a StorageClass with at least 7000 IOPS and 1000 MiB/s (`smithdb_cache_volume` in `stores.json`);
a cluster's default is usually too slow. An object store in the cluster is sized by measurements up to
`datastores.object_store_measured_traces_per_second` (80 traces/s); past that peak a warning says no figure
sizes it.

A backfill of ClickHouse history (`--backfill-runs` with `--backfill-days`) is sized by the docs' estimate,
runs / 5,000,000 / days in vCPUs, as migration pods at the chart's per-pod CPU and at least 32 GiB each.
`smithdb.backfill` gives the pods and their total, and the values set `smithdb.migration.job.parallelism` and
the pod's resources; turning migration on stays a rollout step. The pods run beside the serving pods until
the backfill completes, so they are not in the totals: leave room for `smithdb.backfill.requests_total`.

## The load profile

`load-profile` writes the load once, from `params.yaml`, so the plan and the load test share it: write
rate (average and peak), runs a trace, payload mix and sizes, feedback per trace, read rate and mix, the
SLO targets, the payload's shape (attachments, fields a side, content, how a run is sent, projects and
their skew, metadata keys and runs a request, defaults in `load.payload_shape`), and the provenance of each
figure. The load test reads it with `--profile`, and each shape flag of its own replaces one part for a
run; it needs neither `helm` nor a chart.

## Schemas for tool authors

Stability: each output carries a schema id or number (`"schema": 1` in `plan.json` and `stores.json`,
`langsmith-load-profile/1`, `langsmith-load-results/1`). A breaking change to a field's name, place or
meaning changes that number; adding a field does not. Read the number before the fields, and refuse one you
do not know. Values are the plan's own; a figure is `null` only where [fields.md](fields.md) says so.

### What each output is for

- `plan.json`: the whole plan. Keep it: `compare` reads it. Its sections, in the order to read them: `inputs` and
  `rates` (what you gave and what it resolved to), `regime` (the load band and what it turns on), `workloads` and
  `smithdb` (replicas, floors, ceilings, requests, limits), `stores` (each store's size, placement and
  spec), `scale` (the recommended trigger, what the chart supports, what is applied, the chart ask), `configure`
  and `watch` (what to set and what to read), `warnings`, `totals` and `pools`, `values` (the overlay
  `values.yaml` is written from) and `provenance`.
- `stores.json`: what to provision, `{"schema": 1, "chart", "stores", "smithdb_cache_volume", "warnings"}`. Each store is
  `{placement, spec}`: for `external`, `spec.instance`; for `statefulset` and `operator`, `spec.instances`,
  `spec.per_instance` and `spec.extra`; an in-cluster object store also has `spec.buckets`. `warnings` are the
  plan's whose id starts with `redis`, `postgres`, `object-store` or `clickhouse`.
- `load-profile.json`: `langsmith-load-profile/1`, the load the plan was sized for, which the load test reads.
- `results.json`: `langsmith-load-results/1`, written by the load test; its fields are in
  [the load test's results-fields.md](../../langsmith-load-test/docs/results-fields.md). A `metrics` object keyed by watch
  item id, if present, is read by `compare` as "observed".

#### Warning ids

`severity` is `action` (the plan is wrong or unproven in a way you must act on) or `info`. A warning's `figures`
are the numbers its message cites; which keys each id carries is in [fields.md](fields.md) under
`warnings[<id>].figures`.

| Id | Severity | Means |
|:--|:--|:--|
| `postgres-connections` | action | the pods open more connections than the budget |
| `redis-needs-cluster` | action | Redis needs more shards or memory than one node |
| `redis-over-shard-cap` | action | more shards than the managed cap |
| `beyond-published` | action | past the scale guide's highest configuration |
| `beyond-payload-tested` | action | past the 300 traces/s the payload figures were measured at (the `beyond-tested` regime is a different edge: a peak above 202,700 runs/s) |
| `beyond-tiers` | action | past SmithDB's largest band |
| `object-store-unmeasured` | action | an in-cluster object store past the measured load |
| `pod-does-not-fit-node` | action | the largest pod of a pool is larger than its node |
| `clickhouse-does-not-fit-node` | action | one ClickHouse pod does not fit its node |
| `single-node-hook-peak` | action | everything plus the largest hook Job does not fit the one node |
| `ceilings-above-chart-default` | info | autoscaler ceilings above the chart's default |
| `gateway-below-tested` | action | the chart's LLM gateway asks less than the docs measured its streams a replica at |
| `sandboxes-memory-bound` | action | memory, not CPU, sets the sandbox hosts; the values hold them as the autoscaler's floor |
| `postgres-connections-at-scale` | action | past the tiers, the connections the pods hold and the max_connections to set, with PgBouncer |
| `offload-throttled` | action | past the rate where offloaded payloads throttled the load test's object store, payloads still offloaded |
| `ingestion-hot-project` | info | one busy project's runs land on the same SmithDB ingestion pods; larger-memory nodes, not more pods |
| `scale-out-extrapolated` | info | past the tiers the plan rests on one synthetic load test: reads never measured (SmithDB query pods stay at the large tier), a run size far from its 128 KiB, a rate above the 114.6k it held for long, a chart line other than the 0.17.48 it ran |
| `products-single-replica` | info | a product's Deployments run one replica on an install that must survive a node loss |
| `chart-ask:<workload>` | info | the chart cannot express the recommended trigger; the message says what was applied instead |

#### Provenance

`provenance` maps a path to `{"kind": ..., "from": [...]}`. `kind` is `input`, `param`, `chart`, `docs` or
`derived`; `from` lists sources as `input:<name>`, `param:<id>`, `chart:<values key>`, `docs:<citation id>`
or `derived:<what>`. It is per section, not per number. The paths that carry it: `inputs.<name>` for each
input; `rates`, `rates.bands`, `rates.beyond_published`, `rates.beyond_payload_tested`, `rates.extrapolation`;
`guide`, `payload`, `ingest`; `workloads.<name>`; `smithdb`, `smithdb.auto`, `smithdb.metastore`;
`stores.object_storage`, `stores.redis`, `stores.postgres`, `stores.smithdb_metastore` and `stores.clickhouse`
(while dual); `regime`, `scale`, `configure`, `watch`, `warnings`, `values`, `totals`, `pools`. A
figure under a path inherits that path's sources; the individual numbers inside are not listed.
