# Architecture

> **Status:** current · **Last verified:** 2026-11-24

How Lite goes from `make up` to a running box, what runs on it, and why each piece is the one it is.

## From make up to a running box

```
 laptop (bin/lite)                                   box
 -----------------                                   ---
 make preflight  box/checks.sh --ssh------------->   read-only, as the ssh user
 make plan
   versions      chart lines -> exact versions        (live Helm repos)
                 datastores chart -> build/charts/
   terraform     sizes every pod, checks the fit,
                 renders the bundle (an output)
 make up         the plan's summary, then a question
   terraform     apply (aws: the instance)
   install       bundle, chart, box/ --ssh-------->  box/install.sh, as root
                                                       1 box/checks.sh again: refuses a machine that cannot be the box
                                                       2 k3s at the pinned version, from its release's own installer
                                                       3 namespaces, storage class, Traefik, Secrets
                                                       4 each release to k3s's helm-controller:
                                                         the stores, then LangSmith, observe, Mission Control
                                                       5 the ssh user's kubeconfig, so reading needs no root
                                                       6 removes what an earlier bundle had and this one lacks
```

Nothing on the laptop talks to the box's Kubernetes API. The box installs itself with k3s's own
controllers: whatever sits in `/var/lib/rancher/k3s/server/manifests` is applied, and each `HelmChart`
there is installed by k3s's helm-controller. So the same bundle installs the same way on any machine,
a later `make up` changes only what differs, and the box keeps working if the laptop goes away.

Terraform has no Kubernetes or Helm provider. It sizes the box, renders the bundle, generates the
credentials and, with `cloud = aws`, makes the instance; `bin/lite` does the rest over ssh. The plan
therefore runs before any machine exists, and refuses one too small for what it would run.

## What runs, and why each piece

| Piece | Why this one |
|:--|:--|
| k3s | One binary with its own ingress (Traefik), load balancer (servicelb), storage (local-path), metrics-server and a controller that installs Helm charts from files. The bare-metal module installs MetalLB, Envoy Gateway, local-path and metrics-server; on one box k3s's own do the same with nothing to install |
| LangSmith chart, tracing only | The supported chart at 0.18, with SmithDB as one unified pod (`smithdb.topology: unified`) and every other product off |
| `charts/datastores` from the bare-metal module | Postgres, Redis and RustFS as plain StatefulSets on their official images, already tested under load with that module: NetworkPolicies, PodDisruptionBudgets, Redis at `noeviction` with `maxmemory` at three quarters of its limit, Postgres's buffers from its limit, RustFS's buckets and expiry rules made by Jobs. Shared, not copied |
| One Postgres | LangSmith's database and SmithDB's metastore (Postgres 18) as two databases on one instance: a second Postgres on one box is memory for nothing |
| RustFS | The S3 API on the box's disk, holding SmithDB's data and the payload blobs (blob storage is required from chart 0.18) |
| Prometheus, Grafana | Prometheus scrapes what the chart's own scrape annotations mark (SmithDB, ingest-queue, platform-backend), the kubelet's per-container CPU and memory, the node, Redis and Postgres; Grafana shows LangSmith's official dashboard and three community dashboards (node, Redis, Postgres) |
| Mission Control | The chart's own operator UI: health, preflight checks, diagnostics bundles, database checks. Installed by its chart with its public images; its guided installer is not used |

## Namespaces

| Namespace | Holds |
|:--|:--|
| `langsmith` | LangSmith's pods, SmithDB, Mission Control, cloudflared with `access = tunnel` |
| `langsmith-data` | Postgres, Redis, RustFS; default-deny, admitting `langsmith` and `observe` |
| `observe` | Prometheus, Grafana, kube-state-metrics, node-exporter, the Redis and Postgres exporters |
| `kube-system` | k3s's own, and each release's `HelmChart` |

## Storage

