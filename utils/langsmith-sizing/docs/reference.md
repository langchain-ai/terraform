# Reference

The detail behind the [README](../README.md): every command and flag, how totals and node pools are
counted, where each store runs, the module map, and what each output is for. Every field of every output,
with its type, unit and meaning, is in [fields.md](fields.md), which `make reference` generates from real plans.

## Commands

```
uv run langsmith-sizing size          --chart X.Y.Z [inputs]    plan as JSON on stdout
uv run langsmith-sizing values        --chart X.Y.Z [inputs]    chart values (YAML)
uv run langsmith-sizing stores        --chart X.Y.Z [inputs]    store specs (JSON)
uv run langsmith-sizing load-profile  --chart X.Y.Z [inputs]    the load the plan was sized for (JSON)
uv run langsmith-sizing wizard        [--chart X.Y.Z] [inputs] [--out DIR] [--yes]
uv run langsmith-sizing compare       --plan plan.json --results results.json
uv run langsmith-sizing profile-report --chart X.Y.Z [--root DIR]
uv run langsmith-sizing check-params  [--chart X.Y.Z]
uv run langsmith-sizing check-citations [--ref BRANCH_OR_COMMIT]
uv run langsmith-sizing chart-info    --chart X.Y.Z [--key a.b.c]
```

The chart is pulled once per version into `~/.cache/langsmith-sizing` (`LANGSMITH_SIZING_CACHE` moves
it). `helm` must be on `PATH`. An error prints `error: <what>` and exits 1.

### Inputs

`size`, `values`, `stores`, `load-profile` and `wizard` take the same inputs: `--preset NAME`, or `--users`
with a rate (`--traces-per-second` or `--traces-per-month`). Any flag replaces the preset's value (a traces
flag replaces its average, and leaves the preset's peak where it was: overriding a preset's rate means
giving its peak too, and a peak below the average is refused).

| Flag | Meaning |
|:--|:--|
| `--users` | concurrent frontend users at the busiest time |
| `--traces-per-second`, `--traces-per-month` | the average rate |
| `--peak-traces-per-second` | the busiest hour's rate, when known; otherwise the average times the model's peak factor of 3 |
| `--runs-per-trace`, `--retention-days` | the shape of a trace and how long it is kept |
| `--trace-store` | `smithdb`, `dual` or `dual-replicated`: SmithDB alone, or beside the deprecated ClickHouse during a migration |
| `--survives-node-loss` / `--no-survives-node-loss` | serving pods keep at least two replicas |
| `--postgres`, `--redis`, `--smithdb-metastore`, `--clickhouse` | where each store runs: `external`, `statefulset` or `operator` |
| `--object-store` | `external` (a bucket) or `in-cluster` |
| `--datastores-on` | `app` (in-cluster stores share the application pool) or `dedicated` |
| `--app-node`, `--smithdb-node`, `--datastore-node` | the node shape the pool is counted in, as `8x32` (vCPU x GiB) |
| `--smithdb-tier`, `--smithdb-topology` | SmithDB's tier (`small`, `medium`, `large`) and layout (`cluster`, or `unified` on a chart with `smithdb.topology`); default the load's, and the regime's for a low one |
| `--backfill-runs`, `--backfill-days` | ClickHouse history to copy into SmithDB, and the days to copy it in; both or neither |

`make wizard` writes all four files (`plan.json`, `values.yaml`, `stores.json`, `load-profile.json`) to `OUT`;
`make plan`, `make values`, `make stores` and `make profile` each write only their own file from the same inputs,
and `make load` needs `load-profile.json` from `make wizard` or `make profile`. `make reference` rewrites
`docs/fields.md` and the load test's `docs/results-fields.md`.

`make` takes the common ones as variables (`PRESET`, `USERS`, `TRACES_PER_SECOND`,
`PEAK_TRACES_PER_SECOND`, `RUNS_PER_TRACE`, `RETENTION_DAYS`, `CHART`, `OUT`) and any other flag as `ARGS`.

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

`plan["totals"]` and `plan["pools"]` say what the namespace asks for and how many nodes carry it. The
shape follows the calculator's `compute()`, so the names match its result fields.

