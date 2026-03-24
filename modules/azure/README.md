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

## Makefile

Run from `terraform/azure/`:

```bash
make help          # list all targets
make setup-env     # bootstrap secrets → secrets.auto.tfvars
make preflight     # validate az CLI, auth, resource providers, RBAC
make init          # terraform init
make plan          # terraform plan
make apply         # terraform apply — infrastructure
make kubeconfig    # az aks get-credentials
make k8s-secrets   # Key Vault → langsmith-config-secret
make init-values   # TF outputs → helm/values/values-overrides.yaml
make deploy        # helm upgrade --install (values chain: base + overrides + sizing + addons)
make status        # 9-section health check
make status-quick  # quick status (skip Key Vault + K8s queries)
make deploy-all    # apply → kubeconfig → k8s-secrets → init-values → deploy
make uninstall     # helm uninstall langsmith (run before terraform destroy)
make destroy       # terraform destroy
make clean         # remove local secrets and generated files (run after destroy)
```

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
