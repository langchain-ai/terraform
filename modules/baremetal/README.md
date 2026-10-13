# LangSmith on bare-metal Kubernetes (preview)

> **Preview. Not officially supported by LangChain.** This module is an **example deployment**: one complete, working
> way to run self-hosted LangSmith with **SmithDB** (no ClickHouse) on a plain, self-managed Kubernetes cluster, with no
> cloud provider. It was built and load-tested on a small multi-node cluster. Use it as a starting point and a reference
> for your own deployment, not as a turnkey product: the sizes, IP addresses and settings in it are examples to adapt.

This module deploys everything LangSmith needs that a cloud would otherwise provide (load balancer, ingress, storage
classes, Postgres, Redis, S3-compatible object storage), then installs LangSmith and SmithDB with Helm.

## Using this as an example

Every layer is a separate, replaceable piece. Run it as is to get a working LangSmith on a test or small cluster, or keep
the parts that fit your environment and swap the rest:

| Layer in this example | Keep it when | Replace it with, for example |
|---|---|---|
| MetalLB (L2) | the nodes share one LAN and you have spare IPs | your existing load balancer (BGP, F5, kube-vip, a cloud LB) |
| Envoy Gateway | you have no ingress yet | your ingress controller or Gateway; set the chart's `ingress` or `gateway` values |
| local-path storage | evaluation and small installs | your storage system's StorageClass (Ceph, Longhorn, a SAN CSI driver) |
| In-cluster Postgres ×2 and Redis | evaluation and small production | managed or HA services, wired through the chart's `postgres.external` and `redis.external` |
| RustFS | you have no object storage yet | any S3-compatible store (MinIO, Ceph RGW, an enterprise object store, AWS S3) |
| Cloudflare Tunnel | you want public HTTPS without inbound ports | TLS on your own load balancer or ingress |
| Sizing profiles and the budget gate | always: they size the LangSmith and SmithDB pods for your nodes | — |

What carries over to any Kubernetes deployment regardless of these choices: the Helm values layering, the SmithDB sizing
and recommended settings ([SMITHDB.md](SMITHDB.md)), the sizing formulas ([SIZING.md](SIZING.md)), and the operational
checks in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Architecture

```mermaid
flowchart TB
  user["Users, SDKs and API clients"]
  cf["Cloudflare Tunnel (optional)<br/>public HTTPS, no inbound ports"]

  subgraph cluster["Kubernetes cluster (bare metal)"]
    direction TB
    subgraph edge["Edge: Terraform"]
      mlb["MetalLB (L2)<br/>LoadBalancer IP"]
      envoy["Envoy Gateway<br/>Gateway + HTTPRoute"]
    end

    subgraph app["Namespace langsmith: Helm"]
      fe["frontend"]
      pb["platform-backend<br/>ingest API, run queries"]
      be["backend<br/>UI and API"]
      iq["ingest-queue<br/>workers"]
      q["queue"]
      subgraph smithdb["SmithDB"]
        cm["cluster-manager"]
        ing["ingestion"]
        qry["query"]
        cmp["compaction + workers"]
      end
    end

    subgraph data["Datastores: Terraform, one namespace each"]
      pgl[("Postgres 18<br/>LangSmith")]
      pgs[("Postgres 18<br/>SmithDB metastore")]
      rds[("Redis 7<br/>run buffer + queues")]
      s3[("RustFS (S3 API)<br/>SmithDB files + payload blobs")]
    end

    subgraph platform["Cluster add-ons: Terraform"]
      ms["metrics-server"]
      lp["local-path StorageClasses"]
    end
  end

  user --> mlb
  user -.-> cf -.-> envoy
  mlb --> envoy --> fe
  fe --> pb & be
  pb --> rds
  iq --> rds
  iq --> ing
  pb --> qry
  be --> pgl
  ing --> s3
  ing --> pgs
  qry --> s3
  qry --> pgs
  cmp --> s3
  cmp --> pgs
  pb --> s3
```

How a trace moves through it, every component, and why each piece is there: [ARCHITECTURE.md](ARCHITECTURE.md).
SmithDB specifics and tuning: [SMITHDB.md](SMITHDB.md). Sizing formulas: [SIZING.md](SIZING.md).

## What you get

| Layer | Component | Managed by |
|---|---|---|
| Cluster add-ons | metrics-server (for HPAs), local-path StorageClasses (`local-path`, `local-path-retain`) | Terraform |
| Load balancing | MetalLB in L2 mode, one IP pool | Terraform |
| Ingress | Envoy Gateway (Gateway API): one Gateway, route timeout policy, optional LAN catch-all route | Terraform |
| Public access (optional) | Cloudflare Tunnel connector (`cloudflared`, 2 replicas) | Terraform |
| Datastores | Postgres 18 ×2 (LangSmith, SmithDB metastore), Redis 7, RustFS (S3 API) with buckets | Terraform |
| Secrets | Datastore credentials as Kubernetes Secrets; app secrets in a local `infra/.secrets.env` (mode 600) | Terraform + scripts |
| Application | LangSmith chart 0.17.x with SmithDB (ClickHouse disabled) | Helm (`deploy.sh`) |
| Guardrails | Budget gate: requested CPU/memory checked against your nodes before anything is applied | Terraform |

