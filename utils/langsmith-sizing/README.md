# langsmith-sizing

> **Status:** sizing, values, store specs and load profiles are generated and tested at charts 0.17.56
> and 0.18.0-rc.79. No plan has yet been checked end to end by a load test against a live install, so
> every preset carries an open question ([presets/README.md](presets/README.md)).

Turns the load a self-hosted LangSmith install must carry into a plan: how many replicas each service runs,
what each requests and scales on, what each data store needs, and what to watch once it runs. It writes the
chart values and store specifications that apply the plan, and the load profile a load test sends to check
it. It is for anyone sizing an install: a LangChain engineer, a customer's platform team, or a tool that
sizes LangSmith for a cluster.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/figures/how-it-works-dark.png">
  <img alt="How a plan is made. Four sources feed the model: the Helm chart (every default, rendered with helm at the version planned), the public docs (the scale guide, SmithDB's tiers, store requirements, the backfill rate, quoted by commit and checked), your inputs (users, traces a second, runs a trace, retention, where each store runs) and the parameters (the model's own constants in params.yaml, each with its evidence). The model runs eight stages in order: rates, regime, the scale guide's grid, payload, SmithDB, stores, operate and totals. It writes plan.json, values.yaml, stores.json and load-profile.json; the load test sends the profile at the install and compare judges its results against the plan." src="docs/figures/how-it-works-light.png">
</picture>

