# LangSmith on Azure — Deployment Guide

Self-hosted LangSmith on Azure Kubernetes Service (AKS), managed with Terraform.

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on Azure. Deployment is split into five passes:

| Pass | What | How | Time |
|------|------|-----|------|
| **Pass 1** | AKS cluster, Postgres, Redis, Blob, Key Vault, cert-manager, KEDA | `make apply` | ~15–20 min |
| **Pass 1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` | ~2 min |
| **Pass 2** | LangSmith Helm chart (17 pods) | `make init-values` → `make deploy` | ~10 min |
| **Pass 3** | + LangSmith Deployments (`enable_deployments = true`) | `make init-values && make deploy` | ~5 min |
| **Pass 4** | Agent Builder (`enable_agent_builder = true`) | `make init-values && make deploy` | ~5 min |
| **Pass 5** | Insights + Polly (`enable_insights = true`, `enable_polly = true`) | `make init-values && make deploy` | ~5 min |

A [Makefile](Makefile) wraps all commands — run `make help` to see available targets.

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | Azure DB for PostgreSQL (private) | Azure Cache for Redis (private) | [LangChain Managed](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to Azure Blob — never to ClickHouse.
>
> **In-cluster ClickHouse is for dev/POC only.** It runs as a single pod with no replication or backups. For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

---

## Prerequisites

### Required tools

```bash
# Azure CLI (>= 2.50)
brew install azure-cli
az --version

# Terraform (>= 1.5)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version
```

### Required Azure RBAC

The identity running Terraform needs the following roles on the subscription:

| Role | Purpose |
|------|---------|
| `Contributor` | Create and manage all Azure resources |
| `User Access Administrator` | Create role assignments for Key Vault, Blob, cert-manager managed identities |

Owner includes both. Contributor alone is insufficient (role assignments require UAA).

### Authenticate

```bash
az login
az account set --subscription <your-subscription-id>
az account show   # verify correct subscription
```

---

## Quick Start

```bash
cd terraform/azure

# 1. Copy and fill in your variables
cp infra/terraform.tfvars.example infra/terraform.tfvars
vi infra/terraform.tfvars   # set subscription_id, identifier, location, langsmith_domain

# 2. Bootstrap secrets (prompts on first run, reads from Key Vault on repeat)
make setup-env

# 3. Check prerequisites
make preflight

# 4. Deploy infrastructure (~15–20 min)
# Note: make plan will fail on a fresh deploy (no cluster yet for kubernetes_manifest).
# Skip plan and run apply directly — it handles the ordering in three stages.
make init
make apply

# 5. Get cluster credentials + K8s secrets
make kubeconfig
make k8s-secrets

# 6. Generate Helm values from Terraform outputs
make init-values

# 7. Deploy LangSmith (~10 min)
make deploy

# 8. Check status
make status
```

Or run everything after `make apply` in one shot:

```bash
make deploy-all   # kubeconfig → k8s-secrets → init-values → deploy
```

For the full copy-paste guide with expected outputs and gotchas, see [QUICK_REFERENCE.md](QUICK_REFERENCE.md).
For demo/POC (all in-cluster DBs), see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md).

---

## Deployment Passes

| Pass | What | Make target |
|------|------|-------------|
| **1** | AKS + Postgres + Redis + Blob + Key Vault + cert-manager + KEDA + ClusterIssuer | `make apply` |
| **1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` |
| **2** | LangSmith Helm (17 pods) | `make init-values && make deploy` |
| **3** | + LangSmith Deployments (`enable_deployments = true`) | `make init-values && make deploy` |
| **4** | + Agent Builder (`enable_agent_builder = true`) | `make init-values && make deploy` |
| **5** | + Insights + Polly (`enable_insights = true`, `enable_polly = true`) | `make init-values && make deploy` |

---

## TLS / Edge Options

| Option | Variables | When to use |
|--------|-----------|-------------|
| **Public IP DNS label** ⭐ | `nginx_dns_label` + `tls_certificate_source = "letsencrypt"` | Fastest. Free Azure subdomain (`<label>.<region>.cloudapp.azure.com`). cert-manager HTTP-01. No DNS zone needed. Best for dev/demo/POC. |
| **DNS-01 + cert-manager** | `tls_certificate_source = "dns01"` + `langsmith_domain` + `create_dns_zone = true` | Custom domain + Let's Encrypt DNS-01 challenge via Azure DNS. |
| **Front Door** | `create_frontdoor = true` + `langsmith_domain` | Azure-managed cert at the edge, WAF, CDN. Custom domain required. |
| **None** | `tls_certificate_source = "none"` | Bring your own TLS. |

