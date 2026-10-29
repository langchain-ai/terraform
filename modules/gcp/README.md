# LangSmith on GCP — Deployment Guide

Self-hosted LangSmith on Google Kubernetes Engine (GKE), managed with Terraform.

> **Deploy from a release tag, not `main`.** Check out the latest `v0.17.*` tag before deploying (don't hardcode a patch): `git fetch --tags && git checkout "$(git tag -l 'v0.17.*' --sort=-v:refname | head -1)"`. Tags pin the LangSmith chart line (`~0.17.0` = latest `0.17.x`, never `0.18`). See [Versioning and releases](../../README.md#versioning-and-releases).

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on GCP. Infrastructure is provisioned in three passes:

| Pass | What | Time |
|------|------|------|
| **Pass 1** | GKE cluster, VPC, Cloud SQL, Memorystore Redis, GCS bucket, K8s bootstrap | ~25–35 min |
| **Pass 2** | LangSmith Helm chart | ~10 min |
| **Pass 3** | LangSmith Deployments (KEDA-based, optional) | ~5 min |

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | Cloud SQL (private IP) | Memorystore (private IP) | [LangChain Managed](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to GCS — never to ClickHouse.
>
> **In-cluster ClickHouse is for dev/POC only.** It runs as a single pod with no replication or backups. For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

---

## Prerequisites

### Required tools

```bash
# Google Cloud SDK (>= 450)
brew install --cask google-cloud-sdk
gcloud version

# Terraform (>= 1.11.0)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version
```

### Required GCP APIs

Terraform enables these automatically on first apply. To enable manually:

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  certificatemanager.googleapis.com \
  servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  --project <your-project-id>
```

### Required IAM roles

The identity running Terraform needs `roles/owner`, or a set of predefined roles that includes `roles/resourcemanager.projectIamAdmin`. `roles/editor` alone fails at the first IAM binding. For the full role list, the IAM the deployment creates, and how to test access before the first apply, refer to [PERMISSIONS.md](PERMISSIONS.md).

### Required outbound access

LangSmith needs HTTPS egress from the cluster to **`beacon.langchain.com`** for license verification and usage reporting, unless it runs in [offline mode](https://docs.langchain.com/langsmith/self-host-egress). The module's nodes are private (`enable_private_nodes = true`) and reach the internet through the Cloud NAT it creates, and it adds no egress firewall rules, so a stock deployment works. What breaks it is an egress policy added around the module: a deny-by-default egress firewall rule or firewall policy, or a proxy. Permit `beacon.langchain.com:443` there before the first deploy.

Beacon is not the only destination such a policy has to allow. The cluster also pulls images: LangSmith's from `docker.io`, and the add-ons Terraform installs from their own registries. It reaches Let's Encrypt when it issues certificates.

With an `lcl_` license key this is a startup dependency, not only a reporting one. `platform-backend` exchanges the key with Beacon before it starts and caches the result in Redis. A first install has no cache, so when Beacon is unreachable `platform-backend` refuses to start, logging `failed to fetch license and no cached license available`, and the services behind it crash-loop. A later outage falls back to the cached license, but only until that license expires: it carries its own expiry date, after which `platform-backend` needs Beacon again.

To check the path from inside the cluster before the Helm deploy:

```bash
kubectl run beacon-check --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' https://beacon.langchain.com
```

Any HTTP status, such as `200` or `404`, means the cluster reached Beacon. `000` is not a status: curl made no connection at all, which means a timeout, a refused connection or a TLS failure, so something on the path is dropping or intercepting the traffic. Allow Beacon by name, with an FQDN or application rule. The IP table on LangSmith Cloud's documentation page lists LangSmith Cloud's own outbound addresses, not Beacon's, so it is no substitute.

### Authenticate

```bash
gcloud auth login
gcloud config set project <your-project-id>
gcloud auth application-default login
```

---

## Repository Layout

```
gcp/
├── Makefile             ← Task runner (quickstart/status/preflight/init/plan/apply/deploy)
├── infra/
│   ├── main.tf             ← Root module — enables APIs, wires sub-modules
│   ├── variables.tf        ← All input variables with defaults
│   ├── locals.tf           ← Naming: {prefix}-{env}-{resource}-{suffix}
│   ├── outputs.tf          ← Cluster, DB, Redis, Storage, Helm command outputs
│   └── modules/
│       ├── networking/     ← VPC, subnet, Cloud Router, Cloud NAT, private service connection
│       ├── k8s-cluster/    ← GKE Standard/Autopilot, node pool, Workload Identity
│       ├── postgres/       ← Cloud SQL PostgreSQL, HA, private IP
│       ├── redis/          ← Memorystore Redis, HA tier, private IP
│       ├── storage/        ← GCS bucket with TTL lifecycle rules (ttl_s/ ttl_l/)
│       ├── k8s-bootstrap/  ← Namespaces, K8s secrets, cert-manager, KEDA
│       ├── ingress/        ← Envoy Gateway (Gateway API), GatewayClass, HTTPRoute
│       ├── iam/            ← Workload Identity service accounts and bindings (wired by default)
│       ├── dns/            ← Cloud DNS managed zone + managed cert (optional via flags)
│       ├── secrets/        ← Secret Manager secrets for credentials (optional via flags)
│       ├── smithdb/        ← SmithDB metastore, object-store bucket, Workload Identity SA (optional)
│       └── smithdb-nodes/  ← SmithDB cache + compute GKE node pools (optional)
│   └── scripts/
│       ├── _common.sh          ← Shared helpers (tfvar parser, color/status helpers)
│       ├── preflight.sh        ← Pre-Terraform tooling/auth/API checks
│       ├── quickstart.sh       ← Interactive setup wizard — generates terraform.tfvars
│       ├── setup-env.sh        ← Exports TF_VAR_* secrets from Secret Manager (source it)
│       ├── status.sh           ← Deployment health check — tells you what to run next
│       ├── manage-secrets.sh   ← Secret Manager CRUD (list/get/set/validate/delete)
│       └── tf-run.sh           ← Terraform wrapper that auto-sources setup-env.sh
└── helm/
    ├── scripts/
    │   ├── deploy.sh             ← Helm deploy automation (values chain + WI annotation)
    │   ├── get-kubeconfig.sh     ← gcloud get-credentials wrapper
    │   ├── init-values.sh        ← Generates values-overrides.yaml from Terraform outputs
    │   ├── preflight-check.sh    ← Pre-deploy validation (tools, cluster, values)
    │   ├── smithdb-migration-job-start.sh ← Sets up the SmithDB historical migration (make smithdb-migration-job-start)
    │   ├── smithdb-migration-job-end.sh   ← Removes the migration setup (make smithdb-migration-job-end)
    │   └── uninstall.sh          ← Helm uninstall + operator resource cleanup
    └── values/
        ├── values.yaml                    ← GCP base Helm values (Gateway, GCS HMAC)
        ├── values-overrides.yaml.example  ← Env-specific overlay template
        └── examples/                      ← Annotated reference files and addon overlays
```

---

## Configuration

Copy and populate the variables file:

```bash
cd gcp/infra
cp terraform.tfvars.example terraform.tfvars
```

Minimum required variables:

```hcl
# Required
project_id            = "<your-gcp-project-id>"
name_prefix           = "ls"
environment           = "prod"
langsmith_license_key = "<your-license-key>"
langsmith_domain      = "langsmith.<your-domain>"

# Region / zone
region = "us-west2"
zone   = "us-west2-a"

# PostgreSQL (required when postgres_source = "external")
postgres_source   = "external"
postgres_password = "<strong-password>"   # or: export TF_VAR_postgres_password=...

# Redis
redis_source = "external"

# ClickHouse (in-cluster is default)
clickhouse_source = "in-cluster"

# TLS
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "<ops@your-domain>"

# LangSmith Deployments (Pass 3)
enable_langsmith_deployment = true
```

### Terraform state backend (recommended for production)

Copy `backend.tf.example` to `backend.tf` and fill in your bucket:

```hcl
backend "gcs" {
  bucket = "<your-terraform-state-bucket>"
  prefix = "langsmith/state"
}
```

---

## Pass 1 — Infrastructure

Provisions: VPC, GKE cluster, Cloud SQL PostgreSQL, Memorystore Redis, GCS bucket, K8s bootstrap (namespaces, K8s secrets, cert-manager, KEDA).

```bash
# Recommended workflow
cd gcp
make preflight
make init
make plan
make apply

# Equivalent direct Terraform flow
cd gcp/infra

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

> **Duration:** ~25–35 minutes. GKE creation: 10–15 min. Cloud SQL with HA: additional 10 min. Do not interrupt.

### After apply — get cluster credentials

```bash
cd ../helm/scripts
./get-kubeconfig.sh

kubectl get nodes
kubectl get ns
```

### Verify bootstrap components

```bash
kubectl get pods -n cert-manager
kubectl get pods -n keda
kubectl get secrets -n langsmith
```

---

## Pass 2 — LangSmith Helm Deploy

Use the scripted flow (includes preflight + kubeconfig refresh):

```bash
cd gcp/helm/scripts
./deploy.sh
```

Or run manually — generate secrets first:

```bash
export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export ADMIN_EMAIL="admin@example.com"
export ADMIN_PASSWORD="<strong-password>"

# GCS HMAC credentials (create in GCP Console: Storage > Settings > Interoperability)
export GCS_ACCESS_KEY="<your-hmac-access-key>"
export GCS_ACCESS_SECRET="<your-hmac-secret>"
```

```bash
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith \
  --create-namespace \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.langsmithLicenseKey="<your-license-key>" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="<your-langsmith-domain>" \
  --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
  --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
  --set config.blobStorage.bucketName="$(terraform output -raw storage_bucket_name)" \
  --set config.blobStorage.accessKey="$GCS_ACCESS_KEY" \
  --set config.blobStorage.accessKeySecret="$GCS_ACCESS_SECRET" \
  --set gateway.enabled=true \
  --set ingress.enabled=false \
  --wait --timeout 15m
```

### Verify and configure DNS

```bash
kubectl get pods -n langsmith

# Get Gateway external IP
EXTERNAL_IP=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Create A record: $EXTERNAL_IP -> <your-langsmith-domain>"

kubectl get certificate -n langsmith
```

---

## Pass 3 — LangSmith Deployments (Optional)

Enables deploying and managing LangGraph graphs from the LangSmith UI. Requires KEDA (auto-installed when `enable_langsmith_deployment = true`).

```hcl
# terraform.tfvars
enable_langsmith_deployment = true
```

```bash
cd gcp/infra
terraform apply -var-file=terraform.tfvars

kubectl get pods -n keda

helm upgrade langsmith langchain/langsmith \
  --namespace langsmith \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.deployment.enabled=true \
  --set config.deployment.url="https://<your-langsmith-domain>" \
  --wait --timeout 10m
```

---

## Variable Reference

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `project_id` | — | yes | GCP project ID |
| `region` | `us-west2` | no | GCP region |
| `zone` | `us-west2-a` | no | GCP zone for zonal resources |
| `environment` | `prod` | no | Environment: dev, staging, prod, test, uat |
| `name_prefix` | `ls` | no | Resource name prefix (1–11 chars) |
| `unique_suffix` | `true` | no | Append random suffix to resource names |
| `subnet_cidr` | `10.0.0.0/20` | no | CIDR for the GKE subnet |
| `pods_cidr` | `10.4.0.0/14` | no | CIDR for GKE pods |
| `services_cidr` | `10.8.0.0/20` | no | CIDR for GKE services |
| `gke_use_autopilot` | `false` | no | Use GKE Autopilot mode |
| `gke_node_count` | `2` | no | Initial node count per zone (Standard mode) |
| `gke_min_nodes` | `2` | no | Minimum nodes per zone for autoscaling |
| `gke_max_nodes` | `10` | no | Maximum nodes per zone for autoscaling |
| `gke_machine_type` | `e2-standard-4` | no | GKE node machine type |
| `gke_disk_size` | `100` | no | Node disk size in GB |
| `gke_release_channel` | `REGULAR` | no | GKE release channel: RAPID, REGULAR, STABLE |
| `gke_deletion_protection` | `true` | no | Enable deletion protection on GKE cluster |
| `gke_network_policy_provider` | `DATA_PLANE_V2` | no | Network policy: CALICO or DATA_PLANE_V2 |
| `postgres_source` | `external` | no | `external` (Cloud SQL) or `in-cluster` (Helm) |
| `postgres_version` | `POSTGRES_15` | no | PostgreSQL version for Cloud SQL |
| `postgres_tier` | `db-custom-2-8192` | no | Cloud SQL machine tier |
| `postgres_disk_size` | `50` | no | Cloud SQL disk size in GB |
| `postgres_high_availability` | `true` | no | Enable Cloud SQL HA (regional standby) |
| `postgres_deletion_protection` | `true` | no | Block deletion of the Cloud SQL instance from both Terraform and the Cloud SQL API; set `false` and apply before a destroy |
| `postgres_password` | `""` | when external | PostgreSQL password — use `TF_VAR_postgres_password` |
| `redis_source` | `external` | no | `external` (Memorystore) or `in-cluster` (Helm) |
| `redis_version` | `REDIS_7_0` | no | Redis version for Memorystore |
| `redis_memory_size` | `5` | no | Memorystore Redis memory size in GB |
| `redis_high_availability` | `true` | no | Enable Memorystore HA tier (Standard HA) |
| `redis_prevent_destroy` | `false` | no | Prevent accidental Terraform destroy of Redis |
| `clickhouse_source` | `in-cluster` | no | `in-cluster`, `langsmith-managed`, or `external` |
| `clickhouse_host` | `""` | when external | ClickHouse host (external/managed only) |
| `clickhouse_port` | `9440` | no | ClickHouse native protocol port |
| `clickhouse_http_port` | `8443` | no | ClickHouse HTTP port |
| `clickhouse_user` | `default` | no | ClickHouse username |
| `clickhouse_tls` | `true` | no | Enable TLS for ClickHouse connections |
| `storage_ttl_short_days` | `14` | no | GCS TTL for `ttl_s/` prefix |
| `storage_ttl_long_days` | `400` | no | GCS TTL for `ttl_l/` prefix |
| `storage_force_destroy` | `false` | no | Allow bucket deletion with objects inside |
| `langsmith_namespace` | `langsmith` | no | Kubernetes namespace for LangSmith |
| `langsmith_domain` | `langsmith.example.com` | no | Fully qualified domain name |
| `langsmith_license_key` | `""` | no | License key — use `TF_VAR_langsmith_license_key` |
| `langsmith_helm_chart_version` | `""` | no | Pin Helm chart version (empty = the pinned `~0.17.0` line; must be on the 0.17 line) |
| `install_ingress` | `true` | no | Install Envoy Gateway via Terraform |
| `ingress_type` | `envoy` | no | Ingress type: `envoy`, `istio`, or `other` |
| `tls_certificate_source` | `none` | no | `none`, `letsencrypt`, or `existing` |
| `letsencrypt_email` | `""` | when letsencrypt | Email for Let's Encrypt notifications |
| `tls_secret_name` | `langsmith-tls` | no | Name for the TLS secret in Kubernetes |
| `enable_langsmith_deployment` | `true` | no | Enable LangSmith Deployments — installs KEDA |
| `enable_deployments` | `false` | no | Enable LangGraph Platform (host-backend, listener, operator) |
| `enable_fleet` | `false` | no | Enable Fleet standalone (chart v0.15+) — replaces `enable_agent_builder`; does not require `enable_deployments` |
| `enable_standalone_polly` | `false` | no | Enable Polly standalone (chart v0.15+) — replaces `enable_polly`; does not require `enable_deployments` |
| `enable_standalone_insights` | `false` | no | Enable Insights standalone (chart v0.15+) — replaces `enable_insights`; does not require `enable_deployments` |
| `enable_agent_builder` | `false` | no | Deprecated (chart v0.15+) — `config.agentBuilder.*` is superseded by `enable_fleet` (`fleet.*`) |
| `enable_insights` | `false` | no | Enables Insights without the dedicated Cloud SQL/Memorystore wiring; `enable_standalone_insights` is preferred |
| `enable_polly` | `false` | no | Enables Polly without the dedicated Cloud SQL/Memorystore wiring; `enable_standalone_polly` is preferred |
| `owner` | `platform-team` | no | Owner label applied to all resources |
| `cost_center` | `""` | no | Cost center label for billing attribution |
| `labels` | `{}` | no | Additional labels applied to all resources |

### Optional GCP modules

| Variable | Default | Description |
|---|---|---|
| `enable_gcp_iam_module` | `true` | Wires `modules/iam` for Workload Identity + bucket IAM binding |
| `enable_secret_manager_module` | `false` | Wires `modules/secrets` for Secret Manager bootstrap secret |
| `grant_project_secret_accessor` | `false` | Grants the LangSmith service account `roles/secretmanager.secretAccessor` on the whole project. No module component needs it |
| `enable_dns_module` | `false` | Wires `modules/dns` for Cloud DNS + managed cert |
| `dns_create_zone` | `true` | Create a DNS zone when DNS module is enabled |
| `dns_existing_zone_name` | `""` | Existing zone to use when `dns_create_zone = false` |
| `dns_create_certificate` | `true` | Create a Google-managed cert when DNS module is enabled |
| `enable_smithdb` | `false` | Wires `modules/smithdb` + `modules/smithdb-nodes` — see [SmithDB](#smithdb-chart-017) and [SMITHDB.md](SMITHDB.md) |

---

## Sandboxes (chart 0.17)

Sandboxes run agent code in Firecracker microVMs on a dedicated `sandbox-host` node
pool. The sandbox file system is JuiceFS: data goes to the LangSmith GCS bucket, and
metadata goes to a dedicated Memorystore Redis.

### Requirements

- Standard GKE. Autopilot cannot run the nested-virtualization pool.
- `enable_gcp_iam_module = true` (the default, with the `in-cluster` sandbox runtime).
- A machine type with nested virtualization, such as N2.

### Enable

1. Set `enable_sandboxes = true` in `terraform.tfvars`.
2. Run `source infra/scripts/setup-env.sh`. The script creates the callback signing key.
3. Run `make deploy-all`.

### Host size

The machine type follows `sizing_profile` unless you set `sandbox_host_machine_type`:

| `sizing_profile` | `sandbox_host_machine_type` |
|---|---|
| `production`, `production-large` | `n2-standard-32` |
| every other profile | `n2-standard-8` |

- The pool is regional, so `sandbox_host_node_count`, `sandbox_host_min_node_count`
  and `sandbox_host_max_node_count` are per zone.
- `sandbox_host_min_node_count` defaults to `0`. The autoscaler keeps only the nodes
  that sandbox-host needs: one node for each replica, and the chart default is 1
  replica.
- After a node or zone failure, Kubernetes waits 5 minutes (the default unreachable
  toleration) and then replaces the sandbox-host pod. The autoscaler adds a node in
  a healthy zone, and the node pulls the sandbox-host image. Recovery takes about
  10 minutes. Running sandboxes on the failed node stop.
- Set `sandbox_host_min_node_count = 1` to keep an idle node in every zone. Recovery
  is then faster, because no node creation is necessary. Each extra zone costs one
  idle node.
- The `juicefs-format` Job prefers a sandbox-host node, but it can run on any Linux
  node. It does not wait for a sandbox-host node when the pool is at 0 nodes.
- sandbox-host has the pod annotation
  `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, so the autoscaler does
  not remove a node that runs sandboxes.
- `sandbox_host_ephemeral_local_ssd_count` (default `0`) adds local SSDs for kubelet
  and container runtime storage. The JuiceFS host cache stays at
  `/var/cache/juicefs` on the boot disk, so these disks do not speed up sandbox file
  I/O. Compute Engine accepts only specific counts. An N2 machine with 22-40 vCPU
  takes 4, 8, 16 or 24.

### Identity

- `sandbox-host` runs on the host network. GKE does not give Workload Identity to
  host-network pods, so the JuiceFS mount uses the `<name>-sbox-node` service
  account. Terraform grants that account `roles/storage.objectAdmin` on the bucket,
  with an IAM condition that limits it to objects under `<sandbox_juicefs_name>/`.
  Sandbox nodes run untrusted code, and the bucket also holds trace data.
- The `juicefs-format` Job uses the pod network and the `langsmith-sandbox-host`
  Workload Identity binding.
- `deploy.sh` sets `images.sandboxHostImage.tag` from the chart `appVersion` on each
  deploy. Do not set `sandbox_host_image_tag`.

### Verify

```bash
kubectl get jobs -n langsmith -l app.kubernetes.io/component=juicefs-format
kubectl rollout status deployment -n langsmith -l app=sandbox-host --timeout=10m
kubectl logs -n langsmith -l app=sandbox-host -c sandbox-host --tail=-1 | grep -i "juicefs mount ready"
```

To upgrade from chart 0.16, see [MIGRATION-0.16-to-0.17.md](../../MIGRATION-0.16-to-0.17.md).

### Optional dedicated sandbox cluster

`enable_sandboxes = true` uses the LangSmith GKE cluster by default. To isolate the privileged Firecracker runtime, select the dedicated-cluster topology:

```hcl
enable_sandboxes        = true
sandbox_runtime_source = "external"
sandbox_namespace       = "langsmith-sandbox" # must differ from langsmith_namespace

langsmith_helm_chart_version = "0.18.0"   # exact, 0.18 or later
gateway_load_balancer_type   = "internal" # or configure TLS; see Network
```

An external sandbox runtime needs chart 0.18 or later, pinned to one exact version: the default 0.17 line has no separate-cluster support, and the runtime chart is paired with that exact chart (see [Versions](#versions)). `terraform plan` and `make deploy` both reject anything else.

Terraform then creates, in the same VPC:

- a second Standard GKE cluster, `<name>-sbox-gke`, on its own subnet (`sandbox_subnet_cidr`, `sandbox_pods_cidr`, `sandbox_services_cidr`) and control-plane range (`sandbox_gke_master_ipv4_cidr`, default `172.17.0.16/28`; the LangSmith cluster keeps `172.17.0.0/28`). It has a small untainted system pool for GKE's own add-ons, which cannot tolerate the sandbox taint, and the nested-virtualization `sandbox-host` pool;
- a JuiceFS-only bucket, `<project>-<name>-jfs<suffix>`, with uniform bucket-level access and public access prevention, and an unconditioned `roles/storage.objectAdmin` grant for the `<name>-sbox-node` service account. Cloud Storage checks a list call against the bucket, so a grant on a shared bucket would need a condition; this one needs none, and sandbox nodes never reach trace data;
- AUTH on the JuiceFS Memorystore instance, which another cluster now reaches over the VPC;
- the firewall rules below;
- in the sandbox namespace, two write-only Secrets: the runtime Secret and the JuiceFS config (volume name, metadata URL with AUTH, bucket).

The LangSmith cluster gets none of the same-cluster pieces: no sandbox pool, no JuiceFS Secret, no quota or NetworkPolicy exceptions.

#### Identity

`sandbox-host` runs on the host network, where GKE Workload Identity does not apply, so it uses the sandbox node service account. `init-values.sh` sets `workloadIdentity.provider: gcp` in the runtime values, which moves the JuiceFS formatter onto the host network too, so the one bucket grant covers both pods and no Workload Identity binding is needed. Workload Identity stays enabled on the sandbox cluster, which hides the node service account from pod-network pods. It trusts a namespace and ServiceAccount name in every cluster of the project, so `sandbox_namespace` must differ from `langsmith_namespace`; `terraform plan` checks it.

#### Network

- **TCP 19190 into the sandbox nodes** comes from the LangSmith cluster's node and pod ranges (`platform-backend` and `ingest-queue` call `sandbox-host`; GKE does not masquerade RFC 1918 destinations, so the source is the pod IP) and from the sandbox subnet itself (hosts forward ingress requests, dial sandbox links and send live-migration streams to each other). A rule at priority 950 denies everything else from the LangSmith ranges to both sandbox pools; the VPC's `allow-internal` rule (priority 1000, no targets) would otherwise admit them on every port.
- **That hop is plain HTTP** and carries sandbox commands, files and credentials. This example keeps it inside the VPC. If the two clusters are in different networks, enable the runtime chart's host ingress with TLS (`sandboxHost.ingress` in `langsmith-sandbox`) and set its `https://` origin as `sandboxes.external.hostIngressEndpoint` in the LangSmith values instead of widening 19190.
- **Sandbox nodes reach the LangSmith API** at the runtime chart's `config.endpoint` (`<protocol>://<hostname>/api`) through the Envoy Gateway. With `gateway_load_balancer_type = "internal"` the gateway gets a private VPC address and the call stays in the VPC. An external gateway without TLS would carry the call across the internet in plaintext, so `terraform plan` refuses it: set the internal type or configure TLS. The hostname must resolve from the VPC: set `langsmith_domain = ""` (the default is `langsmith.example.com`) to use the gateway IP, or use a name in DNS the VPC sees. Choose the gateway type before the first deploy; GKE does not move an existing load balancer between external and internal.
- **Sandbox nodes reach Memorystore only for JuiceFS.** Cloud SQL and the LangSmith Redis sit in the private services range, which every subnet in the VPC reaches. An egress rule allows the JuiceFS Redis address and denies the rest of that range to the sandbox nodes, which run untrusted code. Cloud NAT and Cloud Storage access are unchanged.
- **Ranges.** The sandbox ranges must not overlap each other or the LangSmith ranges; `terraform plan` checks. On a VPC applied before, Google already picked the private services range: if creating the sandbox subnet fails with an overlap, look up that range (`gcloud compute addresses list --global --filter=purpose=VPC_PEERING`) and move the sandbox ranges.

#### Secrets

The runtime Secret (`sandbox_runtime_secret_name`, default `langsmith-sandbox-runtime`) holds exactly two keys, the `langsmith-sandbox` chart's defaults. Never copy the whole `langsmith-config` Secret into the sandbox cluster.

| Key | Value |
|-----|-------|
| `sandbox_service_auth_secret` | A dedicated sandbox service-auth secret, identical to `sandbox_service_auth_secret` in `langsmith-config`. It is never the API key salt: `api_key_salt` also signs LangSmith's own service calls, and the sandbox cluster runs untrusted code. |
| `sandbox_callback_signing_jwk` | The callback-signing JWK, identical to the one in `langsmith-config`. |

With `sandbox_runtime_source = "external"`, `setup-env.sh` generates the service-auth secret (64 hex characters) into the Secret Manager secret `langsmith-<name_prefix>-<environment>-sandbox-service-auth-secret`, `deploy.sh` adds it to `langsmith-config` as `sandbox_service_auth_secret`, and `init-values.sh` sets `sandboxes.serviceAuth.secretKey: sandbox_service_auth_secret` in the LangSmith values. The in-cluster runtime creates none of this and keeps the chart default, `api_key_salt`.

Terraform writes both runtime keys from `TF_VAR_sandbox_service_auth_secret` and `TF_VAR_sandbox_callback_signing_jwk` (exported by `source infra/scripts/setup-env.sh`) as write-only values, so neither is stored in state. `terraform plan` fails if the service-auth secret is missing, shorter than 32 characters, or equal to the API key salt. After changing either value, increment `sandbox_runtime_secret_revision` and re-apply, then restart `sandbox-host`; both sides read these values only at startup, and sandboxes fail while they disagree.

#### Versions

Each LangSmith install runs the `langsmith-sandbox` chart whose appVersion equals the `langsmith` chart's. `make deploy` reads the appVersion of the pinned `langsmith` chart and installs the newest `langsmith-sandbox` chart with the same appVersion. If no runtime chart matches, it stops before changing either release. To check by hand:

```bash
APP=$(helm show chart langchain/langsmith --version 0.18.0 | awk '/^appVersion:/{print $2}' | tr -d '"')
helm search repo langchain/langsmith-sandbox --versions --devel -o json \
  | jq -r --arg a "$APP" '[.[] | select(.app_version == $a)][0].version // error("no langsmith-sandbox chart for appVersion \($a)")'
```

#### One runtime per install

Run exactly one `langsmith-sandbox` release per LangSmith install, and only while the LangSmith release uses `sandboxes.external.enabled: true`. Two runtimes reporting to one install merge into one host pool and stop each other's sandboxes; the platform refuses the second one's reports. Do not install the runtime chart by hand next to the one `make deploy` manages, and do not point a second LangSmith install at this sandbox cluster.

#### Install, upgrade and uninstall order

- **Install:** `source infra/scripts/setup-env.sh`, `make apply`, `make init-values`, then `make deploy`. `make init-values` writes both the LangSmith values and `helm/values/langsmith-sandbox-values-overrides.yaml`; `make deploy` installs `langsmith` first, then `langsmith-sandbox` in the sandbox cluster, and waits for the JuiceFS format Job and `sandbox-host`.
- **Upgrade:** change `langsmith_helm_chart_version` and run `make deploy`. It upgrades `langsmith` first and the runtime right after, to the matching chart. If you upgrade with other tools, keep that order and upgrade the runtime within 72 hours.
- **Uninstall:** `make uninstall` removes the `langsmith-sandbox` release from the sandbox cluster first, then the LangSmith release; then run `make destroy`. Without Terraform outputs, uninstall the runtime release from the sandbox cluster yourself before running `make uninstall`.

`make deploy` and `make uninstall` reach the sandbox cluster through a temporary kubeconfig, so your current context is unchanged. To inspect it:

```bash
gcloud container clusters get-credentials <name>-sbox-gke --region <region> --project <project>
kubectl get pods -n langsmith-sandbox
```

To move an existing install from the in-cluster runtime: this topology starts a new sandbox file system in the JuiceFS-only bucket, and existing snapshots and sandboxes do not carry over. The JuiceFS Redis still holds metadata that points at chunks in the trace bucket, so replace it rather than reuse it:

1. Delete the existing sandboxes and snapshots.
2. Change `sandbox_runtime_source` and run `source infra/scripts/setup-env.sh` again (it creates the dedicated service-auth secret).
3. Apply with the Redis replaced: `make apply ARGS="-replace=module.sandbox_juicefs_redis[0].google_redis_instance.langsmith[0]"` (with `sandbox_juicefs_redis_prevent_destroy = true`, turn it off first).
4. Run `make init-values` and `make deploy`.

The JuiceFS objects left under `<sandbox_juicefs_name>/` in the trace bucket can then be deleted.

---

## SmithDB (chart 0.17)

SmithDB is the in-chart columnar store and query engine that runs alongside ClickHouse on LangSmith chart 0.17. It runs in the LangSmith namespace as part of the same Helm release - it cannot be split into its own namespace or cluster.

See [SMITHDB.md](SMITHDB.md) for the full deployment and staged-rollout guide. The rest of this section covers the GCP-specific design decisions.

Setting `enable_smithdb = true` provisions four things:

| Resource | Module | Notes |
|---|---|---|
| Cloud SQL Postgres metastore | `modules/smithdb` | Dedicated instance on a private IP, `POSTGRES_18` by default, with a tier that follows `smithdb_sizing` |
| GCS object-store bucket | `modules/smithdb` | Single-region, uniform access, no lifecycle deletes |
| Workload Identity service account | `modules/smithdb` | `roles/storage.objectAdmin` on that bucket only |
| Two GKE node pools | `modules/smithdb-nodes` | A cache pool and a compute pool; none for `smithdb_sizing = "minimal"` |

### Requirements and constraints

1) **Postgres 18 or later, on a dedicated and empty database.** The chart's metastore migration Job owns the schema. Never point this at the LangSmith operational Postgres. `smithdb_metastore_source = "external"` brings your own. On a module-created Cloud SQL instance, a Cloud SQL Auth Proxy sidecar (the default) keeps the instance at `ENCRYPTED_ONLY`. AlloyDB uses the same shape through the external path. See [SMITHDB.md](SMITHDB.md) for both.

2) **A dedicated object-storage bucket, single-region, in the cluster's region.** Multi-region and dual-region buckets add replication cost and unpredictable tail latency on segment reads. The module deliberately creates no object-expiry lifecycle rules and no versioning: SmithDB owns the lifecycle of its own segments, and expiring them independently makes data unavailable. Compaction already reclaims dead segments.

3) **GKE Standard, not Autopilot.** Autopilot manages its own node pools, so the dedicated SmithDB pools do not exist there. SmithDB pods would then stay Pending against a `nodeSelector` that never matches. The module fails at plan time rather than letting that happen.

