# Architecture

> **Status:** current · **Last verified:** 2026-11-24

How Lite goes from `make up` to a running box, how a trace moves through it, why each piece is the
one it is, and how it differs from the other modules.

## From make up to a running box

```
 laptop: bin/lite                                      box: box/install.sh, as root
 ----------------                                      ----------------------------
 make preflight   box/checks.sh  ---ssh--->            read-only, as the ssh user

 make plan        resolve each chart line   (live Helm repos)
                  package the datastores chart
                  terraform plan: size every pod and volume,
                    check the fit, render the bundle

 make up          the plan's summary, then a question
                  terraform apply           (aws: the instance, its data volume, its snapshots)
                  bundle + chart + box/  ---ssh--->    1  checks.sh again
                                                       2  the data volume, mounted at k3s's storage folder
                                                       3  k3s at the pinned version
                                                       4  namespaces, priority class, storage class, Traefik, Secrets
                                                       5  each HelmChart into k3s's manifests folder,
                                                          the stores first; wait for each install Job
                                                       6  a kubeconfig for the ssh user
                                                       7  remove what this bundle no longer has

 cloud = cluster  terraform apply           (credentials only: there is no machine)
 (make export)    releases, values, Secrets, the datastores chart  --> files for the cluster's operator
```

Nothing on the laptop talks to the box's Kubernetes API. Terraform has no Kubernetes or Helm
provider: it sizes the box, renders the bundle, generates the credentials and, with `cloud = aws`,
makes the instance. `infra/releases.tf` says what each release is (chart, namespace, values, order);
`infra/bundle.tf` how they reach a k3s box; `make export` writes the same releases for a cluster. The box installs itself with k3s's own controllers: k3s applies whatever is in
`/var/lib/rancher/k3s/server/manifests`, and its helm-controller installs each `HelmChart` there. The
plan therefore runs before any machine exists, a second `make up` changes only what differs, and the
box keeps running if the laptop goes away.

## How a trace moves

```
 SDK --HTTPS--> Traefik --> frontend (nginx) --/runs--> platform-backend --> Redis (queue + payload)
                                                                                |
                                         payloads >= 20 KiB --> RustFS: blobs   |
                                                                                v
                                                                         ingest-queue
                                                                                |
                                                                                v
                                                     SmithDB  <--metadata--> Postgres (metastore)
                                                        |
                                                        v
                                                     RustFS: segments

 UI --> Traefik --> frontend --/api--> backend --> SmithDB (queries; its cache on local disk)
                                           \--> Postgres (orgs, projects, keys)
```

`queue`, LangSmith's background worker, reads Redis and Postgres beside this path. Each store holds
one kind of data with one bound on it: SIZING.md has the numbers. Redis and Postgres reserve their
memory (request equals limit), and all four stores run at a priority above the app's, so under memory
pressure an app pod, which restarts with no loss, is evicted before a store.

## What runs, and why each piece

| Piece | Why this one |
|:--|:--|
| k3s | One binary with an ingress (Traefik), a load balancer (servicelb), storage (local-path), metrics-server, and a controller that installs Helm charts from files. On one machine, these replace the MetalLB, Envoy Gateway, local-path and metrics-server the bare-metal module installs |
| LangSmith chart, tracing only | The supported chart at 0.18, with SmithDB as one unified pod and every other product off; the playground and ace-backend run no pod unless turned on |
| The bare-metal module's `charts/datastores` | Postgres, Redis and RustFS as StatefulSets on their official images, already proven under load with that module: NetworkPolicies, PodDisruptionBudgets, Redis at `noeviction`, Postgres's buffers from its limit, the buckets and their expiry rules made by Jobs. Shared, not copied |
| One Postgres | LangSmith's database and SmithDB's metastore as two databases on one instance |
| RustFS | S3 on the box's disk: SmithDB's segments and the payload blobs (blob storage is required from chart 0.18) |
| Prometheus, Grafana | The chart's own scrape annotations and dashboard, the kubelet's per-container use, node, Redis and Postgres dashboards |
| Mission Control | The chart's operator UI: health, preflight, database checks, diagnostics. Its write features are off |

| Namespace | Holds |
|:--|:--|
| `langsmith` | LangSmith's pods, SmithDB, Mission Control, cloudflared for a tunnel |
| `langsmith-data` | Postgres, Redis, RustFS; default-deny, admitting `langsmith` and `observe` |
| `observe` | Prometheus, Grafana, kube-state-metrics, node-exporter, the Redis and Postgres exporters |
| `kube-system` | k3s's own, and each release's `HelmChart` |

The stores' volumes use `local-path-retain` (`storage_class`), so a deleted claim never deletes data;
SmithDB's cache and Prometheus use k3s's `local-path` (`scratch_storage_class`), since both rebuild.
Every volume is a folder on one data disk, with no cloud disk per volume and no CSI driver: on AWS a
gp3 volume of its own, mounted at k3s's storage folder, outliving the instance and snapshotted daily; on
any other box `data_path`, or the root filesystem. k3s's kubelet evicts pods before a disk fills.

## What Lite decides, and what it reads

A fact the platform owns is read from it, so a new chart release brings its own; Lite writes down only
what it decides.

| Read at the installed release, never copied | Decided here, as data |
|:--|:--|
| Each chart's exact version, resolved from its pinned line (`infra/pins.yaml`) before every plan; a plan without it is refused | The chart lines, and k3s's exact version |
| Mission Control's image tag: the chart's appVersion | Which products run: tracing only (`infra/values.tf`) |
| LangSmith's metrics ports: the chart's `prometheus-values.yaml`, applied as a second values layer | Every pod's and volume's size (`infra/sizes.yaml`, SIZING.md) |
| The official dashboard, from the chart's repo at the release tag | The stores' layout: one Postgres, one Redis, one RustFS |
| k3s's installer, from its release's own tag | Retention, payload and access settings (`infra/variables.tf`) |

