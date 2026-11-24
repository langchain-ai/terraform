# LangSmith Lite: tracing on one box

> **Status:** Example · **Last verified:** 2026-11-24 (plan tests, chart renders, preflight on Arch; not yet installed on a box)

Self-hosted LangSmith's tracing on a single machine: k3s, every store as a StatefulSet beside the app,
Prometheus and Grafana with LangSmith's official dashboard, and Mission Control, installed by one
command and sized to the box. For a team that wants its own LangSmith with nothing to operate but one
machine, and for anyone who needs a LangSmith to test against.

It is **not** highly available (the box is one failure domain), **not** a production blueprint, and
**not** an installer LangChain supports: LangChain supports the LangSmith application under your
agreement, and you own the box, its backups and its upgrades. Past what one box holds, use a cloud
module (`../aws`, `../gcp`, `../azure`) or the bare-metal module for a cluster (`../baremetal`).

## What runs on the box

```
 the box (k3s, one node) -------------------------------------------------------------------
 |  langsmith       frontend  backend  platform-backend  ingest-queue  queue                 |
 |                  SmithDB (one unified pod)  Mission Control                               |
 |  langsmith-data  Postgres (LangSmith and SmithDB's metastore)  Redis  RustFS (S3)         |
 |  observe         Prometheus  Grafana  kube-state-metrics  node-exporter  two exporters    |
 |  kube-system     Traefik (ingress)  CoreDNS  metrics-server  local-path                   |
 --------------------------------------------------------------------------------------------
```

Chart 0.18, tracing only: ClickHouse, Fleet, Insights, Polly, Deployments and Sandboxes are not
deployed, the playground and code evaluators run no pod unless turned on, and there are no autoscalers:
every pod runs one replica, sized for the load you name. What that trims, replaces and gives up against
the AWS, GCP, Azure and bare-metal modules, side by side: [COMPARED.md](COMPARED.md). How it fits
together: [ARCHITECTURE.md](ARCHITECTURE.md).

## Where it runs

**The box** is any Linux machine with systemd, amd64 or arm64, reached over ssh: a server, a VM in any
cloud, or a VM on a laptop. Today `cloud = "baremetal"` takes any of them by address; `cloud = "aws"`
also makes the EC2 instance. Native GCP and Azure hosts are coming; until then, make a VM of the
preset's size there and use `baremetal`. k3s needs Linux, so on a Mac or Windows machine Lite runs in a
Linux VM (Lima, OrbStack, UTM, Hyper-V). `make preflight` says whether a machine can be the box before
anything is installed. What each system needs, and what has been tested: [infra/hosts/README.md](infra/hosts/README.md).

**Where you run `make`**: macOS or Linux, with `terraform` 1.11 or later, `helm` 3.12 or later,
`python3` 3.9 or later, `ssh` and `curl`; `uv` for the load test and `shellcheck` for `make check`.
`make init` checks them and names any missing.

## Quick start

```bash
make secrets                                             # the license key, kept in infra/.secrets.env (mode 600)
cp infra/terraform.tfvars.example infra/terraform.tfvars # then edit: where the box is, its size, access
make init                                                # checks the tools, then terraform init
make preflight                                           # can this machine be the box? read-only, no root
make plan                                                # resolves versions, sizes the box, refuses one too small
make up                                                  # asks, then applies and installs: 10 to 20 minutes the first time
make access                                              # every login, and the tunnels to the UIs
```

Then open http://localhost:8080 (or your domain) and log in with `admin_email` and the password
`make access` prints. `make` alone lists every verb:

| Stage | Verbs |
|:--|:--|
| Set up, once | `init`, `secrets` |
| Install | `preflight`, `plan`, `up` (`YES=1` skips its question), `install` (again, without an apply) |
| Use | `access`, `status`, `load`, `down` |
| Inspect and change | `values`, `pins`, `render`, `check`, `tf` (any Terraform command) |