**Recommended for quick deployments** — Azure Public IP DNS label with Let's Encrypt HTTP-01. No custom domain, no DNS zone, instant certificate. Terraform creates the cert-manager `ClusterIssuer` automatically in Pass 1.

**Front Door only** — after `make apply`, set up DNS at your registrar:

```bash
terraform -chdir=infra output frontdoor_endpoint_hostname  # → add CNAME at registrar
terraform -chdir=infra output frontdoor_validation_token   # → add TXT _dnsauth record
```

Public IP DNS label requires no registrar step — the subdomain (`<label>.<region>.cloudapp.azure.com`) is ready immediately after `make apply`.

---

## Command Glossary

All commands run from `terraform/azure/`. Run `make help` to see the list at any time.

---

### `make setup-env` — Bootstrap secrets
**Script:** `infra/scripts/setup-env.sh`

Collects all sensitive values and writes them to `infra/secrets.auto.tfvars` (gitignored, chmod 600). Terraform picks this file up automatically — no shell exports needed.

- Derives the Key Vault name from `identifier` in `terraform.tfvars` (e.g. `langsmith-kv-azonf`)
- **First run:** prompts for PostgreSQL password, LangSmith license key, admin password, and admin email
- **Subsequent runs:** reads all values silently from Azure Key Vault — no prompts
- Stable secrets (API key salt, JWT secret, 4 Fernet encryption keys): reads from Key Vault → falls back to local dot-files → generates fresh if neither exists
- **Read-only against Key Vault** — never writes to KV directly. Terraform is the sole Key Vault writer; `setup-env.sh` only reads from it

> Run this before `make plan` or `make apply`. Re-run any time to rotate credentials.

---

### `make preflight` — Pre-flight validation
**Script:** `infra/scripts/preflight.sh`

Catches the most common problems before you spend 20 minutes on a failing `terraform apply`.

- Checks `az` CLI version and confirms you are logged in
- Prints the active subscription — prompts you to verify it is correct
- Validates 11 required Azure resource providers are registered (`Microsoft.ContainerService`, `Microsoft.DBforPostgreSQL`, `Microsoft.Cache`, `Microsoft.KeyVault`, `Microsoft.Storage`, and others)
- Checks RBAC: requires **Contributor** + **User Access Administrator** (or **Owner**) at subscription scope — needed for role assignments in the Key Vault, storage, and WAF modules
- Verifies `terraform.tfvars` exists with `location` and `subscription_id` set
- Verifies `secrets.auto.tfvars` exists and has a non-empty `langsmith_license_key`
- Checks that `terraform`, `kubectl`, and `helm` binaries are on PATH

> Safe to run at any time with no side effects.

---

### `make init` — Terraform init
Runs `terraform init` in `infra/`. Downloads the AzureRM provider, initializes the backend, and updates module sources. Required once per fresh clone and after any provider version change.

---

### `make plan` — Terraform plan
Runs `terraform plan` in `infra/`. Auto-runs `setup-env.sh` first if `secrets.auto.tfvars` is missing. Prints every resource that will be created, changed, or destroyed — no changes are made. Review this output before `make apply`.

---

### `make apply` — Provision Azure infrastructure
Runs `terraform apply -auto-approve` in `infra/`. Auto-runs `setup-env.sh` if needed. Creates all Azure resources (~15–20 min on first run):

- VNet + subnets (AKS, Postgres, Redis) + private DNS zones
- AKS cluster + node pools + OIDC issuer + managed identity + Workload Identity federated credentials
- Azure DB for PostgreSQL Flexible Server (if `postgres_source = "external"`)
- Azure Cache for Redis Premium (if `redis_source = "external"`)
- Azure Blob storage account + container + managed identity
- Azure Key Vault (RBAC mode, soft-delete) + all 10 application secrets
- cert-manager, KEDA, NGINX ingress controller (via Helm, inside Terraform)
- `langsmith` namespace + `langsmith-sa` service account

---

### `make destroy` — Destroy Azure infrastructure
Runs `terraform destroy` in `infra/`. Permanently deletes all Azure resources. **Run `make uninstall` first** — if active LoadBalancer services remain, the cluster cannot be deleted and Terraform will timeout.

---

### `make clean` — Remove generated local files
**Script:** `infra/scripts/clean.sh`

Prompts for confirmation, then removes all generated and sensitive local files. Safe to run after a full teardown.

