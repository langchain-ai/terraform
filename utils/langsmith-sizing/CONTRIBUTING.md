# Contributing to langsmith-sizing

> **Status:** current. Everything here runs from this folder; `make check` needs only uv and helm.

## Maintaining it

```bash
make check       # every gate CI runs, one line each: ruff, mypy, tests (helm required), check-params on every planned chart, check-citations, the load test's
make reference   # rewrite docs/fields.md, the docs' generated tables and the load test's results fields
make figures FONTS=<dir> LOGOS=<dir>   # draw each figure whose data changed, light and dark (needs Chrome and the brand faces)
```

- **A parameter** is an entry in `params.yaml` with `value`, `unit`, `why`, `source` (kind and ref), `by`
  and `since`. One that overrides a chart setting names it in `chart_key`; one with no chart setting says
  why in `chart_has_no_key`. Run `make reference` and `make figures` after: the docs' tables and figures read it.
- **A citation** moves only after every quote in `citations.yaml` has been re-read against the docs; then
  move `commit`. `make citations` fails a quote that is gone.
- **A chart version** is an edit to `charts.yaml`, then `make check`. That file is the one home of the
  versions the package plans for; a command without `--chart` takes the newest release in the chart
  repository, and a plan on a chart outside the list says so in an info warning.
- **A preset** is a file in `presets/` with a note for every input, and a row in `presets/README.md`
  regenerated from `uv run langsmith-sizing size --preset <name> --chart <version> --json`.

## How it is proven

- **Measured where it matters.** `cases/scale-test.yaml` holds what a 20k to 200k runs/s load test ran,
  and `tests/test_scale_test.py` keeps every plan past the docs' tiers between 0.9x and 1.6x of it
  (ingest at least what ran: see how-it-sizes, section 14), and never smaller as its peak crosses into
  scale-out.
- **Measured on your install.** The load test, run with `--namespace`, reads the plan's watch items and
  each workload's runs a core from the install it loads (`../langsmith-load-test/src/loadtest/cluster.py`).
  A coefficient in `params.yaml` that such runs can replace should cite the results file that measured it;
  vary one payload-shape flag at a time (`load.payload_shape`), so a difference has one cause.
- **No stray numbers.** `tests/test_literals.py` fails a number in the code that is not a parameter, a
  citation, the chart or an input.
- **The plan matches what the chart renders.** `tests/test_values.py` renders the chart with each
  preset's `values.yaml` at every planned chart and checks the replicas, requests, limits and every
  autoscaler's floor and ceiling against the plan.
- **The docs cannot drift.** The tables marked generated, and the figures, are built from `params.yaml` and
  `citations.yaml`; a test fails when a table is stale or a figure was drawn from older data. The figures
  are drawn in the LangChain brand, whose faces are licensed and never committed: `make figures` reads them
  from the folder `FONTS=` names, and refuses a final render without them.
- **Open questions are tests.** Three of the six presets' questions are written to the answer the preset's
  name promises and marked `expectedFailure`, so fixing one fails the suite until the marker goes.

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
  regime       extra-lite, lite, standard, large, scale-out or beyond-tested, by bands in params.yaml
  scale        per workload: the recommended trigger, what the chart supports, the exact chart keys, the gap
  configure    commonEnv, the dedicated SmithDB services, Redis noeviction, the Go CPU limit, per-operation memory limit
  lite         extra-lite's requests from what a lab run measured
  scaleout     past the tiers: components scaled with the run rate at what a load test measured
  products     the pods and needs of each product beside tracing
  watch        what to watch, with a threshold only where a parameter, the chart or the plan gives one
plan.py        size(inputs, chart, params, cited) -> the plan, with a provenance map
deploy.py      store placements and specs, totals, pools
values.py      the chart values overlay, with <placeholders> where the plan cannot know
wizard.py      the questions and the sizing folder
summary.py     a plan as tables, for the terminal and summary.md
ui.py          the terminal layout every command draws through
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

## Credits

The model began as Dzmitry Dubarau's sizing calculator, with SmithDB's tiers by Dariel Dato-on, the scale
guide's interpolation by Dzmitry Dubarau, devfreddy-langchain, Denis Karabanov, Hari Narayan and David
Cisneros, and the bare-metal module's sizing by Reed Bender. Each parameter names its author.

Hari Narayan wrote the load test this package's profile feeds, and his SmithDB guide for self-hosted
installs set the backfill sizing, the cache volume's StorageClass and the metastore's PostgreSQL version
the plan carries, each cited from the public docs. Ben Nagengast set the targets `compare` checks and ran the
20k to 200k runs/s load test the scale-out regime follows; its guide's watch list shaped what the load test
reads from an install. Emil Filipov's v18 load test found the runs a request that S3 tolerates. Quentin
Brosse proposed the queue partitions for a Redis cluster.
