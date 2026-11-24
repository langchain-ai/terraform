# LangSmith Lite: tracing on one box

> **Status:** Example · **Last verified:** 2026-11-24 (plan tests, chart renders, preflight on Arch; not yet installed on a box)

Self-hosted LangSmith's tracing, sized to one machine from the load and the retention you name: k3s,
every store beside the app, Prometheus and Grafana with LangSmith's own dashboard, and Mission Control,
installed by one command. Or the same releases, values and Secrets for a Kubernetes cluster you already
run, one install a namespace. For a team that wants its own LangSmith with one machine to run, for
many isolated installs (one a customer), and for anyone who needs a LangSmith to test against.

It is **not** highly available (the box is one failure domain), **not** a production blueprint, and
**not** an installer LangChain supports: LangChain supports the LangSmith application under your
agreement, and you own the box, its backups and its upgrades. Past box `l` is a full deployment: a
cloud module (`../aws`, `../gcp`, `../azure`) or the bare-metal module for a cluster (`../baremetal`).

```
 the box: any Linux machine, k3s, one node ------------------------------------------------
 |  <namespace>          frontend  backend  platform-backend  ingest-queue  queue            |
 |                       SmithDB (one pod)  Mission Control                                  |
 |  <namespace>-data     Postgres (LangSmith's and SmithDB's metastore)  Redis  RustFS (S3)  |
 |  <namespace>-observe  Prometheus  Grafana  kube-state-metrics  node-exporter  exporters   |
 |  kube-system          Traefik  CoreDNS  metrics-server  local-path                        |
 |  data disk            every store's volume, sized from the load and the TTLs              |
 -------------------------------------------------------------------------------------------
```

Chart 0.18, tracing only, one replica of each pod and no autoscalers.

## Quick start

On macOS or Linux, with `terraform` 1.11+, `helm` 3.12+, `python3` 3.9+, `ssh` and `curl`, and a Linux
machine you can ssh to, or AWS credentials to make one:

```bash
make up        # asks what it needs, shows the plan, asks once more, then installs: 10 to 20 minutes
make access    # every login, and the tunnels to the UIs
```

The first `make up` asks for what an install cannot run without (where it runs, the machine, the size,
the retention, how it is reached, the first admin's email) and the license key, and keeps the answers
in `infra/terraform.tfvars` and the key in `infra/.secrets.env` (mode 600); every other setting is in
`infra/terraform.tfvars.example`. Then open http://localhost:8080 and log in with `admin_email` and the
password `make access` prints.

| Verb | Does |
|:--|:--|
| `up` | makes the install match its settings: plans, applies what changed, installs. Run again after a change, or to finish an install that stopped. |
| `plan` | the same plan, shown and not applied: nothing changes anywhere |
| `preflight` | whether a machine can be the box, before anything is installed: read-only, no root |
| `export` | the releases, values and Secrets for a cluster of one's own |
| `access`, `status`, `load`, `down` | use it, read it, put traces through it, delete it |
| `secrets`, `values`, `pins`, `render`, `check`, `tf` | change the key; inspect what is installed; the module's own gates; any Terraform command |

Settings can be given on the command line instead of asked, and are saved with the rest:
`make up box=m ssh_host=lab1 short_ttl_days=30`. With `YES=1`, or with no terminal, nothing is asked:
what is missing fails, naming what to pass, so a script or a fleet runs `make up` the same way. For a
cluster you already run, answer `cluster`: `make up` then writes the releases, values and Secrets
instead of installing a box.

Each verb prints a heading, one line a step ending ok or FAILED, and the next command; a step's output
goes to `build/logs/`, shown only when it fails. `VERBOSE=1 make plan` prints the whole plan; Terraform
flags pass through `ARGS`.

## Sizes

| `box` | Machine | Peak runs/s | Runs a day | Requests | Volumes | On AWS |
|:--|:--|--:|--:|:--|--:|:--|
| `xs` | 2 vCPU, 16 GiB | 1 | 28,800 | 1.3 vCPU, 7.7 GiB | 36 GiB | r7i.large, about $109 a month |
| `s` | 4 vCPU, 16 GiB | 5 | 144,000 | 2.4 vCPU, 11.6 GiB | 107 GiB | m7i.xlarge, about $169 |
| `m` | 8 vCPU, 32 GiB | 25 | 720,000 | 5.4 vCPU, 24.2 GiB | 468 GiB | m7i.2xlarge, about $370 |
| `l` | 16 vCPU, 64 GiB | 50 | 1,440,000 | 9.7 vCPU, 42.8 GiB | 944 GiB | m7i.4xlarge, about $733 |

A run is one span: a trace of 10 calls at one trace a second is 10 runs/s. Volumes are at the default
TTLs. **Retention is your choice to make:** `short_ttl_days` and `long_ttl_days` size the disk more than
anything else: `make up` asks for them, and a plan run without them says on every run that it is
using the defaults (14 and 30 days). `xs`
runs no observability stack or Mission Control: an install a fleet watches from one shared stack. AWS
prices are us-east-1 on-demand list prices for the instance, both disks, daily snapshots and the address.

## Access

| `access` | LangSmith at | Certificate |
|:--|:--|:--|
| `localhost` (default) | http://localhost:8080, through `make access` | none needed: ssh carries it |
| `ip` | `https://<box address>` | Traefik's self-signed one |
| `dns` | `https://<domain>` | Let's Encrypt |
| `tunnel` | `https://<domain>`, through a Cloudflare Tunnel | Cloudflare's |

Grafana and Mission Control, where they run, are reached only through `make access`.

## The rest

| Read | For |
|:--|:--|
| [ARCHITECTURE.md](ARCHITECTURE.md) | how it installs, how a trace moves, why each piece, many installs, and Lite beside the cloud and bare-metal modules |
| [SIZING.md](SIZING.md) | every number: the computation, each store and what bounds it, the TTLs' effect, the cost, the settings |
| [OPERATE.md](OPERATE.md) | the machine and its checks, access, watching, upgrading, data and snapshots, export, and what to do when an install stops |

| Path | Holds |
|:--|:--|
| `Makefile`, `bin/lite` | the front door, and the one command behind it |
| `lib/` | what the verbs do (`deploy.sh`, `operate.sh`, `develop.sh`, `versions.sh`), shared plumbing (`common.sh`, `ui.sh`), the questions, the plan summary and the export (`settings.py`, `summary.py`, `export.py`) |
| `box/` | what runs on the box: `checks.sh` (also `make preflight`) and `install.sh` |
| `infra/` | Terraform: `sizing.tf` with `sizes.yaml`, `releases.tf` and `values.tf`, `secrets.tf`, `bundle.tf`, `pins.yaml`, `hosts/aws/`, `tests/` |
| `../baremetal/charts/datastores` | the Postgres, Redis and RustFS chart, shared with the bare-metal module |
