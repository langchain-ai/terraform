# Architecture

> **Status:** current · **Last verified:** 2026-11-24

How Lite goes from `make up` to a running box, how a trace moves through it, why each piece is the
one it is, and how it differs from the other modules.

## From make up to a running box

```
 laptop: bin/lite                                      box: box/install.sh, as root
 ----------------                                      ----------------------------
 make preflight   box/checks.sh  ---ssh--->            read-only, as the ssh user

 make up          ask what the tfvars lack   (lib/settings.py; NAME=value answers one)
                  resolve each chart line   (live Helm repos)
                  package the datastores chart
                  terraform plan: size every pod and volume,
                    check the fit, render the bundle
                  the plan's summary, then a question      (make plan stops here)
                  terraform apply           (aws: the instance, its data volume, its snapshots)
                  bundle + chart + box/  ---ssh--->    1  checks.sh again
                                                       2  aws: the data volume, at k3s's storage folder
                                                       3  k3s at the pinned version
                                                       4  namespaces and their network policies, priority
                                                          class, storage class, Traefik, the operator's
                                                          ServiceAccount, Secrets
                                                       5  the ssh user's kubeconfig: the operator's, not admin
                                                       6  each HelmChart into k3s's manifests folder,
                                                          the stores first; wait for each install Job
                                                       7  remove what this bundle no longer has

 cloud = cluster  terraform apply           (credentials only: there is no machine)
 (make export)    releases, values, Secrets, the datastores chart  --> files for the cluster's operator
```

During an install nothing on the laptop talks to the box's Kubernetes API (later, `status`, `access`,
`verify` and `soak` reach it through ssh). Terraform has no Kubernetes or Helm
provider: it sizes the box, renders the bundle, generates the credentials and, with `cloud = aws`,
makes the instance. `infra/releases.tf` says what each release is (chart, namespace, values, order);
`infra/bundle.tf` how they reach a k3s box; `make export` writes the same releases for a cluster. The box installs itself with k3s's own controllers: k3s applies whatever is in
`/var/lib/rancher/k3s/server/manifests`, and its helm-controller installs each `HelmChart` there. The
plan therefore runs before any machine exists, a second `make up` changes only what differs, and the
box keeps running if the laptop goes away.

## How a trace moves