Every verb prints a heading, one line a step ending ok or FAILED, and the next command; a step's
output goes to `build/logs/<time>/`, shown only when it fails. Terraform flags pass through `ARGS`
(`make plan ARGS="-var box=m"`), and `VERBOSE=1 make plan` prints the full plan.

## Sizes

| `box` | Machine | Sized for (peak) | Runs a day | Requests | Object store | All volumes |
|:--|:--|:--|--:|:--|--:|--:|
| `s` | 4 vCPU, 16 GiB, 160 GiB disk | 5 runs/s, 2 readers | 144,000 | 2.4 vCPU, 10.4 GiB | 71 GiB | 115 GiB |
| `m` | 8 vCPU, 32 GiB, 512 GiB disk | 25 runs/s, 5 readers | 720,000 | 5.4 vCPU, 18.1 GiB | 354 GiB | 456 GiB |
| `l` | 16 vCPU, 64 GiB, 1,536 GiB disk | 80 runs/s, 10 readers | 2,304,000 | 12.0 vCPU, 30.6 GiB | 1,133 GiB | 1,355 GiB |

A run is one span: a trace of 10 model and tool calls at one trace a second is 10 runs/s. The design
rate is the busiest minute; storage fills at the average, a third of it, and keeps each run for the
TTLs (14 days, 30 for the 5% on extended retention). The object store's volume is derived from that
traffic, so a lower rate or a shorter TTL needs less disk. Set `runs_per_second`, `readers`, the TTLs,
the payload mix or any pod's size, and `make plan` resizes the box and says whether it still fits.
Every number, what each pod is for, and what is not measured yet: [SIZING.md](SIZING.md).

## Access

| `access` | LangSmith at | Served on the box's addresses | Certificate |
|:--|:--|:--|:--|
| `localhost` (default) | http://localhost:8080 while `make access` runs | nothing of LangSmith's | none needed: ssh carries it |
| `ip` | `https://<box address>` | 443 | Traefik's self-signed one |
| `dns` | `https://<domain>` | 80 (redirect, Let's Encrypt), 443 | Let's Encrypt (point the name's A record at the box first) |
| `tunnel` | `https://<domain>` | nothing of LangSmith's | Cloudflare's, at its edge |

In every mode k3s's own API (6443) and kubelet (10250) also listen on the box's addresses, both
authenticated; on AWS the security group closes them, and on any other box a host firewall should
(OPERATE.md). Grafana and Mission Control are reached only through `make access`. Every login is
generated by Terraform and printed by `make access`. Details, and the tunnel's setup:
[OPERATE.md](OPERATE.md).

## Where things live

| Path | Holds |
|:--|:--|
| `Makefile` | The front door: each target is one verb of `bin/lite` |
| `bin/lite` | The command: help, and each verb |
| `lib/` | What the verbs do, by stage (`deploy.sh`, `operate.sh`, `develop.sh`), versions (`versions.sh`), shared plumbing (`common.sh`), how every command prints (`ui.sh`), the plan summary (`summary.py`) |
| `box/` | What runs on the box: the checks (`checks.sh`, also `make preflight`) and the install (`install.sh`) |
| `infra/` | The Terraform root: sizing (`sizing.tf`, `sizes.yaml`), every release's values (`values.tf`), the bundle (`bundle.tf`), the generated credentials (`secrets.tf`), versions (`pins.yaml`) |
| `infra/hosts/` | Where a box comes from: `aws/` built; any other machine by ssh ([hosts/README.md](infra/hosts/README.md)) |
| `infra/tests/` | Plan tests (`*.tftest.hcl`), and the render cases (`render-*.tfvars`) |
| `README.md`, `ARCHITECTURE.md`, `SIZING.md`, `COMPARED.md`, `OPERATE.md` | This page; how it works; every number; beside the other modules; running a box |
| `../baremetal/charts/datastores` | The Postgres, Redis and RustFS chart, shared with the bare-metal module |

## Status

Proven by the plan tests, by rendering every release through its real chart for each access mode, and
by `make preflight` on an Arch-family machine; not yet installed on a box. What the first installs
must confirm: [OPERATE.md](OPERATE.md#what-the-first-install-confirms).