- Removes `infra/terraform.tfvars` and `infra/secrets.auto.tfvars`
- Removes temporary dot-files written by `setup-env.sh` (`.api_key_salt`, `.jwt_secret`, `.deployments_key`, etc.)
- Removes `infra/terraform.tfstate` and `terraform.tfstate.backup` (only present when not using remote backend)
- Removes `helm/values/values-overrides.yaml` and all `helm/values/langsmith-values-*.yaml` (generated by `make init-values`)
- Keeps `terraform.tfvars.example`, `helm/values/examples/`, and `.terraform/` cache

---

### `make kubeconfig` — Fetch cluster credentials
**Script:** `helm/scripts/get-kubeconfig.sh`

- Reads `aks_cluster_name` and `resource_group_name` from `terraform output`
- Runs `az aks get-credentials --overwrite-existing`
- Merges the AKS context into `~/.kube/config` and sets it as the active context
- Prints `kubectl get nodes` so you can confirm connectivity immediately

---

### `make k8s-secrets` — Push secrets into the cluster
**Script:** `infra/scripts/create-k8s-secrets.sh`

Bridges Key Vault (Terraform's output) to Kubernetes (Helm's input). Safe to re-run — uses `--dry-run=client | kubectl apply` so it updates in place without recreating the secret.

- Resolves Key Vault name from `terraform output keyvault_name`
- Reads 8 secrets from Key Vault: `api_key_salt`, `jwt_secret`, `langsmith_license_key`, `initial_org_admin_password`, `deployments_encryption_key`, `agent_builder_encryption_key`, `insights_encryption_key`, `polly_encryption_key`
- Creates or updates `langsmith-config-secret` in the `langsmith` namespace
- Verifies all 8 keys are present and prints a pass/fail for each

> Helm reads this secret via `config.existingSecretName: langsmith-config-secret`. No secrets are stored in Helm values files.

---

### `make init-values` — Generate Helm values from Terraform outputs
**Script:** `helm/scripts/init-values.sh`

Translates Terraform outputs and `terraform.tfvars` flags into Helm values files. Re-running is safe — outputs are refreshed, existing hostname is preserved unless overridden.

- Reads from `terraform.tfvars`: `identifier`, `location`, `tls_certificate_source`, `postgres_source`, `redis_source`, `sizing_profile`, `nginx_dns_label`, `langsmith_domain`, `create_frontdoor`, `enable_*` flags
- Reads from `terraform output`: storage account name, container name, Workload Identity client ID, namespace, admin email, cluster name
- Determines hostname in priority order: `langsmith_domain` → `nginx_dns_label` (→ `<label>.<region>.cloudapp.azure.com`) → Front Door endpoint → existing value in file → interactive prompt
- Generates `helm/values/values-overrides.yaml` with: hostname, auth config, Blob WI config, Postgres/Redis blocks, Workload Identity annotations for 5 service accounts, ingress/TLS block
- Copies the selected sizing file from `examples/` into `helm/values/`
- Copies addon files based on `enable_*` flags: `agent-deploys` (with `url` and `tlsEnabled` injected automatically), `agent-builder`, `insights` (minimal in-cluster file or full external example), `polly`

---

### `make deploy` — Deploy LangSmith via Helm
**Script:** `helm/scripts/deploy.sh`

The main deploy command. Handles everything from pre-checks to post-deploy verification.

- Validates `values-overrides.yaml` exists (fails fast with `make init-values` hint if missing)
- Refreshes kubeconfig via `az aks get-credentials`
- Annotates the NGINX LoadBalancer service with `service.beta.kubernetes.io/azure-dns-label-name` (read from `nginx_dns_label` in tfvars) — this is what makes `<label>.<region>.cloudapp.azure.com` resolve
- Creates the `letsencrypt-prod` cert-manager `ClusterIssuer` if `tls_certificate_source = "letsencrypt"` (idempotent — skipped if it already exists)
- Runs `preflight-check.sh`: confirms kubectl, helm, az, terraform are on PATH; tests cluster connectivity; updates the `langchain` Helm repo
- Verifies `langsmith-config-secret` exists — auto-creates it from Key Vault if missing
- Reads `enable_*` feature flags from tfvars and validates addon dependencies (agent builder requires deployments)
- Builds the values chain and logs each file included: `values.yaml` → `values-overrides.yaml` → sizing overlay → addon overlays
- Guards against a stuck Helm release: auto-rolls back `pending-upgrade` state before proceeding
- Runs `helm upgrade --install langsmith langchain/langsmith --timeout 20m`
- Waits for core deployments to roll out (`frontend`, `backend`, `platform-backend`, `ingest-queue`, `queue`, and Deployments pods if enabled)
- Annotates the `langsmith-ksa` service account with the Workload Identity client ID (used by operator-spawned agent pods)
- Prints the access URL, login email, and the `az keyvault` command to retrieve the admin password

