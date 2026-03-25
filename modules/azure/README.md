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

### Setup and validation

| Command | Script | What it does |
|---------|--------|-------------|
| `make setup-env` | `infra/scripts/setup-env.sh` | Prompts for `ARM_SUBSCRIPTION_ID`, `LANGSMITH_LICENSE_KEY`, and other secrets on first run. Writes them to `infra/secrets.auto.tfvars` (gitignored). On repeat runs, reads existing values from Azure Key Vault instead of prompting. Must run before `make plan` or `make apply`. |
| `make preflight` | `infra/scripts/preflight.sh` | Validates az CLI version and login, checks that required resource providers are registered (`Microsoft.ContainerService`, `Microsoft.KeyVault`, etc.), verifies RBAC (Contributor + User Access Administrator), and confirms `terraform.tfvars` is present. Safe to run at any time. |

### Pass 1 — Infrastructure

| Command | What it does |
|---------|-------------|
| `make init` | Runs `terraform init` in `infra/` — downloads providers and initializes the backend. Required once per clone or after provider version changes. |
| `make plan` | Runs `terraform plan` in `infra/`. Auto-sources `setup-env.sh` if `secrets.auto.tfvars` is missing. Prints a preview of all resources to be created — no changes made. |
| `make apply` | Runs `terraform apply -auto-approve` in `infra/`. Creates AKS cluster, Postgres (if external), Redis (if external), Blob storage account + container, Key Vault + all secrets, VNet, subnets, cert-manager, KEDA, NGINX ingress controller, and the `langsmith` namespace + service account. Takes ~15–20 min on first run. |
| `make destroy` | Runs `terraform destroy` in `infra/`. Destroys all Azure resources. Run `make uninstall` first to clean up Helm releases — otherwise Terraform will error trying to delete a cluster that still has active load balancers. |
| `make clean` | Runs `infra/scripts/clean.sh`. Removes `infra/secrets/` (generated env files), all `helm/values/langsmith-values-*.yaml` files (generated by `make init-values`), and any stale `.terraform.tfstate.lock.info`. Run after `make destroy` to reset local state. |

### Pass 1.5 — Cluster access and secrets

| Command | Script | What it does |
|---------|--------|-------------|
| `make kubeconfig` | `helm/scripts/get-kubeconfig.sh` | Reads `resource_group` and `cluster_name` from Terraform outputs, then runs `az aks get-credentials --overwrite-existing`. Merges the AKS context into `~/.kube/config` and sets it as the active context. |
| `make k8s-secrets` | `infra/scripts/create-k8s-secrets.sh` | Reads all 8 application secrets from Azure Key Vault (license key, salt, API key, JWT secret, Postgres URL, Redis URL, Blob connection, insights encryption key) and creates the `langsmith-config-secret` Kubernetes secret in the `langsmith` namespace. Helm references this via `config.existingSecretName`. |

### Pass 2+ — Helm deployment

| Command | Script | What it does |
|---------|--------|-------------|
| `make init-values` | `helm/scripts/init-values.sh` | Reads Terraform outputs (storage account, hostname, TLS mode, sizing profile, feature flags) and generates `helm/values/values-overrides.yaml`. Also copies the correct sizing file (`langsmith-values-sizing-<profile>.yaml`) and any enabled addon files (`agent-deploys`, `agent-builder`, `insights`, `polly`) into `helm/values/`. Injects `config.deployment.url` and `tlsEnabled` into the agent-deploys file automatically. |
| `make deploy` | `helm/scripts/deploy.sh` | Runs `helm upgrade --install langsmith` with the full values chain in order: `values.yaml` (Azure base) → `values-overrides.yaml` (generated) → sizing file → addon files. Also applies the NGINX DNS label annotation (`service.beta.kubernetes.io/azure-dns-label-name`) and creates the `letsencrypt-prod` ClusterIssuer if using Let's Encrypt. Waits for rollout. |
| `make uninstall` | `helm/scripts/uninstall.sh` | Deletes all LGP custom resources (`kubectl delete lgp --all`), removes the `lgps.apps.langchain.ai` CRD, then runs `helm uninstall` for langsmith, ingress-nginx, cert-manager, and keda, and deletes their namespaces. Run before `make destroy`. |
| `make deploy-all` | — | Combo: runs `apply → kubeconfig → k8s-secrets → init-values → deploy` in sequence. Useful for a full deploy in one shot after `terraform.tfvars` is configured. |

### Observability

| Command | Script | What it does |
|---------|--------|-------------|
| `make status` | `infra/scripts/status.sh` | Full 9-section health check: Terraform state, AKS node status, Key Vault connectivity, namespace pod counts, Helm release state, ingress + TLS certificate status, LGP deployments, and a "what to run next" suggestion. Takes ~30 sec. |
| `make status-quick` | `infra/scripts/status.sh --quick` | Same as `make status` but skips Key Vault queries and K8s object listing — faster (~5 sec). Good for checking pod counts during a rollout. |

### Addon feature flags

Addon passes (3–5) are controlled by flags in `infra/terraform.tfvars`. Set the flags, then re-run `make init-values && make deploy`:

```hcl
sizing_profile       = "production"   # minimum | dev | production | production-large
enable_deployments   = true           # Pass 3 — LangGraph Platform
enable_agent_builder = true           # Pass 4 — Agent Builder UI
enable_insights      = true           # Pass 5 — Insights / Clio
enable_polly         = true           # Pass 5 — Polly
```

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
│       ├── _common.sh              # Shared helpers: _parse_tfvar, color/status output
│       ├── setup-env.sh            # Bootstrap secrets → writes secrets.auto.tfvars
│       ├── preflight.sh            # Pre-flight checks (az CLI, auth, providers, RBAC)
│       ├── status.sh               # 9-section health check (supports --quick)
│       ├── create-k8s-secrets.sh   # Key Vault → langsmith-config-secret
│       ├── tf-run.sh               # CI-friendly terraform runner (auto-sources setup-env.sh)
│       └── clean.sh                # Remove local secrets and generated files
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
│           └── langsmith-values-polly.yaml               # Pass 5 — Polly
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