| Volume | Class | Why |
|:--|:--|:--|
| Postgres, Redis, RustFS | `local-path-retain` | The stores' data must outlive a deleted claim; k3s's own class deletes the volume with it |
| SmithDB's cache | `local-path` | Disposable: SmithDB rebuilds it from RustFS |
| Prometheus | `local-path` | Metrics are worth keeping across restarts, not across a reinstall |

Every volume is on the box's one disk. Its size is the sum `make plan` prints plus about 30 GiB for
images and logs, and the plan refuses a disk smaller than that.

## Credentials

Terraform generates every credential (`infra/secrets.tf`) and keeps it in its state, which is local
and gitignored: back the state up with the box's data. The license key and a tunnel token, which
cannot be generated, are typed once into `infra/.secrets.env` (mode 600, gitignored, where every module
keeps them) and reach Terraform as environment variables, never as command-line arguments. The plan
file `make up` applies holds the license key too: it is written mode 600 under `build/` and removed once
applied.

The credentials reach the box inside the bundle, which the install writes to a private temporary
folder, sends through ssh and deletes. `box/install.sh` applies the Secrets with a server-side apply (a
client-side one would copy them into an annotation), deletes the file, and k3s encrypts Secrets in its
datastore (`secrets-encryption`). The k3s manifests stay in its manifests folder, root-only; they hold
no credential, since every release reads its credentials from a Secret by name (`make values` shows
the values). The first ssh to a new box learns its host key (`accept-new`) and refuses a changed one
afterwards.

## Root, and what is Lite's

Root on the box installs, upgrades and removes k3s, and nothing else: `make up`, `make install` and
`make down` ask for sudo once each. The install gives the ssh user its own kubeconfig, so `status`,
`access` and kubectl on the box run without it. k3s is marked as Lite's
(`/etc/rancher/k3s/installed-by-langsmith-lite`): the checks refuse a k3s server someone else installed,
and `make down` removes only a k3s that carries the mark.

## Versions

Every version and every upstream path is in `infra/pins.yaml`. Charts are pinned to a line, as the other modules pin
LangSmith's (`~0.17.0` in their `deploy.sh`), and `make plan` resolves each line against its live repo
into `infra/resolved.auto.tfvars.json`, so the plan, the box and the dashboard's release tag name one
exact version; a plan without them is refused. Lite is chart 0.18 only, so its line is its own and it
is not in the release tag's chart-line guard (`.github/scripts/chart-line.sh`), which holds the modules
on 0.17. k3s is pinned exactly: it is the box's operating layer, moved on purpose, and installed from
its release's own installer script. `make pins` shows what each line resolves to now and what is newer.

The bare-metal module's datastores chart is packaged under a name carrying a digest of its files, so
any change to it is a new chart for helm-controller to install.

## What Lite decides, and what it reads from the platform

A fact the chart owns is read from the chart, so a new chart release brings its own; Lite writes down
only what it decides.

| Read at the installed release, never copied | Decided here, as data |
|:--|:--|
| Each chart's exact version (from its pinned line) | The chart lines, and k3s's version (`pins.yaml`) |
| Mission Control's image tag (the chart's appVersion) | Which products run: tracing only (`values.tf`) |
| Which ports LangSmith serves metrics on (the chart's `prometheus-values.yaml`, applied as a values layer) | Every pod's size: the measured model and the presets (`sizes.yaml`) |
| The official dashboard (the chart repo's, at the release tag) | The stores' layout: one Postgres, one Redis, one RustFS (`values.tf`) |
| The stores' templates (the bare-metal module's datastores chart, packaged with a digest) | Retention, payload and volume settings (`variables.tf`) |

What remains a contract with the chart, and so moves only when the chart's own interface does: the
names of the values Lite sets, and the Secret keys the chart reads (`bundle.tf`, which names the
chart's documented keys). `make render` renders every release at the resolved versions with the plan's
values, so a chart that renamed a value fails there before it reaches a box.