---

### `make deploy-all` — Full deploy in one shot
Runs `apply → kubeconfig → k8s-secrets → init-values → deploy` in sequence. Use after `terraform.tfvars` is fully configured and `make init` has been run.

---

### `make uninstall` — Remove Helm releases
**Script:** `helm/scripts/uninstall.sh`

- Refreshes kubeconfig from Terraform outputs
- Deletes all `lgp` custom resources in the `langsmith` namespace (LangGraph Platform operator-managed deployments) before removing the operator that manages them
- Helm uninstalls `langsmith` with `--wait --timeout 5m`
- Prompts before deleting the `langsmith` namespace

> Run before `make destroy`. Follow with `make clean` to remove local secrets and generated files.

---

### `make status` / `make status-quick` — Health check
**Script:** `infra/scripts/status.sh`

Runs 9 checks and prints a pass/warn/fail for each:

1. **Terraform outputs** — reads cluster name, resource group, Key Vault name
2. **Cluster connectivity** — `kubectl cluster-info`
3. **Nodes** — Ready count vs total count
4. **Bootstrap components** — pod counts for cert-manager, KEDA, ingress-nginx
5. **LangSmith pods** — Running/Completed counts; flags anything not in those states
6. **Helm release** — status (deployed / failed / pending-upgrade) and chart version
7. **Ingress + TLS** — ingress hosts and certificate Ready status
8. **Key Vault secrets** — total secret count in the vault _(skipped with `--quick`)_
9. **`langsmith-config-secret`** — key count; warns if fewer than 8 keys _(skipped with `--quick`)_

`make status-quick` skips sections 8 and 9 (no Key Vault API calls) — useful during rollouts when you just want pod counts.

---

### Addon feature flags

Addon passes (3–5) are controlled by flags in `infra/terraform.tfvars`. Set the flags, then re-run `make init-values && make deploy` — no `terraform apply` needed:

```hcl
sizing_profile       = "production"   # minimum | dev | production | production-large
enable_deployments   = true           # Pass 3 — LangGraph Platform (listener + operator + host-backend)
enable_agent_builder = true           # Pass 4 — Agent Builder UI (requires enable_deployments)
enable_insights      = true           # Pass 5 — Insights / Clio (ClickHouse-backed analytics)
enable_polly         = true           # Pass 5 — Polly AI evaluation (requires enable_deployments)
```

---

## Helm Values Files

Helm values are layered — later files override earlier ones. `make deploy` applies them in this order:

```
values.yaml  →  values-overrides.yaml  →  sizing file  →  addon files
```

All files in `helm/values/` are **gitignored** (generated or contain live secrets). The source templates live in `helm/values/examples/` and are copied by `make init-values`.

---

### `values.yaml` — Azure base config
**Location:** `helm/values/values.yaml` (tracked in git)

The Azure-specific base that applies on every deploy. Sets NGINX as the ingress class, configures Blob Storage with Workload Identity (no static credentials), and disables Istio gateway. You should not need to edit this file — environment-specific overrides go in `values-overrides.yaml`.

---

### `values-overrides.yaml` — Your deployment
**Location:** `helm/values/values-overrides.yaml` (gitignored, generated by `make init-values`)

The live file for your specific deployment. Generated fresh from Terraform outputs each time you run `make init-values`. Contains:

- `config.hostname` — your FQDN (from `nginx_dns_label` or `langsmith_domain`)
- `config.initialOrgAdminEmail` — the first org admin account
- `config.existingSecretName: langsmith-config-secret` — tells Helm where to find all secrets
- `config.blobStorage` — Azure storage account name + container + Workload Identity client ID
- Workload Identity annotations for 5 service accounts (backend, platform-backend, queue, ingest-queue, host-backend)
- Ingress + TLS block (cert-manager annotation, TLS secret name) based on `tls_certificate_source`
- Postgres and Redis external secret references (if using managed services)

> Edit freely after generation — re-running `make init-values` will overwrite it.

---

### Sizing files — Resource profiles

`make init-values` copies one of these to `helm/values/` based on `sizing_profile` in `terraform.tfvars`.

