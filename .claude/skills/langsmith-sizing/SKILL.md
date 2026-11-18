---
name: langsmith-sizing
description: Size a self-hosted LangSmith install and set up the load test that proves it, for any customer, on any cloud or on their own hardware. Turns what a person says about their load (users, traces a month or a second, runs a trace, retention, where each data store runs, their node type) into a saved sizing folder with utils/langsmith-sizing, explains every number from its source (the Helm chart, the public docs, params.yaml), and prepares the load profile and the compare. Use when asked how big an install should be, what to provision, how many nodes, what to autoscale on, what to monitor, or to plan or read a load test. Triggers on: size, sizing, how big, how many nodes, capacity, self-hosted, LangSmith install, helm values, SmithDB tier, KEDA, autoscaling, load test, traces per second, traces per month, provision Postgres or Redis, what to monitor.
---

# Sizing a LangSmith install

The tool is `utils/langsmith-sizing` (README.md there is the front door). It is the canonical sizing
for these modules: every number comes from the chart at the version planned, from the public docs by
commit and quote, from the person's inputs, or from `params.yaml` with its evidence. You never size by
hand and never edit an output: you write the inputs, run the tool, and read what it says.

Work from `utils/langsmith-sizing/`. Every step is a make target; `make` alone prints them.

## 1. Gather the inputs

Ask only what the person has not said. Each answer goes into the sizing as data, with where it came
from. Nothing but users and a rate is required; every other input has a default the tool names.

| Input | Ask as | Turn their words into it |
|:--|:--|:--|
| `users` | How many people read traces at the same time at the busiest hour? | Concurrent readers, not seats: "200 engineers, mostly CI" is not 200. If they only know seats, say the figure is a guess and ask them to confirm. |
| `traces_per_second` or `traces_per_month` | How many traces a day or a month? | Give whichever they quote; the tool converts a month. |
| `peak_traces_per_second` | What is the busiest hour's rate? | Leave it out when unknown: the tool takes the average times its peak factor (`params.yaml load.peak_factor`) and says so. |
| `runs_per_trace` | How many steps (LLM calls, tool calls) in a typical trace? | An agent of 30 tool calls is about 30 runs. |
| `retention_days` | How long must a trace be kept? | The base TTL; the chart's default applies when not said. |
| `trace_store` | New install, or migrating from ClickHouse? | `smithdb`, or `dual` / `dual-replicated` during a migration. |
| `survives_node_loss` | Must it keep serving when a node is lost? | Ask; if they have not said, record your choice in its note as a guess. "Single zone is fine" is about zones, not nodes. |
| `postgres`, `redis`, `smithdb_metastore` | Managed (RDS, Cloud SQL, ElastiCache, Memorystore, Azure) or in the cluster? | `external` for managed or their own; `statefulset` for the chart's; `operator` for an operator. |
| `object_store` | A bucket, or storage inside the cluster? | `external` for S3, GCS, Azure Blob or any S3 API; `in-cluster` otherwise. |
| `products` | Besides tracing, do they run Agent Server deployments, Fleet, Insights, Chat, Engine, the LLM gateway or Sandboxes? | A list: `agent_server`, `fleet`, `insights`, `polly`, `engine`, `gateway`, `sandboxes`. Engine brings Sandboxes. Leave out what they do not run: it is switched off. |
| `agent_deployments`, `agent_load` | How many agent deployments, and how busy is each? | The load is the docs' Agent Server table column, read then write: `ll` (about 5 requests a second each), `mm` (50), `hh` (500), or the mixed `lh`, `hl`. |
| `gateway_streams` | How many concurrent LLM streams through the gateway at peak? | Leave out when unknown: the chart's autoscaler stays. |
| `sandboxes`, `sandbox_vcpu`, `sandbox_memory_gib`, `sandbox_node` | How many sandboxes run at once at peak, how big is each, on which KVM node? | Hosts are counted from these; the node must be x86-64 with `/dev/kvm` (a `.metal` or nested-virtualization type). |
| `app_node`, `smithdb_node` | Which machine or instance type? | vCPU x GiB, for example `[8, 32]`. Look the type up on the provider's page (WebFetch) or ask; never recall it. One type for the whole cluster goes in both. |

Cloud or self-hosted changes only the placements and the node shapes. The tool sizes the same pods
either way; mapping a node shape to an instance name is yours to look up.

