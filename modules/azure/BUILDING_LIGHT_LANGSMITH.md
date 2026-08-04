# LangSmith Azure — Light Deploy (All In-Cluster DBs)

> **Tested and verified: 2026-03-24** — chart 0.13.29, AKS 1.32.11, eastus, all in-cluster DBs, NGINX + Let's Encrypt HTTP-01 TLS (`dns_label`), Azure Public IP DNS label. All 13 pods Running/Completed. URL: `https://langsmith-demo.eastus.cloudapp.azure.com`

Full copy-paste guide for deploying LangSmith with **all databases running in-cluster** (no Azure DB for PostgreSQL, no Azure Cache for Redis, no external ClickHouse).

**Use this for:** demos, POC evaluation, customer sandboxes, cost-sensitive testing, quick turnaround deploys.
**Not for:** production, customer data, sustained workloads, or SLA-backed deployments.
**For production with external managed services see:** [QUICK_REFERENCE.md](QUICK_REFERENCE.md)

> **Warning:** In-cluster Postgres and Redis are single-pod StatefulSets with no replication and no backup policy. If the node restarts, data is gone. ClickHouse is the same. Use this tier only where data loss is acceptable.

---

## What This Guide Deploys

| Component | Where it runs | Notes |
|---|---|---|
| LangSmith application | AKS pods | backend, platform-backend, frontend, playground, ace-backend, queue |
| PostgreSQL | In-cluster pod | `langsmith-postgres-0` StatefulSet, no backup |
| Redis | In-cluster pod | `langsmith-redis-0` StatefulSet |
| ClickHouse | In-cluster pod | `langsmith-clickhouse-0` StatefulSet — dev/POC only |
| Blob Storage | Azure Blob | Always external — payloads must not go into ClickHouse |
| TLS | cert-manager + Let's Encrypt | HTTP-01 challenge via NGINX ingress — free, auto-renewing cert |
| Hostname | `<dns_label>.<region>.cloudapp.azure.com` | Free Azure subdomain. Set `dns_label` in terraform.tfvars — no registrar needed |

**Total Azure cost:** AKS cluster + 1–3 Standard_DS4_v2 nodes (~$0.30/hr each) + Blob Storage (negligible) + Key Vault (negligible). All in-cluster DBs eliminate Azure DB for PostgreSQL (~$150/mo) and Azure Cache for Redis (~$200/mo).

---

## Prerequisites

Before starting, verify all of the following:

### Tools
```bash
az --version          # Azure CLI — must be installed and logged in
terraform --version   # >= 1.5
kubectl version       # any recent version
helm version          # >= 3.x
python3 --version     # for JSON parsing in scripts
```

### Azure Access
```bash
# Must be logged in
az account show

# Verify subscription — you will deploy into this subscription
az account show --query "{name:name, id:id}" -o json

# You need Contributor + User Access Administrator on the subscription
# (or Owner, which includes both). User Access Admin is required because
# Terraform creates role assignments for Key Vault, blob storage, and
# cert-manager managed identities.
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --query "[].roleDefinitionName" -o tsv
```

### Python cryptography package (optional but recommended)
```bash
# The setup-env.sh script uses cryptography.fernet to generate Fernet keys.
# If not installed it falls back to base64/urandom — both produce valid keys.
pip3 install cryptography
```

### Kubeconfig isolation
This guide uses a **named context** (`--context langsmith-<suffix>`) on every `kubectl` and `helm` command. This is intentional — it prevents this deployment from affecting any other cluster in your kubeconfig. **Never omit `--context` in a multi-cluster environment.**

---

## Architecture Overview