## Assumptions

This module is opinionated. It assumes:

- **A working Kubernetes cluster** (1.30 or newer) you can reach with `kubectl`, with at least three schedulable worker
  nodes. It doesn't create the cluster. kubeadm, k3s, RKE2, Talos or similar all work, with containerd as the runtime.
- **One Layer 2 network** for the nodes, with a small range of unused IP addresses outside your DHCP pool for MetalLB.
- **Node-local storage.** local-path volumes are directories on one node's disk: fast (NVMe recommended), but each volume
  is pinned to its node and has **no replication**. Back up Postgres and the object store yourself.
- **Single-instance datastores.** Postgres, Redis and RustFS each run as one pod. That fits evaluation, development and
  small production. For high availability, run managed or HA services and point the chart at them instead.
- **Containers can open enough files:** containerd `LimitNOFILE=1048576` on every node (the default soft limit of 1,024
  silently breaks the SmithDB disk cache).
- **No ClickHouse.** SmithDB is the only trace store.

Not covered: building the cluster or its OS, TLS on the gateway itself (terminate TLS in front of it, e.g. with the
Cloudflare Tunnel), backups, multi-cluster or HA setups.

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | ≥ 1.11 |
| kubectl | matching your cluster |
| Helm | ≥ 3.12 (Helm 4 works) |
| python3 | any 3.x (scripts use the standard library only) |

A LangSmith Enterprise license key, and cluster-admin access to the target cluster (the module installs cluster-wide
add-ons: MetalLB, Envoy Gateway, metrics-server, local-path).

## Quick start

From `modules/baremetal/`:

```bash
# 1. Describe your cluster
cp infra/terraform.tfvars.example infra/terraform.tfvars
$EDITOR infra/terraform.tfvars        # kube context, nodes, IP range, sizing profile

# 2. Cluster add-ons and datastores
make init
make plan                             # read the budget output: requests vs your nodes
make apply

# 3. App secrets (license key, admin login, generated keys) → infra/.secrets.env
make setup-env

# 4. Helm values from Terraform outputs → helm/values/
make init-values

# 5. Install LangSmith + SmithDB
make deploy
```

`make deploy` prints the URL when every component is ready. Log in with `INITIAL_ORG_ADMIN_EMAIL` and the password from
`infra/.secrets.env`.

The first `make apply` installs the MetalLB and Envoy Gateway CRDs. If your Terraform version can't plan resources that
depend on CRDs that don't exist yet, apply the add-ons first:
`make apply ARGS="-target=module.metallb -target=module.envoy_gateway"`, then `make apply`.

## Sizing profiles

`sizing_profile` selects both the app sizing and the SmithDB tier. Before anything is applied, the budget gate sums
every pod's requests and rejects a profile that doesn't fit your `cluster_nodes`.

| Profile | App sizing | SmithDB tier | Use for |
|---|---|---|---|
| `minimum` | smallest replicas and requests | minimal | trying it out |
| `lab` | dev | minimal | a small cluster (~18 vCPU, ~48 GiB of workers) with real load |
| `dev` | dev | small (chart tier) | shared dev or staging |
| `production` | production | medium (chart tier) | production |
| `production-large` | production-large | medium (chart tier) | high-volume production |

How to size for a specific workload (traces/s, payload size, users): [SIZING.md](SIZING.md).

## Configuration

All settings are in `infra/terraform.tfvars`; [terraform.tfvars.example](infra/terraform.tfvars.example) lists every one.

| Variable | Required | Purpose |
|---|---|---|
| `kubeconfig_path`, `kube_context` | yes | the cluster; the context is required so the module never acts on your current context |
| `cluster_nodes` | yes | node names, allocatable CPU/memory/disk and roles, for the budget gate and optional SmithDB node pools |
| `metallb_addresses`, `envoy_gateway_lb_ip` | yes | LoadBalancer IP range and the gateway's IP in it |
| `sizing_profile` | no (`minimum`) | see above |
| `langsmith_domain`, `langsmith_url_scheme` | no | hostname and scheme (default `http://<gateway IP>`) |
| `envoy_gateway_route_timeout` | no (`60s`) | request timeout on every route; Envoy's own default of 15 s cuts off slow trace reads |
| `enable_deployments`, `enable_fleet`, `enable_standalone_insights`, `enable_standalone_polly`, `enable_sandboxes`, `enable_sso_oidc`, `enable_usage_telemetry` | no | features, same flags as the cloud modules |
| `enable_cloudflare_tunnel` + `TF_VAR_cloudflare_tunnel_token` | no | public HTTPS through a Cloudflare Tunnel |
| `node_reserved`, `max_request_ratio` | no | budget gate headroom |
| `*_image`, `*_chart_version` | no | pinned versions |

### Helm values layering

`make deploy` passes these files to Helm in order (last wins):

