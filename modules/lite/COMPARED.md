# Lite beside the other modules

> **Status:** current · **Last verified:** 2026-11-24 (against `modules/aws`, `gcp`, `azure` and `baremetal` on `main`)

What Lite keeps, trims, replaces and drops, against the cloud modules (AWS, GCP, Azure) and the
bare-metal module. The cloud modules build a production platform from managed services; Lite puts
LangSmith's tracing on one machine. Where a row differs, the last column says why.

## What runs where

| | Cloud modules | Bare-metal module | Lite | Why Lite differs |
|:--|:--|:--|:--|:--|
| Kubernetes | A managed cluster the module makes: EKS, GKE, AKS | An existing cluster (kubeadm, k3s) | k3s on one machine, installed by Lite | One machine needs no cluster to operate |
| Nodes | Node groups that scale (GKE 2 to 10 a zone; Karpenter node pools for SmithDB on AWS) | The cluster's nodes, optionally pinned for SmithDB | One node, the machine | The box is the unit |
| Postgres | Managed: RDS, Cloud SQL, Azure Database | Two in-cluster Postgres (LangSmith's, SmithDB's metastore) | One in-cluster Postgres holding both databases | A second Postgres on one box is memory for nothing |
| Redis | Managed: ElastiCache, Memorystore, Azure Managed Redis | In-cluster | In-cluster, its limit derived from the rate | Same as bare metal |
| Object storage | S3, GCS, Azure Blob | In-cluster RustFS | In-cluster RustFS, its volume derived from the traffic kept | Same as bare metal |
| Trace store | ClickHouse in-cluster during the move to SmithDB, SmithDB as separate query, ingestion and compaction pods | SmithDB's separate pods; ClickHouse for a migration | SmithDB as one unified pod; no ClickHouse | Chart 0.18's single-pod SmithDB, and nothing to migrate from |
| Chart line | `~0.17.0` | `~0.17.0` | `~0.18.0` | Lite is chart 0.18 only |
| Products | Tracing plus what each enables (Deployments, Fleet, Insights, Polly, Sandboxes) | The same, by input | Tracing only | The box's memory goes to the stores |
| Ingress, TLS | ALB with ACM (AWS); Envoy Gateway with managed certs (GCP); the cloud's DNS | Envoy Gateway and MetalLB | k3s's Traefik: localhost through ssh, a self-signed certificate, Let's Encrypt, or a Cloudflare Tunnel | One machine, any network |
| Secrets | SSM with External Secrets (AWS), Secret Manager (GCP), Key Vault (Azure) | Kubernetes Secrets from Terraform | Kubernetes Secrets from Terraform, encrypted in k3s's datastore | No cloud secret store on a bare machine |
| Install | Two passes: `make apply` (infrastructure), then `make deploy` (Helm from the laptop) | The same two passes | One: `make up`; the box installs itself with k3s's helm-controller | Nothing on the laptop talks to the box's API |
| Observability | Not installed | Not installed | Prometheus, Grafana with the chart's dashboard, node, Redis and Postgres dashboards | One box must be watchable on its own |
| Mission Control | Not installed (AWS can certify a subdomain for it) | Not installed | Installed, read-only but for diagnostics | Health and support on a box with no other tooling |

## What is trimmed

| Pod | Cloud modules, `production` sizing | Lite |
|:--|:--|:--|
| platform-backend | HPA, 2 to 10 replicas | one replica, sized for the design rate |
| backend | HPA, 3 to 10 | one, sized for the readers |
| ingest-queue | KEDA, 3 to 10 | one, sized for the design rate |
| queue | KEDA, 3 to 10 | one, sized for the design rate |
| frontend | HPA, 2 to 10 | one, sized for the readers |
| playground | HPA, 1 to 5 | not running (`playground = true` runs one) |
| ace-backend | HPA, 1 to 5 | not running (`code_evaluators = true` runs one) |
| SmithDB | query, ingestion, compaction (and workers), each with an HPA, at a chart tier (small, medium, large) | one unified pod, sized per box below the chart's smallest tier |

No autoscalers run on Lite: there is no second node to scale onto, and an HPA scaling out on one box
only takes memory from the stores. KEDA and metrics-server autoscaling are replaced by sizing each pod
for a named load up front, and `make plan` refuses a box that cannot hold it.

## How each is sized

| | Cloud modules | Lite |
|:--|:--|:--|
| Method | A profile (`minimum`, `dev`, `production`, `production-large`): fixed requests and replica ranges per component | A measured per-pod model: idle cores plus cores per run/s, times 1.5 (SIZING.md) |
| Input | The profile's name | `runs_per_second`, `readers`, retention, payload mix |
| Storage | The cloud's object store grows on its own | The object store's volume derived from runs a day x bytes a run x days kept |
| Fit check | The bare-metal module's budget against the cluster's nodes | Requests against the machine, the volumes against its disk, a stalled ingest against its memory |
| Beyond the box | Add nodes, raise a profile | A bigger box, or a cloud module |

## What Lite gives up

- **Availability.** One machine is one failure domain: a disk or a kernel lost is LangSmith down until
  it is rebuilt. The cloud modules run managed, replicated stores across zones.
- **Backups.** The managed stores' backups and point-in-time recovery are gone; Lite's data is a disk
  to snapshot (OPERATE.md, Keeping its data).
- **Elasticity.** A spike past the design rate queues in Redis rather than scaling out; Redis's limit
  holds a stalled ingest for `redis_runs_expiry_hours`, after which runs expire.
- **The products beyond tracing.** Deployments, Fleet, Insights, Polly, Sandboxes, the playground and
  code evaluators; the last two are one variable each.

## When to move off Lite

A design rate past box `l` (80 runs/s), a retention the disk cannot hold, a need for availability or
managed backups, or any product beyond tracing: each is a cloud module's job, or the bare-metal
module's on a cluster. A Lite box's data does not move to them in place; plan the move as a new install
and an export of what must be kept.
