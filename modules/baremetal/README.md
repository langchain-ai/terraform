# Reference example: LangSmith with SmithDB on self-managed Kubernetes

**Status: Example.** Tested on kubeadm and k3s. Not a supported deployment path.

## What this example is, and what it is not

- It **is** one tested way to run self-hosted LangSmith with SmithDB (and, for a migration, ClickHouse beside it) on an existing Kubernetes cluster,
  with no cloud provider. Terraform deploys what a cloud would otherwise provide, then Helm installs LangSmith.
- It is **not** an installer that LangChain supports, and it is **not** a production blueprint. The sizes, IP addresses
  and settings in it are examples to adapt.
- **Support boundary:** LangChain supports the LangSmith application under your agreement. You own every layer this
  example adds: load balancing, ingress, storage, Postgres, Redis, object storage, backups and upgrades.

## What LangSmith needs, and how this example meets it

| Need | This example | For production |
|---|---|---|
| LoadBalancer IPs | MetalLB (L2): one dedicated IP for the gateway, a pool for other Services | your existing load balancer (BGP, F5, kube-vip) |
| Ingress | Envoy Gateway (Gateway API), 60 s route timeout | your ingress controller or Gateway, through the chart's `ingress` or `gateway` values |
| Volumes | local-path: node-local, no replication | a replicated StorageClass (Ceph, Longhorn, SAN CSI) |
| Postgres (LangSmith and SmithDB metastore) | one pod each | managed or HA Postgres with point-in-time recovery, through `postgres.external` and `smithdb.config.metastore` |
| Redis | one pod | managed or HA Redis or Valkey, through `redis.external` |
| S3-compatible storage | one RustFS pod (SmithDB data and payload blobs) | a replicated object store (Ceph RGW, an enterprise S3, AWS S3) |
| Pod metrics for autoscaling | metrics-server | your cluster's metrics-server |
| Autoscaling for agent deployments (only with LangSmith Deployments) | KEDA | your cluster's KEDA |
| TLS | none by default; an optional HTTPS listener (`gateway_tls_secret`) or Cloudflare Tunnel | TLS at your load balancer or Gateway |
| Backups | not covered | metastore and bucket backups taken at the same point in time |

What carries over to any Kubernetes deployment, whatever you swap: the Helm values layering, the SmithDB settings
([SMITHDB.md](SMITHDB.md)), the sizing method ([SIZING.md](SIZING.md)) and the checks in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Tested

| Distribution | Kubernetes | Runtime | CNI | Nodes | Chart | Tested |
|---|---|---|---|---|---|---|
| kubeadm on Ubuntu 22.04 | v1.36.5 | containerd 2.4.1 | Calico v3.33.0 | 4 (1 control plane, 3 workers) | langsmith 0.17.11 (app and SmithDB 0.17.38); earlier load tests on 0.17.6 | install, upgrade, deploy, load test, blob offload, an agent deployment |
| k3s | v1.34.5+k3s1 | containerd (k3s) | flannel (k3s) | 5 (1 amd64 server holding all state, 4 arm64 agents with 16K pages, so SmithDB is pinned to the server) | langsmith 0.17.20 | SmithDB-only install, load tests to saturation, an hour's soak with every trace stored, blob expiry applied |