```
Internet (HTTPS 443)
   │
   ▼
Azure Public IP DNS label   (e.g. langsmith-demo.eastus.cloudapp.azure.com → 20.x.x.x)
   │  Set automatically when dns_label is configured — no registrar needed
   ▼
Azure Load Balancer  (public IP provisioned by AKS for NGINX)
   │
   ▼
NGINX Ingress Controller  (installed by Terraform via Helm)
   │  terminates TLS (cert from cert-manager), routes to LangSmith pods
   ▼
LangSmith frontend pod (ClusterIP service)
   │
LangSmith backend pods ──► In-cluster Postgres  (StatefulSet)
                       ──► In-cluster Redis     (StatefulSet)
                       ──► In-cluster ClickHouse (StatefulSet)
                       ──► Azure Blob Storage   (via Workload Identity, no static key)


cert-manager  ──► ACME HTTP-01 challenge through NGINX ingress
              ──► Let's Encrypt issues cert → stored as K8s secret langsmith-tls


Key Vault ──► Stores: license key, admin password, JWT secret, API salt, Fernet keys
          ──► make k8s-secrets reads from KV → writes langsmith-config-secret
```

### Why Azure Public IP DNS label?
Azure assigns a free DNS label (`<label>.<region>.cloudapp.azure.com`) to any public IP when you annotate the LoadBalancer service with `service.beta.kubernetes.io/azure-dns-label-name`. This gives you:
- A real FQDN with no domain purchase or registrar setup
- A stable hostname that stays the same even if the IP changes (Azure updates the A record)
- Compatibility with Let's Encrypt HTTP-01 challenge (cert-manager handles everything)

The DNS label is set on the NGINX LoadBalancer service automatically during `make deploy`. The label format is `<dns_label>.<location>.cloudapp.azure.com`.

### Why Workload Identity for blob storage?
The LangSmith backend pods write trace payloads to Azure Blob Storage using Azure Workload Identity instead of a static storage account key. Terraform creates a Managed Identity, assigns it `Storage Blob Data Contributor` on the storage account, and federates it to the `langsmith-ksa` Kubernetes Service Account via an OIDC trust relationship. The pods annotate themselves with the MI client ID — the AKS OIDC issuer exchanges the pod's token for a short-lived Azure token. No secrets to rotate, no credentials in the cluster.

---

## Pass 1 — Infrastructure (Terraform)

All `make` commands run from `terraform/azure/`.

### 1a — Configure terraform.tfvars

**Option A — wizard (recommended):**

```bash
cd terraform/azure
make quickstart
```

The wizard asks 10 questions and writes `infra/terraform.tfvars`. When prompted, choose:
- Profile: **Dev / POC**
- Services: **In-cluster** for PostgreSQL, Redis, and ClickHouse
- Ingress: **nginx**
- TLS: **Let's Encrypt** with a DNS label
- Sizing: **minimum**

**Option B — copy and edit the example directly:**

```bash
cd terraform/azure
cp infra/terraform.tfvars.example infra/terraform.tfvars
```

**Full `terraform.tfvars` for light deploy — copy this exactly, fill in the four `FILL IN` fields:**