What stays a contract with the chart: the names of the values Lite sets, and the Secret keys it reads.
`make render` renders every release at the resolved versions with the plan's values, so a chart that
renamed a value fails there, before it reaches a box. Lite is chart 0.18 only, so its line is its own
and not in the release tag's chart-line guard, which holds the other modules on 0.17.

## Credentials, root, and what is Lite's

- **Credentials.** Terraform generates every one (`infra/secrets.tf`, with the Secrets that carry them)
  and keeps it in its state, local and gitignored. The license key and a tunnel token are typed once into `infra/.secrets.env` (mode 600)
  and reach Terraform as environment variables. The plan file `make up` applies holds the license key
  too: written mode 600 under `build/`, removed once applied.
- **On the box.** The bundle is written to a private temporary folder, sent through ssh and deleted.
  The Secrets are applied server-side (a client-side apply would copy them into an annotation), their
  file deleted, and k3s encrypts Secrets in its datastore. No credential is in any Helm value
  (`make values` shows them). The first ssh to a new box learns its host key and refuses a changed one.
  `make export` writes the Secrets to `secrets.yaml` (mode 600) for the cluster's operator to apply
  and delete.
- **Root.** It installs, upgrades and removes k3s, and nothing else; `make up` and `make down` ask for
  sudo once each. The install gives the ssh user its own kubeconfig, so everything
  else runs without root.
- **What is Lite's.** k3s is marked (`/etc/rancher/k3s/installed-by-langsmith-lite`): the checks refuse
  a k3s server someone else installed, and `make down` removes only a marked one.

## Many installs

Lite is built to be one of many, one install a customer, driven by a system above it that is not built
here. What that system needs, Lite gives:

- **One install is one root and one tfvars.** Everything an install is follows from its variables;
  nothing is asked interactively when `YES=1` is set (`YES=1 make up`), and each install's state is its
  own (`infra/backend.tf`, one backend a name).
- **Every object carries the install's name** (`langsmith-lite/instance=<name>`): namespaces, Secrets,
  HelmCharts, the stores' pods, the node; Prometheus labels every series with it.
- **Every output is data, keyed the same for every install:** `instance`, `plan` (sizes, disks, cost,
  retention, versions), `values`, `namespaces`, `box`; `make values` prints the releases as JSON.
- **Two shapes from one sizing.** A box per install (k3s, `cloud = baremetal` or `aws`), or many installs
  on one Kubernetes cluster (`cloud = cluster`, one `namespace` each, the cluster's storage classes):
  the same releases and values, written by `make export` for Helm or Argo CD.
- **Watched from one place.** `xs`, and every install on a cluster, runs no observability stack or
  Mission Control of its own: their roles are cluster-wide, and a fleet watches its installs from one
  stack, by the instance label.

## Beside the other modules

The cloud modules build a production platform from managed services; the bare-metal module runs
LangSmith on a cluster you have; Lite puts LangSmith's tracing on one machine.

| | Cloud modules (AWS, GCP, Azure) | Bare-metal module | Lite |
|:--|:--|:--|:--|
| Kubernetes | EKS, GKE, AKS, made by the module | an existing cluster | k3s, installed by Lite |
| Nodes | node groups that scale; Karpenter pools for SmithDB on AWS | the cluster's | one: the machine |
| Postgres | RDS, Cloud SQL, Azure Database | two in-cluster (LangSmith's, the metastore) | one in-cluster, both databases |
| Redis | ElastiCache, Memorystore, Azure Managed Redis | in-cluster | in-cluster, limit from the rate |
| Object storage | S3, GCS, Azure Blob | in-cluster RustFS | in-cluster RustFS, volume from the traffic kept |
| Trace store | ClickHouse during the move to SmithDB; SmithDB as separate pods | SmithDB's separate pods | SmithDB as one pod, no ClickHouse |
| Chart line | `~0.17.0` | `~0.17.0` | `~0.18.0` |
| Products | tracing plus what each enables | the same, by input | tracing only |
| Ingress | ALB with ACM (AWS); Envoy Gateway (GCP) | Envoy Gateway, MetalLB | Traefik: ssh, self-signed, Let's Encrypt or a tunnel |
| Secrets | SSM with External Secrets, Secret Manager, Key Vault | Kubernetes Secrets from Terraform | the same, encrypted in k3s's datastore |
| Install | `make apply`, then `make deploy` (Helm from the laptop) | the same | `make up`; the box installs itself |
| Observability, Mission Control | not installed | not installed | installed |

Every cloud module's `production` sizing runs autoscalers that Lite replaces with one pod sized for a
named load:

| Pod | `production` | Lite |
|:--|:--|:--|
| platform-backend, frontend | HPA, 2 to 10 | one, sized for the rate or the readers |
| backend | HPA, 3 to 10 | one, sized for the readers |
| ingest-queue, queue | KEDA, 3 to 10 | one, sized for the rate |
| playground, ace-backend | HPA, 1 to 5 | none, unless turned on |
| SmithDB | query, ingestion and compaction pods at a chart tier, each with an HPA | one pod, below the chart's smallest tier |

There is no second node to scale onto, and an autoscaler on one box only takes memory from the stores.

What Lite gives up: availability (one machine is one failure domain), the managed stores' backups and
point-in-time recovery, elasticity (a spike past the design rate waits in Redis), and every product
beyond tracing. A design rate past the box's measured range, a retention the disk cannot hold, a need
for availability, or any product beyond tracing is a cloud module's job, or the bare-metal module's
on a cluster. A Lite box's data does not move to them in place: that is a new install, with an export
of what must be kept.