```
 SDK --HTTPS--> Traefik --> frontend (nginx) --/runs--> platform-backend --> Redis (queue + payload)
                                                              |                         |
                                       payloads >= 20 KiB     v                         v
                                                       RustFS: blobs              ingest-queue
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
memory (request equals limit), since they hold the runs waiting to be ingested and every install's
metadata, and a node short of memory reclaims first from pods using more than they asked; the stores
(Postgres, Redis, RustFS and SmithDB) also run at a priority above the app's, so under memory pressure an
app pod, which restarts with no loss, is evicted before a store.

## What runs, and why each piece

| Piece | Why this one |
|:--|:--|
| k3s | One binary with an ingress (Traefik), a load balancer (servicelb), storage (local-path), metrics-server, and a controller that installs Helm charts from files. On one machine, these replace the MetalLB, Envoy Gateway, local-path and metrics-server the bare-metal module installs |
| LangSmith chart, tracing only | The supported chart at 0.18, with SmithDB as one unified pod and every other product off; playground never runs, and ace-backend only with `code_evaluators` |
| The bare-metal module's `charts/datastores` | Postgres, Redis and RustFS as StatefulSets on their official images, already proven under load with that module: NetworkPolicies, PodDisruptionBudgets, Redis at `noeviction`, Postgres's buffers from its limit, the buckets and their expiry rules made by Jobs. Shared, not copied |
| One Postgres | LangSmith's database and SmithDB's metastore as two databases on one instance |
| RustFS | S3 on the box's disk: SmithDB's segments and the payload blobs (blob storage is required from chart 0.18) |
| Prometheus, Grafana | The chart's own scrape annotations and dashboard, the kubelet's per-container use, node, Redis and Postgres dashboards |
| Mission Control | The chart's operator UI: health and diagnostics, strictly read-only (no write verb in its RBAC) |

| Namespace (`<ns>` is `namespace`, by default the install's `name`) | Holds | Admits traffic from |
|:--|:--|:--|
| `<ns>` | LangSmith's pods, SmithDB, Mission Control | itself, `<ns>-observe`, `<ns>-tunnel`, the ingress controller's (`ingress_namespaces`) |
| `<ns>-data` | Postgres, Redis, RustFS | `<ns>` and `<ns>-observe` (the datastores chart's policies) |
| `<ns>-observe` | Prometheus, Grafana, kube-state-metrics, node-exporter, the Redis and Postgres exporters | itself |
| `<ns>-tunnel` | cloudflared, with `access = tunnel`. It takes requests from the internet, so it runs in a namespace of its own, which the stores do not admit | nothing |
| `kube-system` | k3s's own, each release's `HelmChart`, the operator's ServiceAccount | |

The stores' volumes use `local-path-retain` (`storage_class`), so a deleted claim never deletes data;
SmithDB's cache and Prometheus use k3s's `local-path` (`scratch_storage_class`), since both rebuild.
Every volume is a folder on one data disk, with no cloud disk per volume and no CSI driver (OPERATE.md,
The machine, says which disk). The plan keeps every disk at most 80% full once the stores hold their
retention: on a one-disk box that disk also holds the images, and k3s's kubelet evicts pods under 15% free.

## What Lite decides, and what it reads

A fact the platform owns is read from it, so a new chart release brings its own; Lite writes down only
what it decides.

| Read at the installed release, never copied | Decided here, as data |
|:--|:--|
| Each chart's exact version, resolved from its pinned line (`infra/pins.yaml`) before every plan; a plan without it is refused | The chart lines, and k3s's exact version |
| Mission Control's image tag: the chart's `appVersion` | Which products run: tracing only (`infra/values.tf`) |
| LangSmith's metrics ports: the chart's `prometheus-values.yaml`, applied as a second values layer | Every pod's and volume's size (`infra/sizes.yaml`, SIZING.md) |
| The official dashboard, from the chart's repo at the release tag | The stores' layout: one Postgres, one Redis, one RustFS |
| k3s's installer, from its release's own tag | Retention, payload and access settings (`infra/variables.tf`) |

What stays a contract with the chart: the names of the values Lite sets, and the Secret keys it reads.
`make render` renders every release at the resolved versions with the plan's values, so a chart that
renamed a value fails there, before it reaches a box.

## Security

| Concern | What Lite does |
|:--|:--|
| Credentials | Terraform generates every one (`infra/secrets.tf`) and keeps it in its state, local and gitignored; the license key and a tunnel token are typed once into `infra/.secrets.env` (mode 600) and reach Terraform as environment variables, never as arguments. The plan file holds them too: mode 600, removed once applied or declined. No credential is in any Helm value (`make values` shows them) or any log. |
| On the box | The bundle travels inside ssh and is deleted after the install; Secrets are applied server-side (a client-side apply copies them into an annotation), their file deleted, and k3s encrypts Secrets at rest. `make export` writes `secrets.yaml` mode 600, to apply server-side and delete. |
| ssh | An AWS instance's host key is generated by Terraform, given to it at boot and checked strictly; a machine of your own is trusted on first use (its key is yours to know) and refused if its key changes. `admin_cidrs` refuses the whole internet. |
| Root | sudo runs the install and the removal, and nothing after: k3s and its config, the data disk's mount (formatting a blank AWS volume, its fstab line, the rule that k3s waits for it), k3s's manifests; `make down` removes them and the volume folders. Asked once a command. |
| The cluster | The ssh user's kubeconfig is the operator ServiceAccount's: read the install, its logs, tunnels and exec in its own namespaces, a tunnel to Traefik; not cluster-admin and not `nodes/proxy` (whose GET opens a kubelet exec). k3s's admin kubeconfig stays root-only. |
| The network | Every namespace refuses traffic but from where it is needed (the table above); Grafana, Prometheus, Mission Control and the stores have no port on the box; Prometheus runs without its unauthenticated lifecycle API. |
| Logins | LangSmith's first admin, Grafana's admin and Mission Control's are generated passwords; Grafana has no anonymous access; Mission Control is strictly read-only. `make verify` and `make soak` make an API key for the run and revoke it, pass or fail. |
| Data at rest | k3s's Secrets encrypted; on AWS both volumes and their snapshots encrypted, instance metadata reachable only from the instance (IMDSv2, one hop). |
| What is Lite's | k3s is marked (`/etc/rancher/k3s/installed-by-langsmith-lite`): the checks refuse a k3s server someone else installed, `make down` removes only a marked one, and k3s will not start without the data disk mounted. |

Known limits, each a deliberate corner cut:

- Limit: charts are fetched by version and k3s's installer by release tag, not by digest; k3s's installer
  checks the binary's sha256. The upgrade path is digests in `pins.yaml`, checked at plan time.
- Limit: traffic inside the box is plaintext (Postgres `sslmode=disable`), the exporters hold the stores'
  own passwords, and one RustFS key serves both buckets; the network policies are what keep them in.
  The upgrade path is TLS between pods and read-only exporter roles.
- With `access = ip`, browsers meet a self-signed certificate; with `tunnel`, put Cloudflare Access in
  front of the hostname, since LangSmith's login is then on the internet.
- Not built yet, and where each would plug in without a change of shape (OPERATE.md, A real endpoint):
  SSO is one setting that adds the chart's OIDC values (`infra/values.tf`, beside `authType: mixed` and
  the hostname Lite already sets), its client secret in the Secret Lite already makes (`infra/secrets.tf`),
  and basic auth off; your own certificate is a TLS Secret and Traefik's default certificate
  (`traefik_values`); an internal CA for outbound calls is the chart's `config.customCa`.

## Many installs

Lite is built to be one of many, one install a customer, driven by a system above it that is not built
here. What that system needs, Lite gives:

- **One install is one folder.** Everything an install is follows from its tfvars, and its Terraform
  state is a local file beside them (`infra/backend.tf`), so a system driving many keeps one checkout
  (or one state backend) per install. Nothing is asked with `YES=1 make up`, and `make down` takes
  `CONFIRM=<name>` in place of the typed name.
- **Every object carries the install's name** (`langsmith-lite/instance=<name>`): namespaces, Secrets,
  HelmCharts, the stores' pods, the node; Prometheus labels every series with it.
- **Every output is data, keyed the same for every install:** `instance`, `plan` (sizes, disks, cost,
  retention, versions), `values`, `namespaces`, `box`; `make values` prints the releases as JSON.
- **Two shapes from one sizing.** A box per install (k3s, `cloud = baremetal` or `aws`), or many installs
  on one Kubernetes cluster (`cloud = cluster`, one namespace each, the cluster's storage classes):
  the same releases and values, written by `make export` for Helm or Argo CD.
- **Independent stores.** Each install has its own Postgres, Redis and RustFS, its own credentials and its
  own priority class, in namespaces named for it that refuse other installs' traffic (the cluster's CNI
  must enforce NetworkPolicies). Installs share a cluster's nodes and nothing else.
- **Watched from one place, later.** On a cluster an install runs no observability stack or Mission
  Control of its own, since their roles are cluster-wide. The health dashboard and its alerts are
  grouped by namespace, with an install picker, ready for one shared stack; that stack is not built
  here. It would run in a namespace of its own, named in every install's `ingress_namespaces` so their
  policies admit its scrapes.

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
| playground, ace-backend | HPA, 1 to 5 | playground none; ace-backend one with `code_evaluators` |
| SmithDB | query, ingestion and compaction pods at a chart tier, each with an HPA | one pod, below the chart's smallest tier |

There is no second node to scale onto, and an autoscaler on one box only takes memory from the stores.

What Lite gives up: availability (one machine is one failure domain), the managed stores' backups and
point-in-time recovery, elasticity (a spike past the design rate waits in Redis), and every product
beyond tracing. A design rate past the box's measured range, a retention the disk cannot hold, a need
for availability, or any product beyond tracing is a cloud module's job, or the bare-metal module's
on a cluster. A Lite box's data does not move to them in place: that is a new install, with an export
of what must be kept.