4) **Local SSD-backed ephemeral storage, not raw block.** In `local-ssd` mode, the cache pool uses `ephemeral_storage_local_ssd_config`. That mode makes the disks part of the filesystem that kubelet reports as allocatable `ephemeral-storage`, and that filesystem backs `emptyDir`. Raw block Local SSD does not. A disk mounted at an arbitrary host path does not back `emptyDir` at all. The cache then goes to the boot disk with no error.

5) **Machine type generation changes the disk count semantics.** N2/N2D take an explicit `smithdb_instance_store_local_ssd_count` (375 GB per disk). C3 and Z3 `-lssd` types have a fixed count implied by the machine type and require `smithdb_instance_store_local_ssd_count = 0`. C4 needs a Hyperdisk boot disk, which the SmithDB pools do not use.

6) **Pin the pool zones.** The cluster is regional, so an unpinned pool tries every zone in the region and fails if the machine type or disk count is unavailable in any of them. Check availability, then set `smithdb_node_locations`.

Both pools are tainted and default to `min_node_count = 0`, so the cluster autoscaler holds them empty until SmithDB pods with matching tolerations appear. That is the closest native analogue to consolidation-style provisioning.

### Networking

The metastore is private-IP only, so `enable_smithdb` with `smithdb_metastore_source = "create"` turns on the VPC private service connection automatically, the same way `postgres_source = "external"` does.