```hcl
# ── Required ───────────────────────────────────────────────────────────────────
subscription_id = ""              # FILL IN: az account show --query id -o tsv
identifier      = "-demo"         # FILL IN: suffix appended to every resource name
                                  # e.g. "-demo", "-poc", "-dev", "-acme"
                                  # Must start with hyphen, lowercase letters/numbers only
                                  # Key Vault name = "langsmith-kv<identifier>" (max 24 chars)

# ── Region & tags ──────────────────────────────────────────────────────────────
location    = "eastus"            # Azure region — eastus is cheapest for demos
environment = "dev"               # dev | staging | prod (used for resource tags)
owner       = "your@email.com"    # your email — shows up in resource tags
cost_center = "engineering"       # any string — for resource tagging

# ── Database sources — ALL in-cluster ─────────────────────────────────────────
# These three settings are what distinguish a light deploy from a full deploy.
# "in-cluster" means the LangSmith Helm chart manages these pods directly.
# No Azure DB for PostgreSQL, no Azure Cache for Redis are provisioned.
postgres_source   = "in-cluster"
redis_source      = "in-cluster"
clickhouse_source = "in-cluster"  # ClickHouse is always in-cluster regardless

# ── AKS cluster sizing ─────────────────────────────────────────────────────────
# Standard_DS4_v2 = 8 vCPU, 28 GB RAM per node
# With all DBs in-cluster you need this size — Postgres + Redis + ClickHouse
# together consume ~18 GB RAM just for requests. Standard_D4s_v3 (16 GB) is too small.
default_node_pool_vm_size   = "Standard_DS4_v2"
default_node_pool_max_count = 3     # autoscaler can add nodes if pods are pending
default_node_pool_max_pods  = 60    # AKS default of 30 is too low — LangSmith needs ~25 pods
aks_deletion_protection     = false # set true for long-lived deployments

# No additional node pool needed for light deploy.
# The standard deploy creates a "large" pool (Standard_D16s_v3) for ClickHouse,
# but in-cluster ClickHouse shares the default DS4_v2 pool just fine for demos.
additional_node_pools = {}

# ── Blob storage ───────────────────────────────────────────────────────────────
# Always required — LangSmith stores trace payloads in blob storage.
# Short TTL = compressed run payloads, Long TTL = run attachments/files
blob_ttl_enabled    = true
blob_ttl_short_days = 14
blob_ttl_long_days  = 400

# ── Key Vault ──────────────────────────────────────────────────────────────────
# Stores all secrets (license key, admin password, JWT, Fernet keys).
# purge_protection = false means you can delete and re-create the KV on destroy.
# Set true only for long-lived deployments where you need GDPR-level deletion protection.
keyvault_purge_protection = false

# ── Ingress & TLS ──────────────────────────────────────────────────────────────
# NGINX ingress + Let's Encrypt HTTP-01 (recommended for demos — no custom domain needed).
# dns_label creates a free Azure subdomain: <label>.<region>.cloudapp.azure.com
# cert-manager issues and renews the TLS cert automatically via HTTP-01 ACME challenge.
ingress_controller     = "nginx"
dns_label        = "langsmith-demo"    # FILL IN: → langsmith-demo.eastus.cloudapp.azure.com
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"   # FILL IN: for Let's Encrypt notifications

# ── LangSmith namespace ─────────────────────────────────────────────────────────
langsmith_namespace    = "langsmith"
langsmith_release_name = "langsmith"

# ── Sizing + addon flags ────────────────────────────────────────────────────────
sizing_profile = "minimum"   # absolute minimum resources for demo/POC
```

**Why is `identifier` important?**
Every Azure resource name is derived from it: `langsmith-rg-demo`, `langsmith-aks-demo`, `langsmith-kv-demo`, etc. Key Vault names must be globally unique across all of Azure (not just your subscription) — if the name is taken, Terraform will fail at the Key Vault step. If that happens, use a more unique identifier (e.g. your initials + a number: `-dz01`).

---

### 1b — Bootstrap secrets

`setup-env.sh` handles all sensitive values — passwords, license keys, and auto-generated cryptographic keys. **Never put secrets directly in `terraform.tfvars`.**

```bash
cd terraform/azure
make setup-env
```

**On first run**, the script:
1. Prompts for: PostgreSQL admin password, LangSmith license key, admin password, admin email
2. Generates (or reads from local fallback files): API key salt, JWT secret, 4 Fernet encryption keys
3. Writes everything to `secrets.auto.tfvars` (automatically picked up by Terraform, chmod 600, gitignored)

**On subsequent runs** (after `terraform apply` has created Key Vault):
1. Reads all secrets silently from Key Vault — no prompts
2. Re-writes `secrets.auto.tfvars` from Key Vault values
3. Ensures Terraform state stays consistent across machines

```
LangSmith — secret bootstrap
  identifier : -demo
  key_vault  : langsmith-kv-demo

PostgreSQL admin password  : ****
LangSmith license key      : ****
LangSmith admin password   : ****
Initial org admin email    : you@example.com

  Resolving stable secrets...
  Generated langsmith-api-key-salt → .api_key_salt (Terraform stores in Key Vault on apply)
  Generated langsmith-jwt-secret → .jwt_secret (Terraform stores in Key Vault on apply)
  Generated langsmith-deployments-encryption-key → .deployments_key (...)
  ...

  Wrote secrets.auto.tfvars (chmod 600)
```

