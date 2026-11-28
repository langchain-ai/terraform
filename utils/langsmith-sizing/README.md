# langsmith-sizing

> **Status:** sizing, values, store specs and load profiles are generated and tested at every chart in
> [charts.yaml](charts.yaml). No plan has yet been checked end to end by a load test against a live
> install, so every preset carries an open question ([presets/README.md](presets/README.md)).

Give it the load a self-hosted LangSmith install must carry (users, traces a second or a month, runs a trace,
retention, where each data store runs) and it writes the plan: replicas, requests and autoscaler for every
service, the spec of every data store, the chart values that apply it, and the load profile that proves it.
The load test sends that profile at your install and `compare` says which promises of the plan held.

## Quick start

You need Python 3.11+, [uv](https://docs.astral.sh/uv/) 0.13.4+, `helm` on your `PATH`, and network access
the first time each chart version is pulled.

```bash
make setup                                  # once: this package and the load test
make plan NAME=acme PRESET=lite             # or: make wizard NAME=acme (asks, one question at a time)
# fill the "# fill:" lines in out/acme/values.yaml, provision each external store in out/acme/stores.json, helm upgrade --install
cp ../langsmith-load-test/.env.example ../langsmith-load-test/.env   # set your endpoint, API key and project
make load NAME=acme NAMESPACE=langsmith     # sends the planned load and reads the install while it runs
make compare NAME=acme                      # one verdict per promise; exit 1 on a failed one
make plot NAME=acme                         # the install over the run, against the plan's alarm levels
```

`make plan NAME=acme USERS=20 TRACES_PER_MONTH=20000000 RUNS_PER_TRACE=12 ARGS="--postgres external --app-node 16x64"`
sizes a load of your own instead of a [preset](presets/README.md). Run `make load` only against an install you
own: it writes traces to the project in `.env`. The load test's flags, `.env` and exit codes are in its
[README](../langsmith-load-test/README.md). A figure that fails goes back into an input and a new plan, never
into the values by hand.

## Glossary

- **Regime**: the kind of load (extra-lite, lite, standard, large, scale-out, beyond-tested). It decides what
  the plan turns on.
- **Tier**: SmithDB's published size (small, medium, large), chosen from the write and read rate.
- **Floor, sized, ceiling**: the replicas, and the namespace totals, with every autoscaler at its minimum, at
  the replicas sized for the peak, and at its maximum. Size nodes for the floor, quota for the ceiling.
- **KEDA**: Kubernetes Event-driven Autoscaling, which scales a workload on a queue's depth instead of CPU.
- **Hook Job**: a Job Helm runs during an install or upgrade; the largest one adds to the namespace's peak.
- **Node shape**: the machine a pool is counted in, written vCPU x GiB, such as `16x64`. A counting unit, not
  an instance type.
- **Scale-out**: the regime past the docs' tiers (a peak from 10,000 runs/s), sized from a load test's
  measured rates rather than a published table.
- **Open question**: what a preset or regime has not been measured to do.

## Reading the plan

`make plan` prints the plan and saves it as `out/acme/`. Read it top down. The top box says what to act on
first; `DOES NOT FIT` under Node pools means one pod asks for more than a node has, so give that pool a larger
node (`ARGS="--smithdb-node 32x128"`) or move the store it names out of the cluster. Namespace capacity is
the floor, sized and ceiling totals; the ceiling is a quota to allow, not a bill. Data stores is what to
provision outside the chart, or what the chart runs in the cluster. `make list` shows every saved sizing,
`make show NAME=acme` draws one again, and `OUT=<folder>` saves elsewhere.

### The sizing folder

| File | What it is |
|:--|:--|
| `inputs.yaml` | Your answers and where each came from. `make plan NAME=acme` sizes it again, on a new chart with `CHART=`. |
| `summary.md` | The tables the command prints, to send to whoever deploys it. |
| `values.yaml` | The chart values that apply the plan. Each `# fill:` line names a value only you know. |
| `stores.json` | Each data store's placement and the instance to create. |
| `load-profile.json` | The load the plan was sized for, which the load test sends. |
| `plan.json` | The whole plan, every figure with its source. |
| `results.json`, `verdicts.json`, `results.html` | What `make load`, `make compare` and `make plot` add: the run, with the install's readings when it had `NAMESPACE=`; a verdict a promise, the watch items as readings set against their alarm levels; the run drawn over time. |

Set the namespace quota at the ceiling plus the largest hook Job: a lower quota blocks the autoscalers when
they act and fails an upgrade.

## What to read next

| Read | For |
|:--|:--|
| [docs/how-it-sizes.md](docs/how-it-sizes.md) | What is canon, the published profiles it builds from, every formula with a worked example |
| [docs/operate.md](docs/operate.md) | Which signal scales each workload, the metrics a running install serves, what to watch at each size |
| [presets/README.md](presets/README.md) | The six named loads, the regime each lands in, and each one's open question |
| [docs/reference.md](docs/reference.md) | Every command and flag, the warning ids, the output schemas, and every field of `plan.json` |
| [docs/parameters.md](docs/parameters.md) | Every citation from the public docs and every constant the model owns |
| [CONTRIBUTING.md](CONTRIBUTING.md) | The gates, how it is proven, the module map, how to change a parameter, citation, chart or preset |

## With Claude

[Claude Code](https://claude.com/claude-code) opened in this repository has the `langsmith-sizing` skill
(`.claude/` at the repository root). Describe the install in your own words and Claude asks what is missing,
writes `out/<name>/inputs.yaml` with a note on where each figure came from, runs `make plan`, and explains
each number from its source. It never runs the load test or touches a cluster.

## Lineage

The model began as a port of Dzmitry Dubarau's sizing calculator in the LangChain Enterprise Hub, and was
checked case by case against it until it stood on its own; it no longer depends on it. Use the calculator for
a first estimate with a LangChain architect, and this package for the plan you install and verify. A
difference between the two is a bug in one of them, reported to either.
