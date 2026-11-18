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
access for the first run of each chart version, which pulls the chart into a cache. Then, once:

```bash
make setup
```

## Size an install

A team runs 20 million traces a month. Their agents make about 12 calls a trace, and about 20 people
read traces at the busiest hour. They run on EKS with managed Postgres, Redis and S3, use 16 vCPU, 64 GiB
application nodes (`16x64`, vCPU x GiB), and must keep serving when a node is lost. Every fact goes in as
an input:

```bash
make plan NAME=acme USERS=20 TRACES_PER_MONTH=20000000 RUNS_PER_TRACE=12 ARGS="--postgres external --redis external --smithdb-metastore external --object-store external --survives-node-loss --app-node 16x64"
```

Or let the wizard ask, one question at a time, each with its default and where the default comes from.
It offers the [presets](presets/README.md) as starting points, takes a month's count as `20M/month`, and
skips what cannot matter (where in-cluster stores run, when none is in the cluster):

```bash
make wizard NAME=acme
```

Either one prints the plan and saves it as a folder, `out/acme/`. Part of what it prints, at chart 0.17.56:

```
╭─ acme on chart 0.17.56 ──────────────────────────────────────────────────────────────╮
│ Chart                 0.17.56                                                        │
│ Regime                standard: no tighter regime holds at 7.6 traces/s and a peak   │
│                       of 274.1 runs/s                                                │
│ Load                  20 users, 7.6 traces/s average, 22.8 at peak (274.1 runs/s)    │
│ Retention             14 days base, 400 extended                                     │
│ SmithDB               medium tier, cluster topology (chosen by both)                 │
│ Survives a node loss  yes                                                            │
╰──────────────────────────────────────────────────────────────────────────────────────╯

Namespace capacity ─────────────────────────────────────────────────────────────────────
  at        vCPU requested   GiB requested   vCPU limit   GiB limit   volumes GiB
  floor     143.5            270.4           154.5        304.3       800
  sized     149.5            282.4           160.5        316.3       800
  ceiling   639.5            1198.4          650.5        1232.3      4000

Node pools ─────────────────────────────────────────────────────────────────────────────
  pool      node     nodes     largest pod     largest pod on a node
  app       16x64    2 to 3    ingest-queue    fits
  smithdb   32x128   5 to 23   smithdb-query   fits

Data stores ────────────────────────────────────────────────────────────────────────────
  store               runs       provision
  postgres            external   2 vCPU, 8 GiB, 10 GiB disk, max_connections 901 for the pods' pools
  redis               external   1 x 59 GiB, 2 vCPU a shard, noeviction
  smithdb metastore   external   4 vCPU, 32 GiB, 50 GiB disk
  object storage      external   SmithDB 4.3 TB, LangSmith 4.4 TB (expire ttl_s/ 14 d, ttl_l/ 400 d)
```

Below that come each workload's replicas, floor, ceiling and the signal it scales on, anything to act on
before deploying, and what to watch once it runs. Read it top down:

- **Regime** is the band the load falls in and the edge that put it there; it decides what the plan turns
  on (autoscalers, dedicated SmithDB services, a Redis cluster). [docs/how-it-sizes.md](docs/how-it-sizes.md#2-regime).
- **SmithDB** is the published tier the load needs, by its write rate and its readers.
- **Namespace capacity** is what the install asks the cluster for with every autoscaler at its minimum
  (floor), at the sized replicas, and at its maximum (ceiling). Size node pools for the floor with a cluster
  autoscaler able to reach the ceiling. The ceiling is a quota to allow, not a bill: the autoscalers reach
  it only under a backlog. [docs/autoscaling.md](docs/autoscaling.md) says why.
- **Node pools** count nodes of your shape. `DOES NOT FIT` means one pod asks for more than a node has,
  and the top box says `Act on first`: give that pool a larger node (`ARGS="--smithdb-node 16x64"`), or
  move the store it names out of the cluster.
- **Data stores** is what to provision outside the chart, or what the chart runs in the cluster.

The folder holds everything the next steps need:

| File | What it is |
|:--|:--|
| `inputs.yaml` | Your answers and where each came from. `make plan NAME=acme` sizes it again, on a new chart with `CHART=`. |
| `summary.md` | The tables above, to send to whoever deploys it. |
| `values.yaml` | The chart values that apply the plan. Each `# fill:` line names a value only you know (a secret name, a bucket). |
| `stores.json` | Each data store's placement and the instance to create. |
| `load-profile.json` | The load the plan was sized for, which the load test sends. |
| `plan.json` | The whole plan, every figure with its source ([docs/fields.md](docs/fields.md)). |

`make list` shows every saved sizing and `make show NAME=acme` draws one again. `OUT=<folder>` saves
elsewhere. A value you give replaces the preset's, the saved answer or the default; every flag is in
[docs/reference.md](docs/reference.md).

## Deploy it

1. Provision each store marked `external` in `stores.json`, to its spec.
2. Fill the `# fill:` lines in `values.yaml`, then pass it to `helm upgrade --install` after your own values.
3. Set the namespace quota at the ceiling plus the largest hook Job: a lower quota blocks the autoscalers
   when they act and fails an upgrade.

## Prove it

The [load test](../langsmith-load-test/README.md) sends `load-profile.json` at your install, writing
traces to the project named in its own `.env`. Run it only against an install you own.

```bash
cp ../langsmith-load-test/.env.example ../langsmith-load-test/.env   # your endpoint, API key, and LANGSMITH_TRACING=true
make load NAME=acme       # 10 minutes at the average rate with reads; PEAK=1 for the peak, DURATION= and RAMP= to change
make compare NAME=acme    # one verdict per promise; exit 1 on a failed one
```

`compare` judges the rate held after the ramp, the stored-within and trace-load targets, and lists each
watch item as not measured, since a client cannot see server metrics: read those from your monitoring
([docs/monitoring.md](docs/monitoring.md)). A figure that fails goes back into an input and a new plan,
never into the values by hand.

## With Claude

[Claude Code](https://claude.com/claude-code) opened in this repository has the `langsmith-sizing` skill
and agent (`.claude/` at the repository root). Describe the install in your own words, for example "20M
traces a month, agents of about 12 calls, 20 people in the UI, EKS with RDS and ElastiCache, must survive a
node loss", and Claude asks what is missing, writes `out/<name>/inputs.yaml` with a note on where each
figure came from, runs `make plan`, and explains each number from its source in the chart, the docs or
`params.yaml`. It never runs the load test or touches a cluster: those stay yours.

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
make check       # every gate CI runs, one line each: ruff, mypy, tests (helm required), check-params on every planned chart, check-citations, the load test's
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