> **Important:** The script uses environment variable overrides to skip prompts. If you need to run non-interactively (CI/CD), set: `LANGSMITH_PG_PASSWORD`, `LANGSMITH_LICENSE_KEY`, `LANGSMITH_ADMIN_PASSWORD`, `LANGSMITH_ADMIN_EMAIL` before running the script.

---

### 1c — Terraform init and apply

```bash
cd terraform/azure

# First run only — downloads provider plugins (~300 MB)
make init

# Apply — creates all Azure resources
# Note: make plan fails on a fresh deploy (no cluster yet for kubernetes_manifest).
# Run apply directly — it handles the ordering in three targeted stages automatically.
# Light deploy takes 8–12 minutes (dominated by AKS cluster provisioning).
make apply
```

Type `yes` when prompted (or use `-auto-approve` if you prefer).

**Expected output (successful apply):**
```
Apply complete! Resources: 41 added, 0 changed, 0 destroyed.

Outputs:
aks_cluster_name                         = "langsmith-aks-demo"
get_credentials_command                  = "az aks get-credentials --resource-group langsmith-rg-demo --name langsmith-aks-demo --overwrite-existing"
keyvault_name                            = "langsmith-kv-demo"
keyvault_uri                             = "https://langsmith-kv-demo.vault.azure.net/"
langsmith_admin_email                    = "you@example.com"
langsmith_namespace                      = "langsmith"
langsmith_url                            = "No domain configured — set dns_label or langsmith_domain in terraform.tfvars"
resource_group_name                      = "langsmith-rg-demo"
storage_account_name                     = "langsmithblobdemo"
storage_container_name                   = "langsmithblobdemo-container"
storage_account_k8s_managed_identity_client_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

> The `langsmith_url = "No domain configured"` output is expected at this stage. You don't have the NGINX IP yet. This gets fixed after Pass 1.5.

**What was created:**
| Resource | Name pattern | Purpose |
|---|---|---|
| Resource group | `langsmith-rg<id>` | Container for all resources |
| VNet | `langsmith-vnet<id>` | AKS subnet only (no Postgres/Redis subnets in in-cluster mode) |
| AKS cluster | `langsmith-aks<id>` | Kubernetes cluster, OIDC+Workload Identity enabled |
| Managed Identity | `k8s-app-identity` | Used by pods for blob storage access |
| Federated credential | (on the MI) | OIDC trust: pod SA → Azure MI |
| Storage account | `langsmithblob<id>` | Blob storage for trace payloads |
| Blob container | `langsmithblob<id>-container` | Container within storage account |
| Key Vault | `langsmith-kv<id>` | All secrets, 10 entries |
| cert-manager | in `cert-manager` ns | Helm release, manages TLS certs |
| KEDA | in `keda` ns | Helm release, pod autoscaler |
| NGINX | in `ingress-nginx` ns | Helm release, ingress + Load Balancer |
| Namespace | `langsmith` | LangSmith workloads namespace |
| ServiceAccount | `langsmith-ksa` | Annotated with MI client ID for Workload Identity |

**Troubleshooting common apply failures:**

| Error | Cause | Fix |
|---|---|---|
| `KeyVault name 'langsmith-kv-demo' is already in use` | Name taken by another subscription (KV names are globally unique) | Change `identifier` or set `keyvault_name = "my-unique-kv-name"` in tfvars |
| `AuthorizationFailed` on role assignment | Missing User Access Administrator role | Get Owner or User Access Admin on the subscription |
| `QuotaExceeded` for Standard_DS4_v2 | vCPU quota too low | File a quota increase in the Azure portal for the region |
| `InvalidResourceReference` on VNet/subnet | Race condition | Re-run `terraform apply` — Terraform usually resolves on retry |
| Timeout on cert-manager or KEDA | Slow image pull | Re-run `terraform apply` — Helm releases are idempotent |

---

## Pass 1.5 — Cluster Access

### Get credentials

```bash
cd terraform/azure
make kubeconfig
```

This runs `az aks get-credentials` using the cluster name and resource group from `terraform output`. It sets the current context to the cluster.

### Verify cluster is healthy

```bash
kubectl get nodes
# Expected: 1-3 nodes in Ready state