A figure you chose rather than heard is a guess: say so in its note ("Guess: production, so yes"), and
list it in your answer.

## 2. Write the sizing and run it

A sizing is a folder, `out/<name>/` (gitignored). Write `out/<name>/inputs.yaml`, then run
`make plan NAME=<name>`. The file is a preset with the chart added:

```yaml
why: "<who it is for and what they run, one sentence>"
chart: 0.17.60            # exact, a line such as 0.18 (its newest), or omit for the newest release
inputs:
  users: 20
  traces_per_month: 50000000
  runs_per_trace: 30
  postgres: external
  survives_node_loss: true
notes:                    # one per input: where the figure came from, in the person's words
  users: "Their platform lead: about 20 people in the UI at once at peak."
  traces_per_month: "Their dashboard, October: 48M traces."
  runs_per_trace: "Their agent makes about 30 tool calls a trace."
  postgres: "RDS, their standard."
  survives_node_loss: "Production."
```

Pin `chart` to what the customer runs or will run. A line (`0.18`) or no chart resolves to the newest
in the chart repository when first sized, and the saved file then holds that exact version.

`make plan` keeps your `why` and each note whose value did not change, so the file stays the record of who
said what. Or start from a preset (`make presets`): `make plan NAME=<name> PRESET=production USERS=30`.
A person who wants to answer questions themselves runs `make wizard NAME=<name>`; it writes the same
file. Re-running `make plan NAME=<name>` re-sizes from the saved answers, on a new chart with `CHART=`.

The folder then holds `plan.json`, `values.yaml`, `stores.json`, `load-profile.json` and
`summary.md`. `make show NAME=<name>` draws it again.

## 3. Explain it

Read `summary.md` first, then `plan.json` for any figure asked about. Every figure has its source in
`plan.json` `provenance["<field path>"]`: `chart:<key>`, `docs:<citation id>` (quoted in
`citations.yaml`), `param:<id>` (in `params.yaml`, with why, source, author and date) or
`input:<name>`. Answer "where does this come from" from those, never from memory.

| Question | Where the answer is |
|:--|:--|
| Why this many replicas, this tier, these nodes | `docs/how-it-sizes.md`, the regime in `plan.json regime` |
| What it scales on and why | `plan.json scale`, `docs/autoscaling.md` |
| What to monitor, at what threshold | `plan.json watch`, `docs/monitoring.md` |
| What a field means | `docs/fields.md` |
| What the published guide says | the citation in `citations.yaml`; the live pages are docs.langchain.com `langsmith/self-host-scale` and `langsmith/self-host-smithdb-scale` |
| A chart default | `make chart KEY=<dotted.key>` (`CHART=` for a version) |
| What a product adds and needs | the Products and What the products need tables; `plan.json products`; `products.yaml` |
| Agent Server per deployment | `plan.json products.agent_server.each`: the resource_spec to set on each deployment |

Read the top box first. An `Act on first` line names warnings to resolve before anything else. The most
common is `DOES NOT FIT` under Node pools: one pod asks for more than a node of that shape has. Re-plan
with a larger node for that pool (`smithdb_node` or `app_node` in `inputs.yaml`), or move the store
named out of the cluster, and say which you did.

Say what is unmeasured. Every regime carries `observe: true` until a load test reads it, and a
named preset's open question is in `presets/README.md`. Warnings in `plan.json warnings` with severity other
than `info` must be acted on before deploying.

## 4. Deploy and prove it

- `values.yaml`: the person fills each `# fill:` line (secret names, hostnames), then runs
  `helm upgrade --install` with it. You do not run helm against their cluster.
- `stores.json`: what to provision for each store outside the chart.
- `make load NAME=<name>` sends the planned load at their install. It writes traces to the project in
  `../langsmith-load-test/.env`, so only the person runs it, and only against an install they own.
- `make compare NAME=<name>` judges `results.json` against the plan: one verdict per promise. A
  `not measured` server-side item needs the metric read from the install (`docs/monitoring.md`).

## Rules

- Never edit `plan.json`, `values.yaml` or `stores.json`. Change `inputs.yaml` and run `make plan`.
- A constant that should change goes in `params.yaml` with its evidence, in a pull request, never in
  a customer's folder.
- A sizing folder holds a customer's figures: never commit it, and never put a customer's name in the
  repository.
