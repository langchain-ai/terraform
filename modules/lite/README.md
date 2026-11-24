# LangSmith Lite: tracing on one box

> **Status:** Example, not yet installed on a box · **Last verified:** 2026-11-24 (plan tests, chart renders, Grafana provisioning, preflight on Arch)

Self-hosted LangSmith's tracing, sized to one machine from the load and the retention you name: k3s,
every store beside the app, Prometheus and Grafana with a health dashboard and LangSmith's recommended
alerts, and Mission Control, installed from your laptop over ssh by one command. Or the same releases,
values and Secrets for a Kubernetes cluster you already run, one install a namespace. For a team that
wants its own LangSmith on one machine, for many isolated installs (one a customer), and for anyone who
needs a LangSmith to test against.

No box has run it yet: the first installs are under way, and OPERATE.md lists what they confirm. It is
**not** highly available (the box is one failure domain), **not** a production blueprint, and **not**
an installer LangChain supports: LangChain supports the LangSmith application under your agreement, and
you own the box, its backups and its upgrades. Past size `l` is a full deployment: a cloud module
(`../aws`, `../gcp`, `../azure`) or the bare-metal module on a cluster (`../baremetal`).

```
 the box: any Linux machine, k3s, one node -------------------------------------------------
 |  <name>               frontend  backend  platform-backend  ingest-queue  queue            |
 |                       SmithDB (one pod)  Mission Control                                  |
 |  <name>-data          Postgres (LangSmith's and SmithDB's metastore)  Redis  RustFS (S3)  |
 |  <name>-observe       Prometheus  Grafana  kube-state-metrics  node-exporter  exporters   |
 |  kube-system          Traefik  CoreDNS  metrics-server  local-path                        |
 |  data disk            every store's volume, sized from the load and the TTLs              |
 -------------------------------------------------------------------------------------------
```

Chart 0.18, tracing only, one replica of each pod and no autoscalers.

## Quick start

You need:

- on your laptop (macOS or Linux): `terraform` 1.11+, `helm` 3.12+, `python3` 3.9+, `ssh` and `curl`;
  for `verify` and `soak` also `kubectl` 1.28+ and `uv` 0.13.4+ (each verb checks what it needs);
- a Linux machine your laptop reaches by ssh key, as a user with sudo (OPERATE.md, The machine), or AWS
  credentials for Lite to make one, allowed what `infra/hosts/aws/iam-policy.json` grants (OPERATE.md,
  AWS permissions);
- a LangSmith license key, from your LangChain account team.

```bash
git clone https://github.com/langchain-ai/terraform && cd terraform/modules/lite
make up        # asks what it needs, shows the plan, asks once more, then installs (10 to 20 minutes expected)
make access    # every login, and the tunnels to the UIs
```

The first `make up` asks for what an install cannot run without (where it runs, the machine and its ssh
user, the size, the retention, how it is reached, the first admin's email) and the license key. It keeps
the answers in `infra/terraform.tfvars` and the key in `infra/.secrets.env` (mode 600); the settings
most installs change are in `infra/terraform.tfvars.example`, and every one is in `infra/variables.tf`.
Then open http://localhost:8080 and log in with `admin_email` and the password `make access` prints
(it holds the tunnels open), and in another terminal run `make verify`. Size `xs` runs no Grafana or
Mission Control, so `make access` shows only LangSmith's login there.

Any setting can be given on the command line instead, and is saved with the rest:
`make up box=m ssh_host=203.0.113.10 ssh_user=ubuntu short_ttl_days=30`. With `YES=1` nothing is asked:
what is missing fails and names what to pass, the plan applies without the question, and the license key
comes from `TF_VAR_langsmith_license_key`, so a script runs `YES=1 make up` the same way. To send your
own traces: OPERATE.md, Sending traces.

| Verb | Does |
|:--|:--|
| `up` | makes the install match its settings: asks what is missing, plans, applies what changed, installs. Again after a change, or to finish an install that stopped |
| `plan` | the same plan, shown and not applied: nothing changes |
| `preflight` | whether a machine can be the box: read-only, no root |
| `verify` | do traces flow? Ten traces followed hop by hop; where they stop, that workload's logs |
| `soak` | does it hold its design load? `STEP=1`: the rate it holds, and what breaks first |
| `export` | the releases, values and Secrets for a cluster of one's own |
| `access`, `status`, `down` | use it, read it, delete it |
| `secrets`, `values`, `pins`, `render`, `check`, `tf` | change the license key; what is installed; the chart lines; the module's own gates; any Terraform command |

Each verb prints a heading, one line a step ending ok or FAILED, and the next command; a step's output
goes to `build/logs/`, shown only when it fails. `VERBOSE=1 make plan` prints the whole plan.

## Sizes

| `box` | Machine | Peak runs/s | On AWS, a month |
|:--|:--|--:|:--|
| `xs` | 2 vCPU, 16 GiB, 80 GiB | 1 | r7i.large, about $110 |
| `s` | 4 vCPU, 16 GiB, 160 GiB | 5 | m7i.xlarge, about $170 |
| `m` | 8 vCPU, 32 GiB, 600 GiB | 25 | m7i.2xlarge, about $371 |
| `l` | 16 vCPU, 64 GiB, 1,024 GiB | 50 | m7i.4xlarge, about $734 |

A run is one span: a trace of 10 calls at one trace a second is 10 runs/s. **Retention is your choice
to make:** the TTLs size the disk more than anything else, so `make up` asks for them. SIZING.md has
every pod, volume and cost, and how each follows from the load and the TTLs.

## The rest

| Read | For |
|:--|:--|
| [ARCHITECTURE.md](ARCHITECTURE.md) | how it installs, how a trace moves, why each piece, security, many installs, and Lite beside the other modules |
| [SIZING.md](SIZING.md) | every number: the computation, each size, each store, the retention's effect, the cost, the settings |
| [OPERATE.md](OPERATE.md) | the machine and AWS permissions, access, a real endpoint (DNS, certificates, SSO), proving it works, watching it, changing it, its data, a cluster of one's own, and when an install stops |

| Path | Holds |
|:--|:--|
| `Makefile`, `bin/lite` | the front door, and the one command behind it |
| `lib/` | what the verbs do (`deploy.sh`, `operate.sh`, `prove.sh`, `develop.sh`, `versions.sh`), shared plumbing (`common.sh`, `ui.sh`), and their Python (`settings.py`: the questions; `summary.py`: the plan; `export.py`; `prove.py`: the key for verify and soak) |
| `box/` | what runs on the box: `checks.sh` (also `make preflight`) and `install.sh` |
| `infra/` | Terraform: `sizing.tf` with `sizes.yaml`, `releases.tf` and `values.tf`, `health.yaml` (the alerts and the health dashboard), `secrets.tf`, `bundle.tf`, `pins.yaml`, `hosts/aws/`, `tests/` |
| `../baremetal/charts/datastores` | the Postgres, Redis and RustFS chart, shared with the bare-metal module |
| `../../utils/langsmith-load-test` | the load test behind `verify` and `soak` |
