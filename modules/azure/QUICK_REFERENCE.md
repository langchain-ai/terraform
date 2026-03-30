# LangSmith Azure — Quick Reference

All commands run from `terraform/azure/`. Run `make help` to see all targets.

For demo/POC (all in-cluster DBs) see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md).

---

## First-Time Setup

```bash
cd terraform/azure

# 1. Generate terraform.tfvars (interactive wizard — subscription, region, ingress, TLS, sizing)
make quickstart

# 2. Bootstrap secrets — prompts for passwords + license key on first run,
#    reads silently from Key Vault on every subsequent run
make setup-env

# 3. Check prerequisites (az CLI logged in, resource providers registered, RBAC, quotas)
make preflight

# 4. Deploy infrastructure (~15–20 min)
# Note: make plan fails on a fresh deploy (no cluster yet for kubernetes_manifest).
# Skip plan and run apply directly — it runs three targeted stages automatically.
make init
make apply

# 5. Get cluster credentials
make kubeconfig

# 6. Create K8s secrets from Key Vault (langsmith-config-secret)
make k8s-secrets

# 7. Generate Helm values from Terraform outputs
make init-values

# 8. Deploy LangSmith (~10 min)
make deploy

# 9. Check status
make status
```

Or run everything after `make apply` in one shot:

```bash
make deploy-all   # kubeconfig → k8s-secrets → init-values → deploy
```

**Prefer editing over the wizard?** Copy the example and fill in manually:

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
vi infra/terraform.tfvars   # required: subscription_id, identifier, location
# then continue from step 2 above
```

**Terraform Helm path** (alternative Pass 2 — Helm release managed in Terraform state):

```bash
# After make apply, instead of make kubeconfig → make k8s-secrets → make deploy:
cp app/terraform.tfvars.example app/terraform.tfvars
vi app/terraform.tfvars   # set admin_email at minimum
make init-app             # pulls infra outputs into app/infra.auto.tfvars.json + tf init
make apply-app            # creates K8s secrets + langsmith-ksa SA + Helm release via Terraform
```

Or end-to-end via Terraform:

```bash
make deploy-all-tf   # apply → init-values → init-app → apply-app
```

---

## Day-2 Operations

```bash
# Check deployment state and get next-step guidance
make status

# Quick status (skip Key Vault + K8s queries)
make status-quick

# Re-deploy after changing Helm values or upgrading chart version (Helm path)
make deploy

# Re-generate Helm values after Terraform changes (Helm path)
make init-values

# Update kubeconfig for the AKS cluster
make kubeconfig

# Re-create langsmith-config-secret from Key Vault (Helm path)
make k8s-secrets

# Re-apply Helm release changes (Terraform path)
make apply-app

# Re-pull infra outputs after infra changes (Terraform path)
make init-app
```

---

## Pass 3 — LangSmith Deployments

**Prerequisite:** Pass 2 healthy — all core pods Running/Completed.

LangSmith Deployments adds `host-backend`, `listener`, and `operator`. The `operator` spawns agent deployment pods on demand into the `langsmith` namespace. Required before enabling Agent Builder or Insights.

**Before enabling:** bump `default_node_pool_min_count` to at least `5` in `terraform.tfvars` — operator-spawned pods need headroom. Then re-apply infra:

```bash
# infra/terraform.tfvars
default_node_pool_min_count = 5      # operator pods need headroom
enable_deployments          = true
```

```bash
make apply          # scale up node pool
make init-values    # picks up enable_deployments = true
make deploy         # rolls out host-backend + listener + operator
```

**Verify:**

```bash
kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
# Expected: all Running
kubectl get lgp -n langsmith          # list LangSmith Deployments
kubectl get crd | grep langchain      # operator CRDs registered
```

**Watchout:** `config.deployment.url` must include `https://` and point to your LangSmith URL. Missing protocol → operator-spawned agents stuck in `DEPLOYING` indefinitely.

---

## Pass 4 — Agent Builder

**Prerequisite:** Pass 3 healthy — `listener` and `operator` pods Running.

Agent Builder adds `agent-builder-tool-server`, `agent-builder-trigger-server`, and an `agentBootstrap` Job that registers the built-in Polly agent URL in a ConfigMap.

```bash
# infra/terraform.tfvars
enable_agent_builder = true
```

```bash
make init-values    # picks up enable_agent_builder = true
make deploy
```

**Verify:**