[What you get](#what-you-get) says, layer by layer, what is proven on a cluster and what by the plan tests only.

Add-ons as tested: MetalLB 0.16.1, Envoy Gateway v1.9.2, metrics-server chart 3.14.0, KEDA 2.21.0.

**Other distributions need changes.** k3s ships servicelb, local-storage and metrics-server by default
([packaged components](https://docs.k3s.io/installation/packaged-components)), which collide with the MetalLB, local-path
and metrics-server this example installs: start k3s with `--disable servicelb --disable local-storage --disable
metrics-server --disable traefik` (Traefik would otherwise take a MetalLB address), or keep `--disable traefik` only and set `install_metallb`, `install_local_path` and `install_metrics_server` to `false` to use k3s's own (covered by plan tests, not yet run live). RKE2
ships its own metrics-server, so the same collision applies there: disable it, or set `install_metrics_server = false`.

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

One module installs every layer a cloud would provide, and each optional layer is one input. The last column says
how far each is proven: on a live cluster, or by the plan tests only.

| Layer | What, and the inputs that change it | Managed by | Proven |
|---|---|---|---|
| Cluster add-ons | metrics-server (for HPAs), local-path StorageClasses (`local-path`, `local-path-retain`); each skipped when the cluster has its own (`install_metrics_server`, `install_local_path` with `storage_class`) | Terraform | installed: live; skipped: plan tests |
| Load balancing | MetalLB in L2 mode: the gateway IP in its own pool (never auto-assigned), a pool for other Services; skipped for the cluster's own load balancer (`install_metallb`) | Terraform | installed: live; skipped: plan tests |
| Ingress | Envoy Gateway (Gateway API): one Gateway, a 60 s request timeout on the chart's route and the LAN route, none on Fleet, Deployments and agent run streams, an optional HTTPS listener (`gateway_tls_secret`); or the cluster's own Gateway (`install_envoy_gateway`, `existing_gateway`), whose listener must allow routes from the `langsmith` namespace and whose timeouts are its own | Terraform + `deploy.sh` | the Gateway: live; HTTPS, an existing Gateway: plan tests; stream routes: not yet run |
| Public access (optional) | Cloudflare Tunnel connector (`cloudflared`, 2 replicas) | Terraform | plan tests |
| Datastores | Postgres 18 ×2 (LangSmith, SmithDB metastore), Redis 7, RustFS (S3 API) with buckets, blob storage on by default with the cloud modules' expiry (`blob_storage_ttl_days`). In the cluster only: external Postgres, Redis or object storage are not inputs yet | Terraform | live |
| Trace store | SmithDB alone by default. For a migration from ClickHouse: the chart's ClickHouse in the cluster, dual ingest, the backfill and the read switch, one Helm change each (`clickhouse_source`, `enable_smithdb`, `smithdb_*_enabled`, [SMITHDB.md](SMITHDB.md)). SmithDB's tier from the load (`smithdb_tier`) | Terraform + Helm | SmithDB alone: live; ClickHouse and the migration steps: plan tests |
| Secrets | Datastore credentials as Kubernetes Secrets; app secrets in a local `infra/.secrets.env` (mode 600); the first admin's email in `terraform.tfvars` | Terraform + scripts | credentials and the secrets file: live; the email from `terraform.tfvars`: not yet run |
| Application | LangSmith chart on the 0.17 or 0.18 line (line-pinned) | Helm (`deploy.sh`) | 0.17: live; 0.18: not yet run (`deploy.sh` accepts the line) |
| Agent deployments (optional) | KEDA, plus the chart's host-backend, listener and operator (`enable_deployments`) | Terraform + Helm | live |
| Fleet, Insights, Polly, SSO (optional) | the cloud modules' flags (`enable_fleet`, `enable_standalone_insights`, `enable_standalone_polly`, `enable_sso_oidc`) | Terraform + Helm | Fleet, Insights, Polly: plan tests; SSO: not yet tested |
| Sandboxes and Engine (optional) | Sandboxes on KVM nodes, JuiceFS on its own Redis and bucket; Engine on them ([below](#sandboxes-and-engine-optional)) | Terraform + Helm | plan tests |
| Guardrails | Budget gate: requested CPU, memory and disk checked against your nodes before anything is applied; the `pods` output lists what it counted | Terraform | budget gate: live; `pods` output: plan tests |

## Assumptions

This module is opinionated. It assumes:

- **A working Kubernetes cluster** you can reach with `kubectl`, with at least three schedulable worker nodes. It doesn't
  create the cluster. Tested on kubeadm and k3s; other distributions need the changes under [Tested](#tested).
- **One Layer 2 network** for the nodes, with unused IP addresses outside your DHCP pool: one for the gateway, and a
  range for MetalLB that doesn't include it.
- **Node-local storage.** local-path volumes are directories on one node's disk: fast (NVMe recommended), but each volume
  is pinned to its node and has **no replication**. Back up Postgres and the object store yourself.
- **Single-instance datastores.** Postgres, Redis and RustFS each run as one pod. That fits evaluation, development and
  small production. For high availability, run managed or HA services and point the chart at them instead.
- **Containers can open enough files:** containerd `LimitNOFILE=1048576` on every node (the default soft limit of 1,024
  silently breaks the SmithDB disk cache).
- **SmithDB is the trace store.** By default it is the only one; `clickhouse_source = "in-cluster"` adds the chart's
  ClickHouse for dual ingest and a backfill ([SMITHDB.md](SMITHDB.md)).

Not covered: building the cluster or its OS, issuing the certificate (TLS ends at the gateway from a Secret you
provide, `gateway_tls_secret`, or in front of it, e.g. with the Cloudflare Tunnel), backups, multi-cluster or HA setups.

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

# 3. App secrets (license key, admin login, generated keys) → infra/.secrets.env (the admin email from tfvars when set)
make setup-env

# 4. Helm values from Terraform outputs → helm/values/
make init-values

# 5. Install LangSmith + SmithDB
make deploy
```

`make deploy` prints the URL when every component is ready. Log in with `INITIAL_ORG_ADMIN_EMAIL` and the password from
`infra/.secrets.env`. `make setup-env` also makes the signing JWKS (`langsmith_signing_jwks`), which turns on OAuth login
(`langsmith auth login`), Remote MCP, the LLM auth proxy and sandbox service URLs; keep it with the secrets file, since
the docs require it stable across upgrades.

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
| `envoy_gateway_lb_ip`, `metallb_addresses` | with `install_metallb` | the gateway's IP (its own pool, needed when the module also installs Envoy Gateway), and a separate range for other LoadBalancer Services. Without both add-ons ours, `langsmith_domain` is required instead |
| `sizing_profile` | no (`minimum`) | see above |
| `langsmith_domain`, `langsmith_url_scheme` | without both add-ons ours | hostname and scheme (default `http://<gateway IP>`) |
| `langsmith_admin_email` | no | the first org admin's email, written to `initialOrgAdminEmail` as on the cloud modules; empty: `make setup-env` asks |
| `gateway_tls_secret` | no | a `kubernetes.io/tls` Secret in the `langsmith` namespace: adds an HTTPS listener for `langsmith_domain` beside HTTP (needs `langsmith_url_scheme = "https"`) |
| `clickhouse_source`, `enable_smithdb`, `smithdb_ingestion_enabled`, `smithdb_migration_enabled`, `smithdb_query_enabled`, `smithdb_migration_parallelism` | no (SmithDB only) | the trace store, as the cloud modules name these inputs: ClickHouse in the cluster, dual ingest, the backfill and the read switch, one Helm change each ([SMITHDB.md](SMITHDB.md)) |
| `smithdb_tier` | no (the profile's) | SmithDB's tier (`minimal`, `small`, `medium`) when the load, not the profile, should set it: the medium tier asks 28 cores a query pod at any load |
| `install_metrics_server`, `install_local_path` (+ `storage_class`), `install_metallb`, `install_envoy_gateway` (+ `existing_gateway`) | no (all `true`) | skip each add-on a cluster already has; the budget counts only what is installed |
| `enable_sandboxes`, `sandbox_hosts`, `sandbox_source_cidrs`, `sandbox_juicefs_cache_gi` | no | Sandboxes on KVM nodes ([below](#sandboxes-and-engine-optional)) |
| `enable_engine`, `engine_sandbox_tenant_id`, `engine_intelligence_base_url` | no | Engine, on Sandboxes ([below](#sandboxes-and-engine-optional)) |
| `blob_storage_ttl_days` | no (`{short = 14, long = 400}`) | days before the blob bucket deletes `ttl_s/` and `ttl_l/` payloads, as the cloud modules expire them |
| `envoy_gateway_route_timeout` | no (`60s`) | with this module's Envoy Gateway, the request timeout on the chart's route and the LAN route; Envoy's own default of 15 s cuts off slow trace reads. Fleet and Deployments streams have none: with either on, `deploy.sh` applies the `langsmith-fleet-streams` route, and the operator writes `0s` on its agent routes (`HTTPROUTE_REQUEST_TIMEOUT` in the agent-deploys example values) |
| `enable_deployments` (installs KEDA), `enable_fleet`, `enable_standalone_insights`, `enable_standalone_polly`, `enable_sso_oidc`, `enable_usage_telemetry` | no | features, same flags as the cloud modules; with SSO, `make setup-env` asks the OIDC client ID, secret and issuer, and `deploy.sh` turns basic auth off |
| `enable_cloudflare_tunnel` + `TF_VAR_cloudflare_tunnel_token` | no | public HTTPS through a Cloudflare Tunnel |
| `node_reserved`, `max_request_ratio` | no | budget gate headroom |
| `*_image`, `*_chart_version` | no | pinned versions |

### Helm values layering

`make deploy` passes these files to Helm in order (last wins):

| File | Source |
|---|---|
| `helm/values/values.yaml` | committed base: external Postgres/Redis, ClickHouse off (the trace-store inputs turn it on), gateway on |
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

## LangSmith Deployments (optional)

With `enable_deployments = true` (and the Deployments entitlement in your license), `make apply` installs KEDA and
`make deploy` turns on host-backend, listener and operator. Agent deployments then run in the `langsmith` namespace:

- **Image:** build your agent with `langgraph build` (we recommend the Wolfi base: `"image_distro": "wolfi"` in
  `langgraph.json`) and push it to a registry your nodes can pull from. Create the deployment from that image in the UI
  or with the `/api-host/v2/deployments` API (`source: "external_docker"`).
- **Routing:** the operator adds an HTTPRoute per deployment on the module's Gateway, at
  `<LangSmith URL>/lgp/<deployment>`, and KEDA ScaledObjects for the agent and its queue worker.
- **Resources:** with the operator's defaults, each deployment requests about **3.2 CPU and 8.25 GiB**: the agent
  (200m/512Mi), a queue worker (1 CPU/2 GiB), Redis (1 CPU/2 GiB) and a Postgres StatefulSet (1 CPU/3.75 GiB, named
  `lg-<id>`) with a 20 GiB volume on the default StorageClass. `expected_agent_deployments` reserves that much each in
  the budget gate.

## Sandboxes and Engine (optional)

`enable_sandboxes = true` runs Sandboxes on the nodes named in `sandbox_hosts`: amd64 machines with `/dev/kvm`, TUN
and FUSE, each from `cluster_nodes`. The module labels and taints them `sandbox.langsmith.com/host=true:NoSchedule`, so
only the sandbox runtime lands there (the budget counts them as a pool of their own, never as worker capacity), and gives JuiceFS a Redis of its own (AOF, `noeviction`) and a `sandbox-juicefs`
bucket on the same RustFS. The runtime uses the host network, which no NetworkPolicy namespace selector matches, so
`sandbox_source_cidrs` names the addresses its traffic comes from (each sandbox node's own, and the pod CIDR). With
Sandboxes on, the `langsmith` namespace runs at the privileged Pod Security level, and `make setup-env` makes the
callback signing key. Needs the Sandboxes entitlement.

`enable_engine = true` adds Engine on the shared Insights deployment, with its two keys in the app Secret. It needs
Sandboxes, the Engine entitlement, and `https` with a domain, which its callbacks reach it on; `make plan` refuses it
otherwise. Engine calls its models with provider keys, through your own LLM gateway (`engine_gateway_*_base_url`), or
through LangSmith Intelligence (`engine_intelligence_base_url`): [ENGINE.md](ENGINE.md).

## Verify

```bash
kubectl --context <ctx> -n langsmith get pods           # all Running / Completed
kubectl --context <ctx> top pods -n langsmith            # metrics-server works
curl -s -o /dev/null -w '%{http_code}\n' http://<gateway IP>/api/v1/info   # 200
```

Then send a test trace with the LangSmith SDK (`LANGSMITH_ENDPOINT=http://<gateway IP>/api/v1`) and open it in the UI.

## First use

What a new install needs before its features work, from the
[self-hosted usage docs](https://docs.langchain.com/langsmith/self-host-usage):

| Address | What |
|:--|:--|
| `https://<domain>/` (or `http://<gateway IP>/`) | the UI |
| `<host>/api/v1` | the API: `LANGSMITH_ENDPOINT` for the SDKs and the `langsmith` CLI |
| `<host>/api/v1/otel` | OpenTelemetry ingest (`OTEL_EXPORTER_OTLP_ENDPOINT`) |
| `<host>/api-host` | the Deployments control plane API, with `enable_deployments` |

1. **An API key for applications.** Create it in this instance's UI under **Settings > API Keys**; a LangSmith Cloud
   key is not valid here. Over HTTPS with a private CA, an application must trust that CA, and Python's SDK reads its
   own roots, not the system's (`SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE`, set to a bundle with the public roots and
   your CA).
2. **Models for the features that call one.** The Playground, evaluators, Insights, Polly, Chat and Fleet call a model
   provider with the workspace's credentials: add provider keys under **Settings > Workspace > Secrets**, or a model
   that points at your own OpenAI-compatible endpoint or gateway under **Settings > Model configurations**, enabled
   for each feature. Fleet reads a `FLEET_`-prefixed key (`FLEET_OPENAI_API_KEY`) before the plain name
   ([Fleet workspace secrets](https://docs.langchain.com/langsmith/fleet/workspace-admin#workspace-secrets)). Engine
   has its own settings: [ENGINE.md](ENGINE.md).
3. **OAuth login and Remote MCP.** On from the first deploy: `make setup-env` made the signing JWKS. Log in with
   `langsmith auth login --api-url https://<domain>`.
4. **Agent images for Deployments.** Push them to a registry the nodes can pull from, then create the deployment in the
   UI ([deploy with the control plane](https://docs.langchain.com/langsmith/deploy-with-control-plane)).

## Repository layout

```
modules/baremetal/
├── Makefile                       # make help
├── README.md, ARCHITECTURE.md, SMITHDB.md, SIZING.md, TROUBLESHOOTING.md, TEARDOWN.md
├── infra/                         # Terraform root
│   ├── main.tf, locals.tf, variables.tf, outputs.tf, helm_values.tf, budget.tf, smithdb_nodes.tf,
│   │   platform.tf, trace_store.tf, sandboxes.tf
│   ├── terraform.tfvars.example
│   ├── modules/                   # metrics-server, local-path, metallb, envoy-gateway, cloudflared,
│   │                              # postgres, redis, rustfs
│   ├── scripts/                   # setup-env.sh, _common.sh
│   └── tests/                     # plan tests (mocked providers): bash scripts/plan-tests.sh modules/baremetal
└── helm/
    ├── scripts/                   # init-values.sh, deploy.sh
    └── values/                    # values.yaml, examples/, langsmith-values-local.yaml.example
```

## More

- [ARCHITECTURE.md](ARCHITECTURE.md): components, namespaces, request and write paths, storage
- [SMITHDB.md](SMITHDB.md): SmithDB on bare metal, recommended settings, known issues
- [ENGINE.md](ENGINE.md): Engine, its keys, and how it reaches its models (provider keys, your gateway, LangSmith Intelligence)
- [SIZING.md](SIZING.md): assumptions and formulas for Redis, ingest workers, query and storage
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptoms, causes and fixes
- [TEARDOWN.md](TEARDOWN.md): removing LangSmith and the module, and what data survives