| File | Source |
|---|---|
| `helm/values/values.yaml` | committed base: external Postgres/Redis, ClickHouse off, gateway on |
| `langsmith-values-overrides.yaml` | Terraform output: hostname, gateway |
| `langsmith-values-admin.yaml` | initial admin email |
| `langsmith-values-sizing-<profile>.yaml` | copied once from `helm/values/examples/` |
| `langsmith-values-<feature>.yaml` | one per enabled feature |
| `langsmith-values-smithdb.yaml` | Terraform output: SmithDB sizing, cache, object store and metastore wiring |
| `langsmith-values-local.yaml` | **optional**, yours: your tuning; start from [langsmith-values-local.yaml.example](helm/values/langsmith-values-local.yaml.example) |

Generated files are gitignored. Secrets never go into values files: `deploy.sh` builds the `langsmith-config` Secret from
`infra/.secrets.env` and passes it to `kubectl` on stdin.

## Tuning for your workload

The defaults fit a small cluster. Everything that sizes LangSmith for a real workload is a setting you own, in one of
two places, and a redeploy applies it:

| What to tune | Where | Guide |
|---|---|---|
| Overall size: replicas and requests of every service, SmithDB tier | `sizing_profile` in `infra/terraform.tfvars` | [Sizing profiles](#sizing-profiles) |
| Nodes, headroom kept free for the OS, share of capacity pods may request | `cluster_nodes`, `node_reserved`, `max_request_ratio` | [ARCHITECTURE.md](ARCHITECTURE.md#the-budget-gate) |
| Large payloads out of Redis, and the size threshold | `enable_blob_storage`, `blob_storage_min_size_kb` | [SIZING.md](SIZING.md#redis) |
| How long runs stay in Redis (Redis memory) | `config.settings.redisRunsExpirySeconds` in `langsmith-values-local.yaml` | [SIZING.md](SIZING.md#redis) |
| Ingest throughput (workers per pod, pods) | `ingestQueue` in `langsmith-values-local.yaml` | [SIZING.md](SIZING.md#ingest-workers-ingest-queue) |
| Read capacity | `smithdb.query` replicas in `langsmith-values-local.yaml` | [SIZING.md](SIZING.md#reads-smithdb-query) |
| SmithDB memory, cache and scratch volumes, replicas | `smithdb.<component>.deployment` in `langsmith-values-local.yaml` | [SMITHDB.md](SMITHDB.md), [SIZING.md](SIZING.md#smithdb-memory) |
| Any other chart value | `langsmith-values-local.yaml` (applied last, overrides everything generated) | the LangSmith Helm chart's `values.yaml` |
| Request timeout at the gateway | `envoy_gateway_route_timeout` | [TROUBLESHOOTING.md](TROUBLESHOOTING.md#networking-and-ingress) |

Start from the recommended settings in the example values file. Each one carries its reason and the assumption behind
its value:

```bash
cp helm/values/langsmith-values-local.yaml.example helm/values/langsmith-values-local.yaml
$EDITOR helm/values/langsmith-values-local.yaml     # size the values for your load with SIZING.md
make deploy                                          # Terraform settings: make plan && make apply first
```

To tune with confidence, measure: send traces shaped like your production ones (runs per trace, payload sizes) at your
expected rate, and watch Redis memory, the ingest queue backlog, and pod CPU and memory (`kubectl top`). The formulas in
[SIZING.md](SIZING.md) tell you which setting moves which number.

## Verify

```bash
kubectl --context <ctx> -n langsmith get pods           # all Running / Completed
kubectl --context <ctx> top pods -n langsmith            # metrics-server works
curl -s -o /dev/null -w '%{http_code}\n' http://<gateway IP>/api/v1/info   # 200
```

Then send a test trace with the LangSmith SDK (`LANGSMITH_ENDPOINT=http://<gateway IP>/api/v1`) and open it in the UI.

## Repository layout

```
modules/baremetal/
├── Makefile                       # make help
├── README.md, ARCHITECTURE.md, SMITHDB.md, SIZING.md, TROUBLESHOOTING.md, TEARDOWN.md
├── infra/                         # Terraform root
│   ├── main.tf, locals.tf, variables.tf, outputs.tf, helm_values.tf, budget.tf, smithdb_nodes.tf
│   ├── terraform.tfvars.example
│   ├── modules/                   # metrics-server, local-path, metallb, envoy-gateway, cloudflared,
│   │                              # postgres, redis, rustfs
│   ├── scripts/                   # setup-env.sh, _common.sh
│   └── tests/                     # plan tests (mocked providers): bash agents/plan-tests.sh modules/baremetal
└── helm/
    ├── scripts/                   # init-values.sh, deploy.sh
    └── values/                    # values.yaml, examples/, langsmith-values-local.yaml.example
```

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): components, namespaces, request and write paths, storage
- [SMITHDB.md](SMITHDB.md): SmithDB on bare metal, recommended settings, known issues
- [SIZING.md](SIZING.md): assumptions and formulas for Redis, ingest workers, query and storage
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptoms, causes and fixes
- [TEARDOWN.md](TEARDOWN.md): removing LangSmith and the module, and what data survives