kubectl get pods -n cert-manager
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook — all Running

kubectl get pods -n keda
# Expected: keda-operator, keda-operator-metrics-apiserver — all Running

kubectl get pods -n ingress-nginx
# Expected: ingress-nginx-controller-xxxxx — Running
```

> **NGINX EXTERNAL-IP:** The Load Balancer IP is provisioned by AKS when the NGINX Helm release is deployed (Pass 1). If `kubectl get svc ingress-nginx-controller -n ingress-nginx` shows `<pending>` for EXTERNAL-IP, wait 1–2 minutes and retry. If it stays pending beyond 5 minutes, run `kubectl describe svc ingress-nginx-controller -n ingress-nginx` and check Events.

### DNS label assignment

The `service.beta.kubernetes.io/azure-dns-label-name` annotation is set on the NGINX LoadBalancer service automatically during `make deploy` (Pass 2). You do not need to set it manually. Once set, Azure assigns the `<dns_label>.<region>.cloudapp.azure.com` subdomain to the public IP within 1–2 minutes.

---

## Pass 1.6 — TLS ClusterIssuer

> **Handled automatically by `make deploy`.** The `letsencrypt-prod` ClusterIssuer is created by `helm/scripts/deploy.sh` using `kubectl apply`, after the cluster is up. No manual step needed.

`make deploy` creates it idempotently — if it already exists, it is skipped. To verify after `make deploy` runs:

```bash
kubectl get clusterissuer letsencrypt-prod
# Expected:
# NAME               READY   AGE
# letsencrypt-prod   True    1m
```

> **Why not Terraform?** `kubernetes_manifest` requires a live Kubernetes API connection during `terraform plan`. On a fresh deploy the cluster doesn't exist yet, so the resource blocks the entire apply. `deploy.sh` runs after the cluster is up, so `kubectl apply` works reliably.

---

## Pass 2 — Deploy LangSmith

All three steps run from `terraform/azure/`:

### 2a — Write application secrets to K8s

Reads all secrets from Key Vault and creates `langsmith-config-secret` in the `langsmith` namespace:

```bash
make k8s-secrets
```

Expected output:
```
  ✔  Reading secrets from Key Vault: langsmith-kv-demo
  ✔  langsmith-config-secret applied to namespace/langsmith
  ✔  8 keys present — ready for Helm install