```bash
kubectl get pods -n langsmith | grep agent-builder
# Expected: tool-server Running, trigger-server Running, agentBootstrap Completed

kubectl get pods -n langsmith | grep -E "tool-server|trigger-server|Bootstrap"
```

**Watchout:** The `agentBootstrap` Job creates the `langsmith-polly-config` ConfigMap that the frontend reads for the Polly UI. If the frontend was already running when bootstrap completed, roll it:

```bash
kubectl rollout restart deployment langsmith-frontend -n langsmith
```

---

## Pass 5 — Insights + Polly

**Prerequisite:** Pass 4 healthy — Agent Builder pods Running, `agentBootstrap` Completed.

Insights enables ClickHouse-backed trace analytics. Polly is the AI eval/monitoring agent (requires Deployments + Agent Builder). Enable both together.

```bash
# infra/terraform.tfvars
enable_insights = true
enable_polly    = true
```

```bash
make init-values    # picks up both flags
make deploy
```

**Verify:**

```bash
kubectl get pods -n langsmith | grep -E "clickhouse|polly|clio"
# ClickHouse already running from Pass 2; Insights operator deploys clio pods
kubectl get pods -n langsmith -w     # watch for new clio/analytics pods to come up
```

**Watchouts:**

- `insights_encryption_key` and `polly_encryption_key` **must never change** after first enable — changing either breaks all existing encrypted data permanently.
- Roll frontend after first Polly enable if Polly UI shows "Unable to connect": `kubectl rollout restart deployment langsmith-frontend -n langsmith`

---

## Sizing

Set `sizing_profile` in `infra/terraform.tfvars`:

```hcl
sizing_profile = "production"         # multi-replica with HPA (recommended)
sizing_profile = "production-large"   # high-volume (~50 users, ~1000 traces/sec)
sizing_profile = "dev"                # single-replica, minimal resources (dev/CI/demos)
sizing_profile = "minimum"            # absolute minimum (demos, very low resource budget)
```

Then re-run `make init-values && make deploy`.

---

## Deployment Summary

| Pass | What | Make target |
|------|------|-------------|
| **1** | AKS + Postgres + Redis + Blob + Key Vault + cert-manager + KEDA | `make apply` |
| **1.5** | Cluster credentials + K8s secrets from Key Vault | `make kubeconfig && make k8s-secrets` |
| **2 (Helm)** | LangSmith base (~25 pods production) — frontend, backend, platform-backend, ingest, queue, clickhouse | `make init-values && make deploy` |
| **2 (TF)** | Same via Terraform — secrets + SA + Helm release in state | `make init-app && make apply-app` |
| **3** | LangSmith Deployments — host-backend, listener, operator. Scale nodes to min 5 first. | `make apply && make init-values && make deploy` |
| **4** | Agent Builder — tool-server, trigger-server, agentBootstrap job | `make init-values && make deploy` |
| **5** | Insights + Polly — clio analytics pods, Polly eval agent | `make init-values && make deploy` |

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
dns_label        = "langsmith-prod"
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

## app/terraform.tfvars (Terraform Helm path)

Only needed when using `make apply-app`. Infrastructure values are auto-populated by `make init-app`. You only need to set app-specific config:

```hcl
# ── Required ──────────────────────────────────────────────────────────────────
admin_email = "you@example.com"

# ── Optional ──────────────────────────────────────────────────────────────────
# sizing = "production"          # minimum | dev | production | production-large
# chart_version = "0.7.0"        # pin version; empty = latest

# ── Feature toggles ───────────────────────────────────────────────────────────
# enable_agent_deploys = true    # Pass 3 — LangSmith Deployments
# enable_agent_builder = true    # Pass 4 — Agent Builder (requires agent_deploys)
# enable_insights      = true    # Pass 5 — Insights (requires clickhouse_host)
# enable_polly         = true    # Pass 5 — Polly (requires agent_deploys)
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

## Pass 2 Expected Pods

Production sizing (`sizing_profile = "production"`) runs multiple replicas with HPA. Expect ~25–30 pods total:

```
NAME                                               READY   STATUS      RESTARTS   AGE
langsmith-ace-backend-xxxxxxxxx-xxxxx              1/1     Running     0          5m
langsmith-backend-xxxxxxxxx-xxxxx                  1/1     Running     0          5m   # ×3 replicas
langsmith-backend-auth-bootstrap-xxxxx             0/1     Completed   0          5m
langsmith-backend-ch-migrations-xxxxx              0/1     Completed   0          5m
langsmith-backend-migrations-xxxxx                 0/1     Completed   0          5m
langsmith-clickhouse-0                             1/1     Running     0          5m
langsmith-frontend-xxxxxxxxx-xxxxx                 1/1     Running     0          5m   # ×2 replicas
langsmith-ingest-queue-xxxxxxxxx-xxxxx             1/1     Running     0          5m   # ×3 replicas
langsmith-platform-backend-xxxxxxxxx-xxxxx         1/1     Running     0          5m   # ×2 replicas
langsmith-playground-xxxxxxxxx-xxxxx               1/1     Running     0          5m
langsmith-queue-xxxxxxxxx-xxxxx                    1/1     Running     0          5m   # ×3 replicas
```

**Pass 3 adds** (after `enable_deployments = true`):
```
langsmith-host-backend-xxxxxxxxx-xxxxx             1/1     Running     0          5m
langsmith-listener-xxxxxxxxx-xxxxx                 1/1     Running     0          5m
langsmith-operator-xxxxxxxxx-xxxxx                 1/1     Running     0          5m
```

**Pass 4 adds** (after `enable_agent_builder = true`):
```
langsmith-agent-builder-tool-server-xxxxx          1/1     Running     0          5m
langsmith-agent-builder-trigger-server-xxxxx       1/1     Running     0          5m
langsmith-agent-builder-bootstrap-xxxxx            0/1     Completed   0          5m
```

**Pass 5 adds** (after `enable_insights = true`, `enable_polly = true`):
```
langsmith-clio-xxxxxxxxx-xxxxx                     1/1     Running     0          5m   # Insights analytics
# Polly agent pod appears in langsmith ns after agentBootstrap registers it
```

---

## Key Watchouts

> **`langsmith-config-secret` key name:** The job expects `initial_org_admin_password` (not `admin_password`). Wrong key → `CreateContainerConfigError` on auth-bootstrap.

> **`config.deployment.url` must include `https://`.** Example: `url: "https://langsmith-prod.eastus.cloudapp.azure.com"`. Missing the protocol causes operator-deployed agents to stay stuck in `DEPLOYING` state indefinitely ("ConnectionError: Unable to connect to LangGraph server").

> **`config.deployment.enabled: true` is required for Pass 3.** Setting only `config.deployment.url` without `enabled: true` causes the chart to silently skip `listener` and `operator`.

> **`insights_encryption_key` and `polly_encryption_key` must never change** after first enable — changing either breaks existing encrypted data permanently.

> **Roll frontend after first Polly enable.** The `agentBootstrap` job creates `langsmith-polly-config` ConfigMap with `VITE_POLLY_DEPLOYMENT_URL` after Polly registers. If the frontend pod was running before bootstrap completed, Polly shows "Unable to connect to LangGraph server" (falls back to `localhost:8123`). Fix: `kubectl rollout restart deployment langsmith-frontend -n langsmith`

> **Uninstall Helm BEFORE `terraform destroy`.** The Azure Load Balancer created by NGINX blocks VNet deletion. Run `helm uninstall langsmith -n langsmith --wait` first.

> **DNS label works for nginx, istio, istio-addon, and envoy-gateway.** `dns_label` applies the `service.beta.kubernetes.io/azure-dns-label-name` annotation to whichever LB service your ingress controller creates. No custom domain needed — `<label>.<region>.cloudapp.azure.com` resolves immediately. Not applicable to AGIC — use `langsmith_domain` with an A record pointing to `terraform output agw_public_ip_address`, or use the auto-assigned FQDN from `terraform output agw_public_ip_fqdn`.

> **AGIC requires a dedicated `/24` subnet.** Terraform creates it automatically (`10.0.96.0/24`) when `ingress_controller = "agic"`. Application Gateway v2 requires an exclusive subnet — no pods, VMs, or other resources. The subnet is managed by the networking module; no manual creation needed.

> **AGIC `ignore_changes` lifecycle.** Terraform creates the App Gateway with placeholder backend/listener/rule. AGIC rewrites these on first reconcile. `ignore_changes` in the AGW resource prevents Terraform from overwriting AGIC-managed routing on subsequent `terraform apply` runs.

> **Envoy Gateway uses Gateway API, not Ingress.** Set `ingress.enabled: false` in LangSmith Helm values and apply Gateway + HTTPRoute resources manually. See `helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml` for the step-by-step commands.

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