`plan["totals"]` holds the namespace's requests before and after overhead, at the sized replicas and at the
autoscalers' floors, `applied.{floor,sized,ceiling}` (requests, limits and volume GiB at each replica count) and
`hooks` (the chart's hook Jobs, and `peak`: the namespace at its `base` of ceiling plus the largest Job).
`plan["pools"]` has `app`, `smithdb` and, with `--datastores-on dedicated`, `datastores`, each with the same sums
at the floors and the sized replicas, the node shape counted in and where it came from, the largest pod and
whether it fits, and nodes at each of `applied.{floor,sized,ceiling}`; the one-node regime adds `single_node`.
Each field is in [fields.md](fields.md).

Nodes are `max(ceil(cpu x overhead / node vCPU), ceil(mem x overhead / node GiB), floor)`; a pod fits a
node only strictly below it. The default shapes are the calculator's reference shapes in `params.yaml`
(application 8 vCPU / 32 GiB, SmithDB by tier 16 / 64, 32 / 128, 64 / 256, a floor of two nodes each).
In-cluster stores share the application pool as the calculator counts them, or get their own with
`--datastores-on dedicated`.

The calculator's names read the model's figures before a regime adjusts the replicas (under
`regime_adjusted`); everything under `applied` is what the chart values do. Hook Jobs are read from the
chart rendered with the plan's values: Helm runs them one at a time, so the peak is the ceiling plus the
largest Job. The one-node regime also gets `pools.single_node`: whether everything plus that Job fits one
node.

## Where each store runs

Each store is placed: `postgres`, `redis`, `smithdb_metastore` and `clickhouse` (only while the trace
store is dual) as `external`, `statefulset` or `operator`; `object_store` as `external` or `in-cluster`.
`plan["stores"][name]` gains `placement` and `spec`, and `plan["dbs"]` lists the instances the cluster
runs, under the calculator's ids (`ls-postgres`, `ls-redis`, `clickhouse`) and ours.

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

## The model, module by module

```
inputs.py      what a person says
model/         pure functions, numbers in and numbers out
  load         rates, load bands, the scale guide's grid and the blend between its corners
  payload      the payload mix and the per-run curves (SmithDB, blob and Redis KB a run)
  services     application replicas, ingest-queue CPUs and pods, platform-backend, KEDA
  smithdb      the tier by peak runs a second and by reads, replicas, splits, metastore
  stores       object storage, Redis memory and shards, Postgres connections, ClickHouse while dual
  datastores   each store sized for where it runs
  totals       the namespace's requests, limits and volumes, node counts per pool
  regime       extra-lite, lite, standard, large or beyond-tested, by bands in params.yaml
  scale        per workload: the recommended trigger, what the chart supports, the exact chart keys, the gap
  configure    commonEnv, the dedicated SmithDB services, Redis noeviction, the Go CPU limit, per-operation memory limit
  watch        what to watch, with a threshold only where a parameter, the chart or the plan gives one
plan.py        size(inputs, chart, params, cited) -> the plan, with a provenance map
deploy.py      store placements and specs, dbs, totals, pools
values.py      the chart values overlay, with <placeholders> where the plan cannot know
wizard.py      the questions, the headline, the four files
presets.py     presets/<name>.yaml -> inputs
profile.py     the same inputs -> the load profile
compare.py     a plan and a load test's results -> one verdict per promise
profile_report.py  each preset's plan beside the modules' hand-written profiles
units.py       the unit conversions and float tolerances: the only numbers the code spells out
docs_gen.py    the docs' generated tables, from params.yaml and citations.yaml
figures.py     the docs' figures in the LangChain brand, light and dark, from the same data
```

A parameter that overrides a chart setting names it (`chart_key`); `check-params --chart` and the tests
fail when the chart already gives that value, so no number has two sources. A scalar parameter that
names no chart setting says why in `chart_has_no_key`, or the same check fails.

## The load profile

`load-profile` writes the load once, from `params.yaml`, so the plan and the load test share it: write
rate (average and peak), runs a trace, payload mix and sizes, feedback per trace, read rate and mix, the
SLO targets, and the provenance of each figure. The load test reads it with `--profile`; it needs neither
`helm` nor a chart.

## Schemas for tool authors

Stability: each output carries a schema id or number (`"schema": 1` in `plan.json` and `stores.json`,
`langsmith-load-profile/1`, `langsmith-load-results/1`). A breaking change to a field's name, place or
meaning changes that number; adding a field does not. Read the number before the fields, and refuse one you
do not know. Values are the plan's own; a figure is `null` only where [fields.md](fields.md) says so.

### What each output is for

- `plan.json`: the whole plan. Keep it: `compare` reads it. Its sections, in the order to read them: `inputs` and
  `rates` (what you gave and what it resolved to), `regime` (the load band and what it turns on), `workloads` and
  `smithdb` (replicas, floors, ceilings, requests, limits), `stores` and `dbs` (each store's size, placement and
  spec), `scale` (the recommended trigger, what the chart supports, what is applied, the chart ask), `configure`
  and `watch` (what to set and what to read), `warnings`, `totals` and `pools`, `values` (the overlay
  `values.yaml` is written from) and `provenance`.
- `stores.json`: what to provision, `{"schema": 1, "chart", "stores", "dbs", "warnings"}`. Each store is
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
| `beyond-tested` | action | past the load the payload figures were measured at |
| `beyond-tiers` | action | past SmithDB's largest band |
| `object-store-unmeasured` | action | an in-cluster object store past the measured load |
| `pod-does-not-fit-node` | action | the largest pod of a pool is larger than its node |
| `clickhouse-does-not-fit-node` | action | one ClickHouse pod does not fit its node |
| `single-node-hook-peak` | action | everything plus the largest hook Job does not fit the one node |
| `ceilings-above-chart-default` | info | autoscaler ceilings above the chart's default |
| `chart-ask:<workload>` | info | the chart cannot express the recommended trigger; the message says what was applied instead |

#### Provenance

`provenance` maps a path to `{"kind": ..., "from": [...]}`. `kind` is `input`, `param`, `chart`, `docs` or
`derived`; `from` lists sources as `input:<name>`, `param:<id>`, `chart:<values key>`, `docs:<citation id>`
or `derived:<what>`. It is per section, not per number. The paths that carry it: `inputs.<name>` for each
input; `rates`, `rates.bands`, `rates.beyond_published`, `rates.beyond_tested`, `rates.extrapolation`;
`guide`, `payload`, `ingest`; `workloads.<name>`; `smithdb`, `smithdb.auto`, `smithdb.metastore`;
`stores.object_storage`, `stores.redis`, `stores.postgres`, `stores.smithdb_metastore` and `stores.clickhouse`
(while dual); `regime`, `scale`, `configure`, `watch`, `warnings`, `dbs`, `values`, `totals`, `pools`. A
figure under a path inherits that path's sources; the individual numbers inside are not listed.