```

> If any key shows `✗`, re-run `make setup-env` and then `make apply` to ensure Key Vault is populated.

### 2b — Generate Helm values

Reads all Terraform outputs and generates `helm/values/values-overrides.yaml`:

```bash
make init-values
```

This populates all placeholders (hostname, storage account, workload identity client ID, namespace, etc.) from `terraform output` — no manual editing needed.

### 2c — Deploy via Helm

```bash
make deploy
```

This runs:
1. `preflight-check.sh` — verifies kubectl/helm/az/terraform are present and cluster is reachable
2. Sets the `service.beta.kubernetes.io/azure-dns-label-name` annotation on the NGINX LoadBalancer service so Azure assigns the free DNS subdomain
3. `helm upgrade --install langsmith langsmith/langsmith` with the generated values, `--wait --timeout 20m`

**Expected output on success:**
```
Release "langsmith" has been upgraded. Happy Helming!
NAME: langsmith
LAST DEPLOYED: Tue Mar 24 12:34:56 2026
NAMESPACE: langsmith
STATUS: deployed
REVISION: 1
```

With all DBs in-cluster, first install takes 8–12 minutes — Postgres, Redis, and ClickHouse must initialize before the migration jobs can run. If `--wait` times out, the install is not rolled back — check pod status with `make status`.

---

## Known Issue — ch-migrations Job Fails in In-Cluster Mode

### What happens

After Helm install completes (or while `--wait` is running), the `backend-ch-migrations` job pod fails with:

```
Error from server: secret "langsmith-postgres-secret" not found
```

Then retries and fails with:
```
Error from server: secret "langsmith-redis-secret" not found
```

### Why it happens

The `backend-ch-migrations` job in chart 0.13.29 (and likely adjacent versions) references `langsmith-postgres-secret` and `langsmith-redis-secret` by those hardcoded names regardless of whether external or in-cluster mode is configured. In external mode, Terraform creates these secrets. In in-cluster mode, the chart creates `langsmith-postgres` and `langsmith-redis` (without the `-secret` suffix), so the migration job can't find them.

This is a chart-level bug — the migration job should use the chart-managed connection values when in-cluster mode is selected.

### Fix — create alias secrets

Read the actual secret names that the chart created and create aliases under the names the job expects:

```bash
# Step 1 — see what secrets exist in the namespace
kubectl --context langsmith-<identifier-suffix> get secrets -n langsmith

# You should see:
# langsmith-postgres   (created by Helm, holds the in-cluster PG connection URL)
# langsmith-redis      (created by Helm, holds the in-cluster Redis connection URL)

# Step 2 — extract the connection URLs from the chart-created secrets
PG_CONN_URL=$(kubectl --context langsmith-<identifier-suffix> \
  get secret langsmith-postgres -n langsmith \
  -o jsonpath='{.data.connection_url}' | base64 -d)

REDIS_CONN_URL=$(kubectl --context langsmith-<identifier-suffix> \
  get secret langsmith-redis -n langsmith \
  -o jsonpath='{.data.connection_url}' | base64 -d)

# Verify they are not empty
echo "PG:    $PG_CONN_URL"
echo "Redis: $REDIS_CONN_URL"

# Step 3 — create alias secrets with the names the job expects
# --dry-run=client -o yaml | kubectl apply  makes this idempotent (safe to re-run)
kubectl --context langsmith-<identifier-suffix> create secret generic langsmith-postgres-secret \
  --namespace langsmith \
  --from-literal=connection_url="$PG_CONN_URL" \
  --dry-run=client -o yaml | kubectl --context langsmith-<identifier-suffix> apply -f -

kubectl --context langsmith-<identifier-suffix> create secret generic langsmith-redis-secret \
  --namespace langsmith \
  --from-literal=connection_url="$REDIS_CONN_URL" \
  --dry-run=client -o yaml | kubectl --context langsmith-<identifier-suffix> apply -f -

# Step 4 — delete the stuck/failed pod so the job controller creates a new one
kubectl --context langsmith-<identifier-suffix> \
  delete pod -n langsmith -l job-name=langsmith-backend-ch-migrations

# Step 5 — watch the job complete (takes ~30 seconds)
kubectl --context langsmith-<identifier-suffix> \
  get pods -n langsmith -w | grep ch-migrations
# Expected: pod transitions from Pending → Running → Completed
```

> **When does this apply?** Only on first install. After the migration job completes, the alias secrets persist and subsequent Helm upgrades work without this step.

---

## Pass 2.g — Verify Deployment

The fastest check is:

```bash
make status
```

This runs a 9-section health check: Terraform outputs, cluster connectivity, node readiness, bootstrap component pods, LangSmith pods, Helm release status, ingress/TLS, Key Vault secret count, and `langsmith-config-secret` key count. It prints `✔ All checks passed` at the end if everything is healthy.

For detailed pod/ingress output:

```bash
# All LangSmith pods — expect all Running or Completed, 0 failed
kubectl get pods -n langsmith

