# LangSmith Azure — Quick Reference

All commands run from `terraform/azure/`. Run `make help` to see all targets.

For demo/POC (all in-cluster DBs) see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md).

---

## First-Time Setup

```bash
cd terraform/azure

# 1. Copy and fill in your variables
cp infra/terraform.tfvars.example infra/terraform.tfvars
vi infra/terraform.tfvars    # set subscription_id, identifier, location

# 2. Bootstrap secrets (prompts on first run, reads from Key Vault on repeat)
make setup-env

# 3. Check prerequisites (az CLI, login, resource providers, RBAC)
make preflight

# 4. Deploy infrastructure (~15–20 min)
# Note: make plan fails on a fresh deploy (no cluster yet for kubernetes_manifest).
# Skip plan and run apply directly — it handles the ordering in three stages.
make init
make apply

# 5. Get cluster credentials
make kubeconfig

# 6. Create K8s secrets from Key Vault
make k8s-secrets

# 7. Generate Helm values from Terraform outputs
make init-values

# 8. Deploy LangSmith (~10 min)
make deploy

# 9. Check status
make status
```

Or run the full deployment in one shot:

```bash
make deploy-all   # apply → kubeconfig → k8s-secrets → init-values → deploy
```

---

## Day-2 Operations

```bash
# Check deployment state and get next-step guidance
make status

# Quick status (skip Key Vault + K8s queries)
make status-quick

# Re-deploy after changing Helm values or upgrading chart version
make deploy

# Re-generate Helm values after Terraform changes
make init-values

# Update kubeconfig for the AKS cluster
make kubeconfig

# Re-create langsmith-config-secret from Key Vault
make k8s-secrets
```

---

## Enable Optional Addons (Passes 3–5)

Addons are controlled by `enable_*` flags in `infra/terraform.tfvars`. Set the flags, then re-run `init-values` to copy the corresponding values files:

```hcl
# infra/terraform.tfvars
enable_deployments   = true    # Pass 3 — LangSmith Deployments (required for Agent Builder + Insights)
enable_agent_builder = true    # Pass 4 — Agent Builder UI
enable_insights      = true    # Pass 5 — ClickHouse-backed analytics
enable_polly         = true    # Pass 5 — Polly AI eval/monitoring
```

```bash
make init-values   # copies addon values files based on enable_* flags
make deploy
```

**Sizing**: Set `sizing_profile` in `terraform.tfvars`:

```hcl
sizing_profile = "production"         # multi-replica with HPA (recommended)
sizing_profile = "production-large"   # high-volume (~50 users, ~1000 traces/sec)
sizing_profile = "dev"                # single-replica, minimal resources (dev/CI/demos)
sizing_profile = "minimum"            # absolute minimum (demos, very low resource budget)
```

Then re-run `make init-values && make deploy`.

---

## 5-Pass Deployment Summary

| Pass | What | Make target |
|------|------|-------------|
| **1** | AKS + Postgres + Redis + Blob + Key Vault + cert-manager + KEDA | `make apply` |
| **1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` |
| **2** | LangSmith Helm (17 pods) | `make init-values && make deploy` |
| **3** | + LangSmith Deployments (`enable_deployments = true`) | `make init-values && make deploy` |
| **4** | + Agent Builder (`enable_agent_builder = true`) | `make init-values && make deploy` |
| **5** | + Insights + Polly (`enable_insights = true`, `enable_polly = true`) | `make init-values && make deploy` |

---

## terraform.tfvars — Minimal Required

```hcl
# ── Required ──────────────────────────────────────────────────────────────────
subscription_id = ""              # az account show --query id -o tsv
identifier      = "-prod"         # suffix appended to every resource name
location        = "eastus"        # Azure region

# ── Data sources ──────────────────────────────────────────────────────────────
postgres_source   = "external"    # Azure DB for PostgreSQL Flexible Server
redis_source      = "external"    # Azure Cache for Redis Premium
clickhouse_source = "in-cluster"  # in-cluster (dev/POC) or managed

# ── AKS ───────────────────────────────────────────────────────────────────────
default_node_pool_vm_size   = "Standard_D8s_v3"
default_node_pool_max_count = 12
default_node_pool_max_pods  = 60

# ── TLS (pick one approach) ───────────────────────────────────────────────────
# Option A — Azure Public IP DNS label (fastest, free, no custom domain needed)
#   → langsmith-prod.eastus.cloudapp.azure.com
nginx_dns_label        = "langsmith-prod"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"

