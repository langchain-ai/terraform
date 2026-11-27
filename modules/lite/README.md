# LangSmith Lite: tracing on one box

> **Status:** Example · **Last verified:** 2026-11-27 (installed, verified and soaked on an Arch-family server: every size from 1 to 3 times its design rate, in simple and in realistic agent traces, 2026-11-26)

Self-hosted LangSmith's tracing, sized to one machine from the load and the retention you name: k3s,
every store beside the app, Prometheus and Grafana with a health dashboard and LangSmith's recommended
alerts, and Mission Control, installed from your laptop over ssh by one command. Or the same releases,
values and Secrets for a Kubernetes cluster you already run, one install a namespace. For a team that
wants its own LangSmith on one machine, for many isolated installs (one a customer), and for anyone who
needs a LangSmith to test against.

It has run on one machine so far, magus, an Arch-family server, where every size stored all of 700,309
runs at 1 to 3 times its design rate, and the sizing now follows what those runs used ([SIZING.md, What
the experiments measured](SIZING.md#what-the-experiments-measured);
[OPERATE.md](OPERATE.md#what-the-first-install-confirms) has what the first installs still confirm). It is
**not** highly available (the box is one failure domain), **not** a production blueprint, and **not** an
installer LangChain supports: LangChain supports the LangSmith application under your agreement, and you
own the box, its backups and its upgrades. Past size `l` is a full deployment: a cloud module
([`../aws`](../aws), [`../gcp`](../gcp), [`../azure`](../azure)) or the bare-metal module on a cluster
([`../baremetal`](../baremetal)).

## Where Lite fits

<img alt="Two panels. A full deployment, the cloud modules or the bare-metal module on a cluster: four tenants, each an organization, use one LangSmith install whose services scale out (platform-backend and backend 2 or 3 to 10 by HPA, ingest-queue 3 to 10 by KEDA, SmithDB a pod per role), over managed Postgres, Redis and object storage outside the cluster, in which every tenant's rows are interleaved: separation is logical. LangSmith Lite: four tenants, each with its own install, its own LangSmith, Postgres, Redis and RustFS, its own disk and its own keys: separation is physical, up to 50 runs a second an install, tracing only, each install one failure domain." src="diagrams/standard-vs-lite.png">

A full deployment is one LangSmith for many tenants: each is an organization in one install, and its rows
sit beside every other tenant's in shared managed stores that scale out. Lite turns that around: one
install a tenant, each with its own LangSmith, Postgres, Redis, RustFS, disk and credentials, so no two
tenants share a process, a database or a key. That is the shape for data that must stay apart, one
install a customer, and its cost is one install's: a machine of 2 to 16 vCPU, or a namespace pair on a
Kubernetes cluster you run ([ARCHITECTURE.md, Many installs](ARCHITECTURE.md#many-installs)).

Chart 0.18, tracing only, one replica of each pod and no autoscalers.

## Quick start

You need:

- on your laptop (macOS or Linux): `terraform` 1.11+, `helm` 3.12+, `python3` 3.9+, `ssh` and `curl`;
  for `verify` and `soak` also `kubectl` 1.28+ and `uv` 0.13.4+ (each verb checks what it needs);
- a Linux machine your laptop reaches by ssh key, as a user with sudo ([OPERATE.md, The
  machine](OPERATE.md#the-machine)), or AWS credentials for Lite to make one, allowed what
  [`infra/hosts/aws/iam-policy.json`](infra/hosts/aws/iam-policy.json) grants ([OPERATE.md, AWS
  permissions](OPERATE.md#aws-permissions));
- a LangSmith license key, from your LangChain account team.

```bash
git clone https://github.com/langchain-ai/terraform && cd terraform/modules/lite
make up        # asks what it needs, shows the plan, asks once more, then installs (10 to 20 minutes expected)
make access    # every login, and the tunnels to the UIs
```

The first `make up` asks for what an install cannot run without (where it runs, the machine and its ssh
user, the size, the retention, how it is reached, the first admin's email) and the license key. It keeps
the answers in `infra/terraform.tfvars` and the key in `infra/.secrets.env` (mode 600); the settings most
installs change are in `infra/terraform.tfvars.example`, and every one is in
[`infra/variables.tf`](infra/variables.tf). Then open http://localhost:8080 and log in with `admin_email`
and the password `make access` prints (it holds the tunnels open), and in another terminal run `make
verify`. Size `xs` runs no Grafana or Mission Control, so `make access` shows only LangSmith's login
there.

Any setting can be given on the command line instead, and is saved with the rest:
`make up box=m ssh_host=203.0.113.10 ssh_user=ubuntu short_ttl_days=30`. With `YES=1` nothing is asked:
what is missing fails and names what to pass, the plan applies without the question, and the license key
comes from `TF_VAR_langsmith_license_key`, so a script runs `YES=1 make up` the same way. To send your
own traces: [OPERATE.md, Sending traces](OPERATE.md#sending-traces).

| Verb | Does |
|:--|:--|
| `up` | makes the install match its settings: asks what is missing, plans, applies what changed, installs. Again after a change, or to finish an install that stopped |
| `plan` | the same plan, shown and not applied: nothing changes |
| `preflight` | whether a machine can be the box: read-only, no root |
| `verify` | do traces flow? Ten traces followed hop by hop; where they stop, that workload's logs |
| `soak` | does it hold its design load? `STEP=1`: the rate it holds, and what breaks first |
| `experiment` | every size from no data, held to its machine: verify, then 1x twice, 2x and 3x its design rate |
| `report` | the runs as figures, their numbers and the runs' own files |
| `compare` | experiments side by side, every size on one scale, each against the plan it ran with |
| `export` | the releases, values and Secrets for a cluster of one's own |
| `access`, `status`, `down` | use it, read it, delete it |
| `secrets`, `values`, `pins`, `render`, `check`, `tf` | change the license key; what is installed; the chart lines; the module's own gates; any Terraform command |

Each verb prints a heading, one line a step ending ok or FAILED, and the next command; a step's output
goes to `build/logs/`, shown only when it fails. `VERBOSE=1 make plan` prints the whole plan.

## Sizes

| `box` | Machine | Peak runs/s | On AWS, a month |
|:--|:--|--:|:--|
| `xs` | 2 vCPU, 16 GiB, 100 GiB | 1 | r7i.large, about $110 |
| `s` | 4 vCPU, 32 GiB, 200 GiB | 5 | r7i.xlarge, about $217 |
| `m` | 8 vCPU, 64 GiB, 640 GiB | 25 | r7i.2xlarge, about $464 |
| `l` | 16 vCPU, 64 GiB, 1,280 GiB | 50 | m7i.4xlarge, about $737 |

A run is one span: a trace of 10 calls at one trace a second is 10 runs/s, and 30,000 runs a month is
0.01 runs/s, well inside `xs`. **Retention is your choice to make:** the TTLs size the disk more than
anything else, so `make up` asks for them. [SIZING.md](SIZING.md) has every pod, volume and cost, the
same shapes on Azure and Google Cloud, and how each follows from the load and the TTLs.

Questions people ask first, and where each is answered:

| Question | Answer |
|:--|:--|
| What does Lite leave out? | Every product off the tracing path: the playground, Insights, Polly, Fleet, LangGraph deployments; custom code evaluators run with `code_evaluators = true`. Datasets and experiments the SDK runs use the same API, but nothing here has measured them ([SIZING.md, What the chart runs](SIZING.md#what-the-chart-runs-and-what-lite-keeps)) |
| Can Postgres and the object store be managed services? | Not yet; where it plugs in: [ARCHITECTURE.md, Security, known limits](ARCHITECTURE.md#security) |
| How is it upgraded, one install or a hundred? | [OPERATE.md, Changing and upgrading it](OPERATE.md#changing-and-upgrading-it) |
| How much disk does a retention take? | [SIZING.md, The retention](SIZING.md#the-retention) |
| Can many installs share a cluster, each on nodes of its own? | Many installs share one today, each in its own namespaces; a node pool an install is not built yet ([ARCHITECTURE.md, Many installs](ARCHITECTURE.md#many-installs)) |
| What if it is down? | One box is one failure domain: snapshots and `pg_dumpall` ([OPERATE.md, Keeping its data](OPERATE.md#keeping-its-data)) |

## The rest

| Read | For |
|:--|:--|
| [ARCHITECTURE.md](ARCHITECTURE.md) | how it installs, how a trace moves, why each piece, security, many installs, and Lite beside the other modules |
| [SIZING.md](SIZING.md) | every number: the computation, each size, each store, the retention's effect, the cost, the settings |
| [OPERATE.md](OPERATE.md) | the machine and AWS permissions, access, a real endpoint (DNS, certificates, SSO), proving it works, watching it, changing it, its data, a cluster of one's own, and when an install stops |

| Path | Holds |
|:--|:--|
| `Makefile`, `bin/lite` | the front door, and the one command behind it |
| `lib/` | what the verbs do (`deploy.sh`, `operate.sh`, `prove.sh`, `develop.sh`, `versions.sh`), shared plumbing (`common.sh`, `ui.sh`), and their Python (`settings.py`: the questions; `summary.py`: the plan; `export.py`; `prove.py`: the key for verify and soak), its tests (`tests/`) and its gate (`quality.py`: complexity under 15, CRAP under 30) |
| `box/` | what runs on the box: `checks.sh` (also `make preflight`) and `install.sh` |
| `infra/` | Terraform: `sizing.tf` with `sizes.yaml`, `releases.tf` and `values.tf`, `health.yaml` (the alerts and the health dashboard), `secrets.tf`, `bundle.tf`, `pins.yaml`, `hosts/aws/`, `tests/` |
| `diagrams/` | the docs' figures and `draw.py`, which draws them from the numbers the docs and the code hold; `make check` fails when one no longer matches |
| [`../baremetal/charts/datastores`](../baremetal/charts/datastores) | the Postgres, Redis and RustFS chart, shared with the bare-metal module |
| [`../../utils/langsmith-load-test`](../../utils/langsmith-load-test) | the load test behind `verify` and `soak` |