# Expected (13 pods total with in-cluster DBs):
# NAME                                          READY   STATUS      RESTARTS
# langsmith-ace-backend-xxxxx                   1/1     Running     0
# langsmith-backend-xxxxx                       1/1     Running     0
# langsmith-backend-auth-bootstrap-xxxxx        0/1     Completed   0
# langsmith-backend-ch-migrations-xxxxx         0/1     Completed   0
# langsmith-backend-migrations-xxxxx            0/1     Completed   0
# langsmith-clickhouse-0                        1/1     Running     0
# langsmith-frontend-xxxxx                      1/1     Running     0
# langsmith-platform-backend-xxxxx              1/1     Running     0
# langsmith-playground-xxxxx                    1/1     Running     0
# langsmith-postgres-0                          1/1     Running     0
# langsmith-queue-xxxxx                         1/1     Running     0
# langsmith-redis-0                             1/1     Running     0

# Ingress — expect host = <dns_label>.<region>.cloudapp.azure.com
kubectl get ingress -n langsmith
# NAME                CLASS   HOSTS                                           ADDRESS         PORTS
# langsmith-ingress   nginx   langsmith-demo.eastus.cloudapp.azure.com        52.x.x.x        80, 443

# TLS certificate — expect READY: True (may take 2-3 min after DNS label is assigned)
kubectl get certificate -n langsmith
# NAME            READY   SECRET          AGE
# langsmith-tls   True    langsmith-tls   5m
```

> If certificate shows `READY: False` after 5 minutes:
> ```bash
> kubectl describe certificate langsmith-tls -n langsmith
> kubectl get challenges -n langsmith   # active ACME challenges
> kubectl logs -n cert-manager deploy/cert-manager | tail -30
> # Most common cause: DNS label not yet propagated — wait 2 more minutes
> ```

**Accessing LangSmith:**
```
URL:      https://<dns_label>.<region>.cloudapp.azure.com
Login:    the initialOrgAdminEmail you set in setup-env.sh
Password: az keyvault secret show --vault-name langsmith-kv<identifier> \
            --name langsmith-admin-password --query value -o tsv
```

Open the URL in a browser. Accept the EULA and you will land on the LangSmith dashboard.

---

## Troubleshooting

### Pods stuck in Pending

```bash
kubectl --context langsmith-<identifier-suffix> describe pod <pod-name> -n langsmith
# Look for "Events" at the bottom
```

Common causes:
- **Insufficient CPU/memory:** Node pool has no capacity. Check `kubectl --context ... get nodes` — if only 1 node and it's full, wait for autoscaler to add a node (1-2 min). Max nodes is controlled by `default_node_pool_max_count` in tfvars.
- **PVC not bound:** ClickHouse, Postgres, Redis use PersistentVolumeClaims. Check: `kubectl --context ... get pvc -n langsmith`. If `Pending`, check storage class availability.

### Platform-backend restarts (RESTARTS > 0)

This is normal. `platform-backend` connects to Postgres at startup and may restart 1-2 times before the in-cluster Postgres pod fully initializes. If restarts exceed 5, check its logs:
```bash
kubectl --context langsmith-<identifier-suffix> logs -n langsmith deploy/langsmith-platform-backend --previous
```

### TLS certificate not issuing

```bash
# Check the ACME challenge — cert-manager creates a temporary Ingress for HTTP-01
kubectl --context langsmith-<identifier-suffix> get challenges -n langsmith
kubectl --context langsmith-<identifier-suffix> describe challenge -n langsmith

# Common issue: NGINX is not responding to HTTP on port 80
# Verify the ingress has an address:
kubectl --context langsmith-<identifier-suffix> get ingress -n langsmith
# If ADDRESS is empty, NGINX hasn't received the IP yet — wait longer
```

### Azure CLI errors on secret fetch

```bash
# If az keyvault secret show fails:
az account show   # verify still logged in
az keyvault show --name langsmith-kv-demo   # verify KV exists