Segment traffic to GCS stays on Google's network. The subnet already sets `private_ip_google_access = true` (see `infra/modules/networking/main.tf`), so nodes without external IPs reach `storage.googleapis.com` directly rather than egressing through Cloud NAT. This is the GCP analogue of the S3 Gateway VPC endpoint on the AWS module, and it needs no additional resources.

Adding a private `googleapis.com` DNS zone would pin resolution to `private.googleapis.com` as well, but a VPC-wide DNS zone affects every workload in the network, so treat it as a deliberate follow-up rather than part of enabling SmithDB.

### Chart version

SmithDB on this module needs chart 0.17. `deploy.sh` pins the 0.17 line and refuses anything off it, so enabling SmithDB needs no version handling of its own. To name an exact patch instead of the latest on the line:

```bash
CHART_VERSION=0.17.0 make deploy
```

List what is published with `helm search repo langchain/langsmith --versions`.

### Sizing and staged rollout

`smithdb_sizing` (`minimal`, `small`, `medium`, `large`) and `smithdb_cache_storage` (`local-ssd`, `network-disk`) in `infra/terraform.tfvars` set the chart tier, the resources, the node pool shapes, the namespace quota, and the default tier of a created metastore. An unset `smithdb_sizing` follows `sizing_profile`. The gates `smithdb_ingestion_enabled` and `smithdb_query_enabled` in the same file move SmithDB through dual write and cutover. Run `make deploy-all` after each change. ClickHouse stays enabled in every stage.