**What is canon.** The Helm chart and LangChain's public docs. The plan reads every default from the chart
at the version you install, and quotes every published figure (the scale guide's five configurations,
SmithDB's three tiers) from the docs by commit and exact text; CI fails when either moves. The model's own
constants are in [`params.yaml`](params.yaml), each with the evidence behind it. Every formula, and the
source of every number in it, is in [docs/how-it-sizes.md](docs/how-it-sizes.md).

| Read | For |
|:--|:--|
| [docs/how-it-sizes.md](docs/how-it-sizes.md) | What is canon, the published profiles it builds from, and every formula with a worked example |
| [docs/autoscaling.md](docs/autoscaling.md) | Why autoscaling matters here, which signal moves each workload, and what the chart cannot express yet |
| [docs/monitoring.md](docs/monitoring.md) | The metrics endpoints a running install serves, how to scrape them, and what to watch at each size |
| [presets/README.md](presets/README.md) | The six named loads, the regime each lands in, and each one's open question |
| [docs/reference.md](docs/reference.md) | Every make target and flag, the warning ids, the schemas for tool authors |
| [docs/fields.md](docs/fields.md) | Every field of `plan.json`, `stores.json` and the load profile, generated from real plans |

## Requirements

Python 3.11 or later, [uv](https://docs.astral.sh/uv/) 0.13.4 or later, `helm` on your `PATH`, and network
access for the first run of each chart version, which pulls the chart into a cache.

## Quickstart

### 1. Size an install

```bash
make setup
make wizard USERS=10 TRACES_PER_SECOND=5 PEAK_TRACES_PER_SECOND=15 YES=1
```

That is 10 concurrent users, 5 traces a second on average and 15 at the peak. Without `YES=1` the wizard
asks each input in turn, showing its default and where the default comes from. Without make:
`uv run langsmith-sizing wizard --chart 0.17.56 --users 10 --traces-per-second 5 --peak-traces-per-second 15 --out out --yes`.
It prints, at chart 0.17.56:

```
uv run langsmith-sizing wizard --chart 0.17.56 --users 10 --traces-per-second 5 --peak-traces-per-second 15 --out out --yes
regime lite: a peak of 15 traces/s is at or below 15
smithdb tier small (cluster), peak 15 traces/s
namespace requests (vCPU, GiB) before overhead
  at floor    42.8 vCPU, 117.2 GiB, volumes 742 GiB
  at sized    44.8 vCPU, 121.2 GiB, volumes 742 GiB
  at ceiling  184.8 vCPU, 401.2 GiB, volumes 4042 GiB
  with hook Jobs 185 vCPU, 401.5 GiB (largest: langsmith-smithdb-metastore-migration)
  sized x1.2 overhead: 53.7 vCPU, 145.4 GiB
node pools
  app        3-4 nodes of 8x32; largest pod ls-redis DOES NOT FIT
  smithdb    2-13 nodes of 16x64; largest pod smithdb-compaction-worker fits
stores
  postgres           statefulset, 1 x
  redis              statefulset, 1 x
  smithdb_metastore  external, instance
  object_storage     external, instance
warning postgres-connections: the pods open 262 Postgres connections against a budget of 80 (100 max_connections): size Postgres for them or lower the pools
warning chart-ask:ingest-queue: ingest-queue: the chart cannot express the recommended trigger (the KEDA scaler also fires on the feedback and adhoc backlogs against the same queueTargetSize, so a feedback flood can still scale it; ask a switch to scale on the run backlog alone (GO_FEEDBACK_QUEUE_PRIORITY keeps runs ahead of feedback meanwhile)); applied instead: keda on run_backlog
warning chart-ask:smithdb-query: smithdb-query: the chart cannot express the recommended trigger (scale on the SmithDB admission queue length (query_admission_queue_length), a trigger field the autoscaling block does not have); applied instead: hpa on cpu
warning chart-ask:smithdb-ingestion: smithdb-ingestion: the chart cannot express the recommended trigger (scale on memory utilization; scale on pending ingest segments (ingest_pending_segment_entry_count), a trigger field the autoscaling block does not have); applied instead: hpa on cpu
warning pod-does-not-fit-node: The largest pod of the app pool, ls-redis (2 vCPU, 32 GiB), does not fit a 8 vCPU, 32 GiB node: give the pool a larger node, or move that store out of the cluster
wrote out/plan.json, out/values.yaml, out/stores.json, out/load-profile.json
```

Read it top down.

- **`regime`** is the band the load falls in and the edge that put it there; it decides what the plan
  turns on. `lite` is unmeasured, so treat its figures as what to observe.
- **`smithdb tier`** is SmithDB's size and layout. The model's bands alone would plan `medium` here (two
  28 vCPU query pods, 109 vCPU at the floor); the `lite` regime keeps `small` and scales it out instead, to
  two ingestion pods at the 86 runs a second one pod was measured to hold and two query pods at the docs'
  tested 10 queries a second. On a 0.18 chart, a load one pod carries runs as a single unified SmithDB pod:
  `--chart 0.18.0-rc.79 --users 2 --traces-per-second 1 --peak-traces-per-second 3` plans 15 vCPU at the floor.
- **`namespace requests`** are what the install asks the cluster for, before overhead, at the
  autoscalers' floors, at the sized replicas and at their ceilings. `with hook Jobs` adds the largest Helm
  hook Job, which runs beside the pods during an install or upgrade: that is the namespace's true peak.
- **`node pools`** counts nodes of a stated shape (vCPU x GiB), a counting unit, not a provisioning
  instruction. `DOES NOT FIT` means one pod asks for more than a node of that shape.
- **`stores`** says where each store runs: `statefulset` in the cluster, `external` an instance to create.
- **`warning`** lines are what the plan already knows is wrong or unproven; a `chart-ask` is a scaling
  trigger the chart cannot express yet ([docs/autoscaling.md](docs/autoscaling.md)).

Here the in-cluster Redis must hold every run for its six-hour expiry, 32 GiB, which does not fit the 8x32
node: add `ARGS="--redis external"` for a managed Redis, or `ARGS="--datastores-on dedicated
--datastore-node 8x64"` for a pool of its own. A value you give replaces the preset's or the default; the
flags are in [docs/reference.md](docs/reference.md).

### 2. Deploy it

| File | What to do with it |
|:--|:--|
| `out/values.yaml` | Pass it to `helm` after your own values. Each `# fill:` line names a value the plan cannot know (a secret name, a bucket). Credentials are never in it. |
| `out/stores.json` | Provision from it: for each store, where it runs and the instance to create (vCPU, GiB, disk, connections, buckets with lifecycle rules). |
| `out/plan.json` | The whole plan. Keep it: `compare` reads it. |

Size node pools for the floor, with a cluster autoscaler able to reach the ceiling, and set the namespace
quota at the ceiling plus the largest hook Job: a quota below it blocks the autoscalers when they act and
fails an upgrade. [docs/autoscaling.md](docs/autoscaling.md) says why.

### 3. Verify it

`out/load-profile.json` is the load the plan was sized for: payload mix, runs a trace, feedback, read rate
and read mix. The [load test](../langsmith-load-test/README.md) sends it at your instance, writing to the
project named in its own `.env` (set `LANGSMITH_TRACING=true` there, since the read probe needs it).

```bash
cp ../langsmith-load-test/.env.example ../langsmith-load-test/.env   # then fill in your endpoint and API key
make load        # 10 minutes at the average rate with reads; PEAK=1 for the peak, DURATION= and RAMP= to change
make compare     # one verdict per promise; exit 1 on a failed one
```

`compare` judges the rate held after the ramp against the plan, the stored-within and trace-load targets,
and lists each watch item as "not measured by the load test", since a client cannot see server metrics:
read those from your monitoring ([docs/monitoring.md](docs/monitoring.md)). A figure that fails goes back
into an input and a new plan, never into the values by hand.

## Chart versions

[`charts.yaml`](charts.yaml) is the one place a chart version is written. The default is 0.17.56, the
release customers install today; the tests and `make params` also run against 0.18.0-rc.79, a release
candidate whose `smithdb.topology` can run SmithDB as one unified pod. Choose `CHART=` (or `--chart`) as
the chart your install runs: every default in the plan is read from it. The first run of a version pulls
the chart into `~/.cache/langsmith-sizing` (`LANGSMITH_SIZING_CACHE` moves it).

## How it is proven, and its limits

- **A calculator oracle.** The model began as LangChain Professional Services' sizing calculator, and
  `cases/calculator-<commit>.json` holds what that calculator returns for 180 inputs.
  `tests/test_conformance.py` compares the plan with each field by field, and a test that moves one
  parameter by 1% proves the comparison can fail. The fixture was recorded from LangChain's internal
  calculator, so outside readers can run the comparison but not regenerate it.
- **No stray numbers.** `tests/test_literals.py` fails a number in the code that is not a parameter, a
  citation, the chart or an input.
- **The plan matches what the chart renders.** `tests/test_values.py` renders the chart with each
  preset's `values.yaml` at both chart versions and checks the replicas, requests, limits and every
  autoscaler's floor and ceiling against the plan.
- **The docs cannot drift.** The tables in `docs/` marked generated, and the figures, are built from
  `params.yaml` and `citations.yaml`; a test fails when a table is stale or a figure was drawn from older
  data. The figures are drawn in the LangChain brand, whose faces are licensed and never committed: `make
  figures` reads them from the folder `FONTS=` names, and refuses a final render without them.
- **Open questions are tests.** Three of the six presets' questions are written to the answer the preset's
  name promises and marked `expectedFailure`, so fixing one fails the suite until the marker goes.

Only tracing is sized: Agent Server, Fleet, Insights, Polly and the gateway are not modeled. A plan says
vCPU and GiB, never an instance type or a price. Past about 300 traces a second, where the payload
measurements stop, the plan warns `beyond-tested`. 0.18.0-rc.79 is a release candidate.

## Maintaining it

```bash
make check       # every gate CI runs: tests (helm required), ruff, mypy, check-params on every planned chart, check-citations
make reference   # rewrite docs/fields.md and the docs' generated tables
make figures FONTS=<dir> LOGOS=<dir>   # draw each figure whose data changed, light and dark (needs Chrome and the brand faces)
```

- **A parameter** is an entry in `params.yaml` with `value`, `unit`, `why`, `source` (kind and ref), `by`
  and `since`. One that overrides a chart setting names it in `chart_key`; one with no chart setting says
  why in `chart_has_no_key`. Run `make reference` and `make figures` after: the docs' tables and figures read it.
- **A citation** moves only after every quote in `citations.yaml` has been re-read against the docs; then
  move `commit`. `make citations` fails a quote that is gone.
- **A chart version** is an edit to `charts.yaml`, then `make check`.
- **A preset** is a file in `presets/` with a note for every input, and a row in `presets/README.md`.

## Credits

The model is LangChain Professional Services' sizing calculator, by Dzmitry Dubarau, with SmithDB's tiers
by Dariel Dato-on, the scale guide's interpolation by Dzmitry Dubarau, devfreddy-langchain, Denis
Karabanov, Hari Narayan and David Cisneros, and the bare-metal module's sizing by Reed Bender. Each
parameter names its author.

Hari Narayan wrote the load test this package's profile feeds, and his SmithDB guide for self-hosted
installs set the backfill sizing, the cache volume's StorageClass and the metastore's PostgreSQL version
the plan carries, each cited from the public docs. Ben Nagengast set the targets `compare` checks. Quentin
Brosse proposed the queue partitions for a Redis cluster.