# If you get access denied:
# Your account needs "Key Vault Secrets User" or "Key Vault Secrets Officer" on the KV.
# Terraform grants this automatically via the keyvault module.
# If missing: az keyvault set-policy --name langsmith-kv-demo --upn you@email.com --secret-permissions get list
```

---

## Teardown

Run these steps in order. Each step cleans up a layer — Helm first, then namespace, then Azure infra, then local config.

```bash
cd terraform/azure

# 1. Uninstall the LangSmith Helm release
#    Removes all pods, services, PVCs (and in-cluster DB data), ConfigMaps, secrets managed by Helm.
make uninstall

# 2. Destroy all Azure infrastructure
#    Deletes: AKS cluster, VNet, Blob storage, Key Vault, Managed Identity, resource group.
#    Takes 5–10 minutes. Type 'yes' when prompted.
make destroy

# 3. Remove local secrets and generated files
make clean

# 4. Remove the kubeconfig context (optional cleanup)
#    Without this, the dead cluster context stays in your kubeconfig permanently.
kubectl config delete-context langsmith-<identifier-suffix>
kubectl config delete-cluster langsmith-aks<identifier>
kubectl config delete-user clusterUser_langsmith-rg<identifier>_langsmith-aks<identifier>
```

> **Key Vault soft-delete:** Even with `purge_protection = false`, Azure applies a 7-day soft-delete retention on Key Vault. If `terraform destroy` fails on the Key Vault resource, wait a minute and retry. If you need to immediately reuse the same Key Vault name, purge it manually: `az keyvault purge --name langsmith-kv<identifier>`.

> **Data loss:** All in-cluster DB data (Postgres, Redis, ClickHouse) is deleted with the PVCs in step 1. There is no recovery path — this is expected for demo/POC deployments.

---

## Verified Working Output (2026-03-29)

Deployment: identifier `-dzlight`, chart 0.13.35, AKS 1.32.11, eastus, Standard_DS4_v2 × 2 nodes (autoscaled to 3), `dns_label = "langsmith-dzlight"`, Let's Encrypt HTTP-01 prod TLS. All in-cluster DBs.

**Apply output:**
```
Apply complete! Resources: 41 added, 0 changed, 0 destroyed.

Outputs:
  aks_cluster_name     = "langsmith-aks-dzlight"
  keyvault_name        = "langsmith-kv-dzlight"
  resource_group_name  = "langsmith-rg-dzlight"
  storage_account_name = "langsmithblobdzlight"
  langsmith_url        = "https://langsmith-dzlight.eastus.cloudapp.azure.com"
```

**Pods:**
```
NAME                                         READY   STATUS      RESTARTS   AGE
langsmith-ace-backend-79745bd595-bg92c       1/1     Running     0          2m
langsmith-backend-856949d7d5-29dq2           1/1     Running     1          2m
langsmith-backend-auth-bootstrap-xzmrf       0/1     Completed   0          2m
langsmith-backend-ch-migrations-2frj5        0/1     Completed   0          2m
langsmith-backend-migrations-5bc62           0/1     Completed   0          2m
langsmith-clickhouse-0                       1/1     Running     0          2m
langsmith-frontend-694677f76f-qr9lg          1/1     Running     0          2m
langsmith-ingest-queue-7dd7f7b69d-54ccs      1/1     Running     1          2m
langsmith-platform-backend-d49657bb4-8hv9f   1/1     Running     2          2m
langsmith-playground-676989c855-lfl2q        1/1     Running     0          2m
langsmith-postgres-0                         1/1     Running     0          2m
langsmith-queue-7499799fbf-nt5mm             1/1     Running     0          2m
langsmith-redis-0                            1/1     Running     0          2m
```

**Ingress:**
```
NAME                CLASS   HOSTS                                          ADDRESS        PORTS
langsmith-ingress   nginx   langsmith-dzlight.eastus.cloudapp.azure.com   4.156.189.14   80, 443
```

**TLS certificate:**
```
NAME            READY   SECRET          AGE
langsmith-tls   True    langsmith-tls   2m
```

**Access URL:** `https://langsmith-dzlight.eastus.cloudapp.azure.com`