| File | Profile | When to use |
|------|---------|-------------|
| `langsmith-values-sizing-minimum.yaml` | `minimum` | Absolute floor — fits everything on a single small node (4 vCPU / 16 Gi). Rock-bottom CPU/memory requests from real `kubectl top` measurements on idle. **Expect OOM kills under any real traffic.** Use for cost parking, weekend standby, or single-user demos. |
| `langsmith-values-sizing-dev.yaml` | `dev` | Light non-production profile for local dev, CI pipelines, integration tests, and short-lived POCs. Single replica per component, no autoscaling. Will show instability under real workloads — that is expected. |
| `langsmith-values-sizing-production.yaml` | `production` | **Recommended for production.** Multi-replica deployments with HPA on all stateless components. Sensible CPU/memory starting points — tune with `kubectl top pods -n langsmith` after go-live. |
| `langsmith-values-sizing-production-large.yaml` | `production-large` | High-volume starting point based on the LangSmith scale guide (~50 concurrent users, ~1000 traces/sec). Elevated HPA minimums (e.g. 10 backend replicas). Start with `production` and move here when monitoring shows sustained pressure. |

---

### Addon files — Feature overlays

These are copied to `helm/values/` by `make init-values` when the corresponding `enable_*` flag is set.

**`langsmith-values-agent-deploys.yaml`** — Pass 3 (`enable_deployments = true`)

Enables the LangGraph Platform: the Deployments nav item in the UI, the `listener` pod (watches for new deployment requests), and the `operator` pod (spawns and manages agent pods). Also includes the operator's deployment template — the spec used when it creates agent pods. `make init-values` automatically injects `config.deployment.url` (your FQDN with protocol) and `config.deployment.tlsEnabled` so the operator builds correct endpoint URLs.

> Without the correct `url` and `tlsEnabled`, agent deployments will get stuck in `DEPLOYING` state indefinitely.

**`langsmith-values-agent-builder.yaml`** — Pass 4 (`enable_agent_builder = true`)

Enables the visual agent builder UI and its two supporting services: `agentBuilderToolServer` (exposes the tool registry) and `agentBuilderTriggerServer` (handles agent execution triggers). Also enables `backend.agentBootstrap` — a post-install job that registers Agent Builder as an LGP deployment and creates the required ConfigMap. Without this job, the Agent Builder nav item does not appear in the UI. Sets conservative agent worker pod resources (1 CPU / 1 Gi) instead of the chart's default 4 CPU / 8 Gi.

> Requires `enable_deployments = true`.

**`langsmith-values-insights.yaml`** — Pass 5 (`enable_insights = true`)

Enables ClickHouse-backed analytics in the Insights tab. The file generated depends on `clickhouse_source` in `terraform.tfvars`:

- `in-cluster` → minimal file with just `config.insights.enabled: true`. The Helm chart manages ClickHouse internally. No external connection needed.
- `external` → full file with `clickhouse.external.enabled: true` and a `langsmith-clickhouse` secret reference. You must create the secret and fill in the ClickHouse host/credentials before deploying.

**`langsmith-values-polly.yaml`** — Pass 5 (`enable_polly = true`)

Enables Polly, the AI-powered evaluation and monitoring agent. Polly runs as an LGP deployment (operator-managed pod). Sets resource limits for Polly's agent worker (2 CPU / 4 Gi request, 4 CPU / 8 Gi limit, scales 1–5 replicas).

> Requires `enable_deployments = true`.

---

## Repository Layout