# Option B — Custom domain + DNS-01 challenge (production recommended)
# tls_certificate_source = "dns01"
# langsmith_domain       = "langsmith.example.com"
# letsencrypt_email      = "you@example.com"

# ── Sizing + addon flags ───────────────────────────────────────────────────────
sizing_profile = "production"
# enable_deployments   = true
# enable_agent_builder = true
# enable_insights      = true
# enable_polly         = true
```

---

## secrets.auto.tfvars

`setup-env.sh` generates this file — never commit it. Contains:

```hcl
postgres_admin_password                = "..."
langsmith_license_key                  = "..."
langsmith_admin_password               = "..."
langsmith_api_key_salt                 = "..."
langsmith_jwt_secret                   = "..."
langsmith_deployments_encryption_key   = "..."
langsmith_agent_builder_encryption_key = "..."
langsmith_insights_encryption_key      = "..."
langsmith_polly_encryption_key         = "..."
```

On subsequent runs `setup-env.sh` reads from Key Vault — no re-entry needed.

---

## Common kubectl Commands

```bash
# Pod health
kubectl get pods -n langsmith
kubectl get pods -n langsmith -w
kubectl describe pod <pod-name> -n langsmith
kubectl logs <pod-name> -n langsmith --tail=100 -f
kubectl logs <pod-name> -n langsmith --previous --tail=50

# Ingress / TLS
kubectl get svc ingress-nginx-controller -n ingress-nginx
kubectl get ingress -n langsmith
kubectl get certificate -n langsmith

# Secrets (check keys without decoding)
kubectl get secret langsmith-config-secret -n langsmith -o json | \
  python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)['data']]"

# Force pod restart
kubectl rollout restart deployment/langsmith-backend -n langsmith
```

---

## Pass 2 Expected Pods (~17)

```
NAME                                          READY   STATUS      RESTARTS   AGE
langsmith-ace-backend-xxxxxxxxx-xxxxx         1/1     Running     0          5m
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running     0          5m
langsmith-backend-auth-bootstrap-xxxxx        0/1     Completed   0          5m
langsmith-backend-ch-migrations-xxxxx         0/1     Completed   0          5m
langsmith-backend-migrations-xxxxx            0/1     Completed   0          5m
langsmith-clickhouse-0                        1/1     Running     0          5m
langsmith-frontend-xxxxxxxxx-xxxxx            1/1     Running     0          5m
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running     0          5m
langsmith-platform-backend-xxxxxxxxx-xxxxx    1/1     Running     0          5m
langsmith-playground-xxxxxxxxx-xxxxx          1/1     Running     0          5m
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running     0          5m
```

---

## Key Watchouts

> **`langsmith-config-secret` key name:** The job expects `initial_org_admin_password` (not `admin_password`). Wrong key → `CreateContainerConfigError` on auth-bootstrap.

> **`config.deployment.url` must include `https://`.** Example: `url: "https://langsmith-prod.eastus.cloudapp.azure.com"`. Missing the protocol causes operator-deployed agents to stay stuck in `DEPLOYING` state indefinitely ("ConnectionError: Unable to connect to LangGraph server").

> **`config.deployment.enabled: true` is required for Pass 3.** Setting only `config.deployment.url` without `enabled: true` causes the chart to silently skip `listener` and `operator`.

> **`insights_encryption_key` and `polly_encryption_key` must never change** after first enable — changing either breaks existing encrypted data permanently.

> **Roll frontend after first Polly enable.** The `agentBootstrap` job creates `langsmith-polly-config` ConfigMap with `VITE_POLLY_DEPLOYMENT_URL` after Polly registers. If the frontend pod was running before bootstrap completed, Polly shows "Unable to connect to LangGraph server" (falls back to `localhost:8123`). Fix: `kubectl rollout restart deployment langsmith-frontend -n langsmith`

> **Uninstall Helm BEFORE `terraform destroy`.** The Azure Load Balancer created by NGINX blocks VNet deletion. Run `helm uninstall langsmith -n langsmith --wait` first.

> **Pin `--version` in Helm.** Without it, `helm upgrade` pulls latest which may silently apply DB migrations or toggle feature flags.

---

## Teardown

```bash
# 1. Uninstall LangSmith (removes Azure Load Balancer)
make uninstall

# 2. Destroy infrastructure
make destroy

# 3. Remove local secrets and generated files
make clean
```

---

## Reference

- [ARCHITECTURE.md](ARCHITECTURE.md) — component diagram and pass structure
- [SERVICES.md](SERVICES.md) — what each pod does, dependencies, which pass enables it
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — issues, gotchas, and fixes
- [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md) — all-in-cluster demo/POC guide