The historical migration (backfill) is the one stage with its own make targets:

```bash
make smithdb-migration-job-start   # TaskDB, sizing; sets smithdb_migration_enabled = true
make deploy-all                    # make apply, make init-values, make deploy
make smithdb-migration-job-end     # once the Job is Complete; sets smithdb_migration_enabled = false
make deploy-all
```

See [SMITHDB.md](SMITHDB.md) for the sizing table, the stages, and the upgrade from chart 0.16.

---

## Teardown

```bash
# 1. Remove LangSmith Deployments (if Pass 3 was enabled)
kubectl delete lgp --all -n langsmith 2>/dev/null || true

# 2. Uninstall LangSmith Helm release (removes Gateway load balancer)
helm uninstall langsmith -n langsmith --wait

# 3. Delete namespace
kubectl delete namespace langsmith --timeout=60s

# 4. Disable deletion protection in tfvars, then destroy
cd gcp/infra
terraform destroy
```

> Set `gke_deletion_protection = false` and `postgres_deletion_protection = false` in `terraform.tfvars` before running `terraform destroy` in production.

When SmithDB is enabled, also set `smithdb_metastore_deletion_protection = false`, and either empty the object-store bucket first or set `smithdb_bucket_force_destroy = true`. Only do the latter on disposable stacks - it deletes live trace segments.

Deletion protection is enforced by Cloud SQL itself, not just by Terraform, so editing the tfvars is not enough - apply the change before running the destroy. Cloud SQL also deletes an instance's backups and PITR logs along with the instance, so export anything you need to keep to GCS first. [TEARDOWN.md](TEARDOWN.md) has the commands for both databases.