```
azure/
├── Makefile                    # Task runner — start here
├── infra/                      # Terraform — Azure infrastructure
│   ├── main.tf                 # Module wiring
│   ├── variables.tf            # All input variables
│   ├── outputs.tf              # Terraform outputs (storage, identity, connection URLs)
│   ├── terraform.tfvars.example
│   ├── terraform.tfvars.minimum    # Minimal variable set (light deploy)
│   ├── terraform.tfvars.dev        # Dev/CI variable set
│   ├── terraform.tfvars.production # Production variable set
│   ├── secrets.auto.tfvars         # Generated by setup-env.sh — gitignored, never commit
│   └── scripts/
│       ├── _common.sh              # Shared helpers: _parse_tfvar, _tfvar_is_true, color output
│       ├── setup-env.sh            # Bootstrap secrets → secrets.auto.tfvars
│       ├── preflight.sh            # Pre-flight checks (az CLI, auth, providers, RBAC)
│       ├── status.sh               # 9-section health check (supports --quick)
│       ├── create-k8s-secrets.sh   # Key Vault → langsmith-config-secret
│       └── clean.sh                # Remove all generated/sensitive local files after teardown
├── helm/
│   ├── scripts/
│   │   ├── deploy.sh           # Helm values chain deploy (base + overrides + sizing + addons)
│   │   ├── init-values.sh      # TF outputs → values-overrides.yaml; copies sizing + addon files
│   │   ├── get-kubeconfig.sh   # az aks get-credentials wrapper
│   │   ├── preflight-check.sh  # Tools check + cluster connectivity + Helm repo
│   │   └── uninstall.sh        # Clean Helm uninstall (Azure LB warning included)
│   └── values/
│       ├── values.yaml                              # Azure base (NGINX, Blob WI, external secrets)
│       ├── values-overrides.yaml                    # Live file — gitignored, generated by init-values.sh
│       └── examples/
│           ├── langsmith-values.yaml                     # Annotated reference
│           ├── langsmith-values-sizing-minimum.yaml      # Absolute minimum resources
│           ├── langsmith-values-sizing-dev.yaml          # Dev / CI sizing
│           ├── langsmith-values-sizing-production.yaml   # Production (multi-replica + HPA)
│           ├── langsmith-values-sizing-production-large.yaml  # High-volume (~1000 traces/sec)
│           ├── langsmith-values-agent-deploys.yaml       # Pass 3 — LangGraph Platform
│           ├── langsmith-values-agent-builder.yaml       # Pass 4 — Agent Builder
│           ├── langsmith-values-insights.yaml            # Pass 5 — Insights / Clio
│           ├── langsmith-values-polly.yaml               # Pass 5 — Polly
│           └── letsencrypt-issuer-dns01.yaml             # cert-manager ClusterIssuer for DNS-01 TLS


```

---

## Terraform Modules

| Module | Required | Description |
|--------|----------|-------------|
| `networking` | yes | VNet, subnets (main, postgres, redis), private DNS zones. Multi-AZ zone pinning supported. |
| `k8s-cluster` | yes | AKS cluster, node pools, OIDC issuer, managed identity, federated credentials (Workload Identity centralized here). |
| `k8s-bootstrap` | yes | Kubernetes namespace, ServiceAccount, cert-manager, KEDA, NGINX ingress, postgres/redis K8s secrets. |
| `storage` | yes | Azure Blob storage account + container. |
| `keyvault` | yes | Azure Key Vault (RBAC mode, soft-delete) + all application secrets. |
| `postgres` | optional | Azure DB for PostgreSQL Flexible Server. Enabled when `postgres_source = "external"`. Multi-AZ standby supported. |
| `redis` | optional | Azure Cache for Redis Premium. Enabled when `redis_source = "external"`. |
| `dns` | optional | Azure DNS zone + A record. Required for DNS-01 cert issuance (`tls_certificate_source = "dns01"`). |
| `frontdoor` | optional | Azure Front Door Standard — managed TLS, CDN edge, WAF-ready. Enabled with `create_frontdoor = true`. |
| `waf` | optional | Azure Application Gateway + WAF v2. Alternative to Front Door for enterprise perimeter security. |
| `diagnostics` | optional | Log Analytics workspace + diagnostic settings for AKS, Key Vault, and Blob. |
| `bastion` | optional | Azure Bastion (Standard tier) for private SSH/RDP to cluster nodes. |

> **Workload Identity** is centralized in `k8s-cluster`. Federated credentials for blob-accessing pods (backend, platform-backend, queue, ingest-queue, host-backend, listener, agent-builder-tool-server, agent-builder-trigger-server) are registered there. Adding a new pod that needs Blob access requires updating `service_accounts_for_workload_identity` in `k8s-cluster` and running `terraform apply -target=module.aks`.

---

## Multi-AZ Support

```hcl
# Spread AKS nodes across zones 1, 2, 3
availability_zones = ["1", "2", "3"]

# PostgreSQL HA standby in a different zone
postgres_high_availability_mode = "ZoneRedundant"
```

Zone-redundant PostgreSQL requires `GeneralPurpose` or `MemoryOptimized` SKU.

---

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md).

## Service Reference

See [SERVICES.md](SERVICES.md) — what each pod does, what it depends on, and which pass enables it.

## Light Deploy (Demo / POC)

See [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md) — full guide for all-in-cluster deployment (no external Postgres/Redis), using Front Door for TLS.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — issues, gotchas, and fixes. Read before deploying.
