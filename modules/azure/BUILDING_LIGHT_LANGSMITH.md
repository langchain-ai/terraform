# LangSmith Azure — Light Deploy (All In-Cluster DBs)

> **Tested and verified: 2026-03-23** — chart 0.13.29, AKS 1.32, eastus, all in-cluster DBs, NGINX + Let's Encrypt HTTP-01 TLS, sslip.io hostname. All pods Running/Completed.

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
| TLS | cert-manager + Let's Encrypt | HTTP-01 challenge via NGINX, free auto-renewing cert |
| Hostname | `<nginx-ip>.sslip.io` | No DNS registration needed — sslip.io maps IP to hostname automatically |

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
Internet
   │  HTTPS (443)
   ▼
sslip.io DNS   (e.g. 57-151-68-189.sslip.io → 57.151.68.189)
   │
   ▼
Azure Load Balancer (public IP provisioned by AKS for NGINX)
   │
   ▼
NGINX Ingress Controller  (installed by Terraform via Helm in k8s-cluster module)
   │  routes + terminates TLS
   ▼
LangSmith frontend pod (ClusterIP service)
   │
LangSmith backend pods ──► In-cluster Postgres (StatefulSet)
                       ──► In-cluster Redis    (StatefulSet)
                       ──► In-cluster ClickHouse (StatefulSet)
                       ──► Azure Blob Storage  (via Workload Identity, no static key)

cert-manager  ──► Let's Encrypt (HTTP-01 challenge through NGINX)
              ──► Writes TLS cert to K8s secret langsmith-tls

Key Vault ──► Stores: license key, admin password, JWT secret, API salt, Fernet keys
          ──► create-k8s-secrets.sh reads from KV → writes langsmith-config-secret
```

### Why sslip.io?
`sslip.io` is a free public DNS service that maps IP-based hostnames to their IP. The name `57-151-68-189.sslip.io` resolves to `57.151.68.189`. This means:
- No DNS registration needed
- Let's Encrypt can issue a trusted certificate for it (HTTP-01 challenge works)
- You get a real HTTPS URL for free, instantly

### Why Workload Identity for blob storage?
The LangSmith backend pods write trace payloads to Azure Blob Storage using Azure Workload Identity instead of a static storage account key. Terraform creates a Managed Identity, assigns it `Storage Blob Data Contributor` on the storage account, and federates it to the `langsmith-ksa` Kubernetes Service Account via an OIDC trust relationship. The pods annotate themselves with the MI client ID — the AKS OIDC issuer exchanges the pod's token for a short-lived Azure token. No secrets to rotate, no credentials in the cluster.

---

## Pass 1 — Infrastructure (Terraform)

All Terraform commands run from `terraform/azure/infra/`.

### 1a — Configure terraform.tfvars

Copy the example and fill in your values. The light deploy uses a minimal set of variables — most optional modules are disabled.

```bash
cd terraform/azure/infra
cp terraform.tfvars.example terraform.tfvars
```

**Full `terraform.tfvars` for light deploy — copy this exactly, fill in the two required fields:**

```hcl
# ── Required ───────────────────────────────────────────────────────────────────
subscription_id = ""              # FILL IN: az account show --query id -o tsv
identifier      = "-demo"         # FILL IN: suffix appended to every resource name
                                  # e.g. "-demo", "-smoll", "-dz", "-poc"
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
# nginx = NGINX ingress controller installed via Helm by the k8s-cluster module.
# letsencrypt = cert-manager issues a free certificate via HTTP-01 ACME challenge.
ingress_controller     = "nginx"
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"   # FILL IN: your email for LE notifications

# ── LangSmith namespace ─────────────────────────────────────────────────────────
langsmith_namespace    = "langsmith"
langsmith_release_name = "langsmith"

# ── langsmith_domain — intentionally omitted here ──────────────────────────────
# For sslip.io, the hostname depends on the NGINX external IP, which is only
# assigned after the AKS cluster and Load Balancer are provisioned in Pass 1.
# After Pass 1.5 (cluster access), you will:
#   1. Get NGINX IP: kubectl get svc ingress-nginx-controller -n ingress-nginx
#   2. Derive hostname: HOSTNAME="${NGINX_IP//./-}.sslip.io"
#   3. Append to this file: echo 'langsmith_domain = "X-X-X-X.sslip.io"' >> terraform.tfvars
#   4. Re-run: terraform apply -auto-approve  (only updates the langsmith_url output — no infra changes)
```

**Why is `identifier` important?**
Every Azure resource name is derived from it: `langsmith-rg-demo`, `langsmith-aks-demo`, `langsmith-kv-demo`, etc. Key Vault names must be globally unique across all of Azure (not just your subscription) — if the name is taken, Terraform will fail at the Key Vault step. If that happens, use a more unique identifier (e.g. your initials + a number: `-dz01`).

---

### 1b — Bootstrap secrets

`setup-env.sh` handles all sensitive values — passwords, license keys, and auto-generated cryptographic keys. **Never put secrets directly in `terraform.tfvars`.**

```bash
cd terraform/azure/infra
./setup-env.sh
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
cd terraform/azure/infra

# First run only — downloads provider plugins (~300 MB)
terraform init

# Always preview before applying
terraform plan

# Apply — creates all Azure resources
# Light deploy takes 8-12 minutes (dominated by AKS cluster provisioning)
terraform apply
```

Type `yes` when prompted.

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
langsmith_url                            = "No domain configured — set var.langsmith_domain or var.create_frontdoor = true"
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
# Use a named context to avoid overwriting your default kubeconfig context.
# Replace <identifier-suffix> with the value you set (e.g. "demo" for identifier="-demo").
az aks get-credentials \
  --resource-group langsmith-rg<identifier> \
  --name langsmith-aks<identifier> \
  --context langsmith-<identifier-suffix> \
  --overwrite-existing

# Example with identifier="-demo":
# az aks get-credentials --resource-group langsmith-rg-demo --name langsmith-aks-demo --context langsmith-demo --overwrite-existing
```

> **Why `--context`?** Without it, AKS names the context after the cluster (`langsmith-aks-demo`) and sets it as the current context, which would switch all your future `kubectl` commands to this cluster. Using `--context langsmith-demo` gives it a predictable name you control.

### Verify cluster is healthy

```bash
# All commands below use --context to be explicit
kubectl --context langsmith-<identifier-suffix> get nodes
# Expected: 1-2 nodes in Ready state (autoscaler starts at 1, scales up as pods are scheduled)

kubectl --context langsmith-<identifier-suffix> get pods -n cert-manager
# Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook — all Running (3/3)

kubectl --context langsmith-<identifier-suffix> get pods -n keda
# Expected: keda-operator, keda-operator-metrics-apiserver — all Running

kubectl --context langsmith-<identifier-suffix> get pods -n ingress-nginx
# Expected: ingress-nginx-controller-xxxxx — Running
```

### Wait for NGINX external IP

The NGINX ingress controller creates an Azure Load Balancer to get a public IP. This takes 1-3 minutes after the cluster is ready.

```bash
# Watch until EXTERNAL-IP shows an IP address (not <pending>)
kubectl --context langsmith-<identifier-suffix> get svc ingress-nginx-controller -n ingress-nginx --watch

# Expected output when ready:
# NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
# ingress-nginx-controller   LoadBalancer   10.0.64.x     57.151.68.189   80:30xxx/TCP,443:30xxx/TCP
```

Press `Ctrl+C` once you see the IP.

> If `EXTERNAL-IP` stays as `<pending>` for more than 5 minutes, check:
> ```bash
> kubectl --context langsmith-<identifier-suffix> describe svc ingress-nginx-controller -n ingress-nginx
> # Look for Events — usually indicates a quota issue or subnet exhaustion
> ```

---

## Pass 1.6 — TLS ClusterIssuers

cert-manager needs to know how to request certificates from Let's Encrypt. This is done by creating `ClusterIssuer` resources. Two are created:
- `letsencrypt-staging` — for testing, issues untrusted certs, no rate limits
- `letsencrypt-prod` — trusted by browsers, rate-limited to 5 certs per domain per week

### Verify cert-manager CRDs are ready

```bash
kubectl --context langsmith-<identifier-suffix> get crd clusterissuers.cert-manager.io
# Expected: clusterissuers.cert-manager.io — shows the CRD exists
# If not found, cert-manager is still starting up — wait 30s and retry
```

### Apply the issuers

The issuer YAML is at `helm/values/use-cases/letsencrypt/letsencrypt-issuers.yaml`. It contains a placeholder `ACME_EMAIL_PLACEHOLDER` that must be replaced with your email before applying. The `sed` command does this inline:

```bash
# Run from the azure/infra directory (or adjust the path accordingly)
sed 's/ACME_EMAIL_PLACEHOLDER/you@example.com/g' \
  ../helm/values/use-cases/letsencrypt/letsencrypt-issuers.yaml \
  | kubectl --context langsmith-<identifier-suffix> apply -f -

# Expected output:
# clusterissuer.cert-manager.io/letsencrypt-staging created
# clusterissuer.cert-manager.io/letsencrypt-prod created
```

### Verify issuers are ready

```bash
kubectl --context langsmith-<identifier-suffix> get clusterissuers
# Expected (may take 20-30 seconds to become Ready):
# NAME                  READY   AGE
# letsencrypt-prod      True    30s
# letsencrypt-staging   True    30s
```

If a ClusterIssuer shows `READY: False`, check its status:
```bash
kubectl --context langsmith-<identifier-suffix> describe clusterissuer letsencrypt-prod
# Look for Status.Conditions — usually a network issue reaching Let's Encrypt
```

---

## Pass 2 — Deploy LangSmith

> **Note on `deploy.sh`:** The `infra/scripts/deploy.sh` script is designed for the standard deploy where `langsmith_domain` is set in `terraform.tfvars` before the first apply (DNS-01 or custom domain). For the light sslip.io deploy, the hostname is unknown until the Load Balancer IP is assigned, so `deploy.sh` cannot be used without modification. Pass 2 is done manually here. The steps map 1:1 to what `deploy.sh` does internally.

### 2a — Collect values and derive hostname

Run all of these from `azure/infra/`:

```bash
# Get the NGINX external IP (the one you saw in Pass 1.5)
NGINX_IP=$(kubectl --context langsmith-<identifier-suffix> get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Derive the sslip.io hostname — dots replaced with hyphens
HOSTNAME="${NGINX_IP//./-}.sslip.io"

# Read outputs from Terraform state
KV_NAME=$(terraform output -raw keyvault_name)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
STORAGE_CONTAINER=$(terraform output -raw storage_container_name)
WI_CLIENT_ID=$(terraform output -raw storage_account_k8s_managed_identity_client_id)

# Verify all variables are populated
echo "HOSTNAME:          $HOSTNAME"           # e.g. 57-151-68-189.sslip.io
echo "KV_NAME:           $KV_NAME"            # e.g. langsmith-kv-demo
echo "STORAGE_ACCOUNT:   $STORAGE_ACCOUNT"    # e.g. langsmithblobdemo
echo "STORAGE_CONTAINER: $STORAGE_CONTAINER"  # e.g. langsmithblobdemo-container
echo "WI_CLIENT_ID:      $WI_CLIENT_ID"       # a UUID
```

If any variable is empty, `terraform output -raw` likely failed — verify `terraform apply` completed successfully.

### 2b — Update terraform.tfvars with the hostname

Adding `langsmith_domain` makes the `langsmith_url` output meaningful and ensures future `setup-env.sh` runs and `deploy.sh` invocations can read it:

```bash
echo "langsmith_domain = \"${HOSTNAME}\"" >> terraform.tfvars

# Re-apply — only the langsmith_url output changes, no infrastructure is modified
# (langsmith_domain does not create a DNS zone since create_dns_zone is not set)
terraform apply -auto-approve
# Expected: "Apply complete! Resources: 0 added, 0 changed, 0 destroyed."
# The langsmith_url output now shows: "https://57-151-68-189.sslip.io"
```

### 2c — Prepare Helm values-overrides.yaml

The `values-overrides-demo.yaml.example` is the template for the light deploy. It configures:
- All in-cluster DBs (no `postgres.external` or `redis.external` blocks)
- Lightweight resource requests (suitable for DS4_v2 with all DBs sharing one pool)
- NGINX ingress with Let's Encrypt TLS annotation
- Workload Identity annotations for the 3 pods that need blob storage access

```bash
# Start from the demo template (designed for in-cluster DBs)
cp ../helm/values/values-overrides-demo.yaml.example ../helm/values/values-overrides.yaml

# Fill all placeholders — macOS sed requires '' after -i; Linux does not
# The script below detects OS and uses the right variant
_sed() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

_sed "s|<your-domain.com>|${HOSTNAME}|g"                            ../helm/values/values-overrides.yaml
_sed "s|<admin@example.com>|you@example.com|g"                      ../helm/values/values-overrides.yaml  # CHANGE THIS
_sed "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g"     ../helm/values/values-overrides.yaml
_sed "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g" ../helm/values/values-overrides.yaml
_sed "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g" ../helm/values/values-overrides.yaml

# Verify no placeholders remain (ignoring comments)
echo "--- Checking for remaining placeholders ---"
grep -v '^[[:space:]]*#' ../helm/values/values-overrides.yaml | grep '<' \
  && echo "WARNING: placeholders remain — fix before deploying" \
  || echo "OK: no placeholders"

# Review the final file
cat ../helm/values/values-overrides.yaml
```

**Key sections in the resulting `values-overrides.yaml` and why they matter:**

| Section | What it sets | Why |
|---|---|---|
| `config.hostname` | sslip.io hostname | Used in CORS, cookie domain, and self-referential URLs |
| `config.existingSecretName` | `langsmith-config-secret` | Points all pods to the K8s secret you'll create in 2d |
| `config.blobStorage` | storage account + container | Where trace payloads are stored |
| `backend.serviceAccount.annotations` | workload identity client ID | Binds the pod's SA to the Azure Managed Identity |
| `ingress.annotations` | `cert-manager.io/cluster-issuer: letsencrypt-prod` | Tells cert-manager to issue a cert for this ingress |
| `ingress.tls` | secretName + hosts | cert-manager writes the issued cert here |
| `ingestQueue.enabled: false` | disables ingest queue | Light deploy — the main queue handles ingestion |

### 2d — Create K8s config secret from Key Vault

The `langsmith-config-secret` contains all application-level secrets: license key, admin password, API key salt, JWT secret, and 4 Fernet encryption keys. The LangSmith pods reference this secret via `config.existingSecretName`.

Use the provided script which reads from Key Vault and creates/updates the secret idempotently:

```bash
# Switch context before running the script (the script uses the current context)
kubectl config use-context langsmith-<identifier-suffix>

# Run from azure/infra/
bash scripts/create-k8s-secrets.sh
```

The script will output each Key Vault secret it reads and verify all 8 keys are present:
```
LangSmith — create K8s config secret
  key_vault : langsmith-kv-demo
  namespace : langsmith

  Reading secrets from Key Vault...
  All secrets retrieved.

  Applying langsmith-config-secret to namespace/langsmith...
secret/langsmith-config-secret configured

  Verifying keys in langsmith-config-secret...

  [✓] agent_builder_encryption_key
  [✓] api_key_salt
  [✓] deployments_encryption_key
  [✓] initial_org_admin_password
  [✓] insights_encryption_key
  [✓] jwt_secret
  [✓] langsmith_license_key
  [✓] polly_encryption_key

  All 8 keys present. Ready for helm install.
```

> If any key shows `[✗]`, the Key Vault secret wasn't created by Terraform (unlikely if apply succeeded). Re-run `./setup-env.sh` and then `terraform apply`.

### 2e — Add helm repo and find chart version

```bash
helm repo add langsmith https://langchain-ai.github.io/helm --force-update
helm repo update

# List available versions and pick the latest (or a specific one)
helm search repo langsmith/langsmith --versions | head -10

# Capture the latest version programmatically
CHART_VERSION=$(helm search repo langsmith/langsmith --versions -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['version'])")
echo "Deploying chart version: $CHART_VERSION"
```

### 2f — Deploy LangSmith via Helm

```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version "$CHART_VERSION" \
  --namespace langsmith \
  --create-namespace \
  --kube-context langsmith-<identifier-suffix> \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

**What `--wait --timeout 15m` does:** Helm waits until all Deployment pods are in Ready state and all Job pods have Completed before returning success. With in-cluster DBs, this takes 5-10 minutes on first install (Postgres, Redis, and ClickHouse all need to initialize before the migration jobs can run). If it times out, the install is not rolled back — check pod status manually.

**Expected output on success:**
```
Release "langsmith" has been upgraded. Happy Helming!
NAME: langsmith
LAST DEPLOYED: Mon Mar 23 12:34:56 2026
NAMESPACE: langsmith
STATUS: deployed
REVISION: 1
```

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

```bash
# All LangSmith pods — expect all Running or Completed, 0 failed
kubectl --context langsmith-<identifier-suffix> get pods -n langsmith

# Expected (12 pods total):
# NAME                                          READY   STATUS      RESTARTS
# langsmith-ace-backend-xxxxx                   1/1     Running     0
# langsmith-backend-xxxxx                       1/1     Running     0
# langsmith-backend-auth-bootstrap-xxxxx        0/1     Completed   0
# langsmith-backend-ch-migrations-xxxxx         0/1     Completed   0
# langsmith-backend-migrations-xxxxx            0/1     Completed   0
# langsmith-clickhouse-0                        1/1     Running     0
# langsmith-frontend-xxxxx                      1/1     Running     0
# langsmith-platform-backend-xxxxx             1/1     Running     0
# langsmith-playground-xxxxx                    1/1     Running     0
# langsmith-postgres-0                          1/1     Running     0
# langsmith-queue-xxxxx                         1/1     Running     0
# langsmith-redis-0                             1/1     Running     0

# Ingress — expect host and address to be set
kubectl --context langsmith-<identifier-suffix> get ingress -n langsmith
# NAME                CLASS   HOSTS                    ADDRESS         PORTS
# langsmith-ingress   nginx   57-151-68-189.sslip.io   57.151.68.189   80, 443

# TLS certificate — expect READY: True
kubectl --context langsmith-<identifier-suffix> get certificate -n langsmith
# NAME            READY   SECRET          AGE
# langsmith-tls   True    langsmith-tls   2m

# If certificate shows READY: False after 3 minutes, check cert-manager logs:
kubectl --context langsmith-<identifier-suffix> describe certificate langsmith-tls -n langsmith
kubectl --context langsmith-<identifier-suffix> get certificaterequest -n langsmith
kubectl --context langsmith-<identifier-suffix> logs -n cert-manager deploy/cert-manager | tail -30
```

**Accessing LangSmith:**
```
URL:      https://57-151-68-189.sslip.io    (your sslip.io hostname)
Login:    you@example.com                   (the initialOrgAdminEmail you set)
Password: az keyvault secret show --vault-name langsmith-kv-demo --name langsmith-admin-password --query value -o tsv
```

Open the URL in a browser. The first load may show a brief loading screen while the frontend initializes. Accept the EULA and you will land on the LangSmith dashboard.

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
# 1. Uninstall the LangSmith Helm release
#    Removes all pods, services, PVCs (and in-cluster DB data), ConfigMaps, secrets managed by Helm.
#    --wait blocks until all resources are deleted before returning.
helm uninstall langsmith -n langsmith \
  --kube-context langsmith-<identifier-suffix> \
  --wait

# 2. Delete the namespace
#    Catches any leftover resources not owned by Helm (e.g. manually created secrets, jobs).
kubectl --context langsmith-<identifier-suffix> \
  delete namespace langsmith --timeout=60s

# 3. Destroy all Azure infrastructure
#    Deletes: AKS cluster, VNet, Blob storage, Key Vault, Managed Identity, resource group.
#    Takes 5-10 minutes. Type 'yes' when prompted.
cd terraform/azure/infra
terraform destroy

# 4. Remove the kubeconfig context (optional cleanup)
#    Without this, the dead cluster context stays in your kubeconfig permanently.
kubectl config delete-context langsmith-<identifier-suffix>
kubectl config delete-cluster langsmith-aks<identifier>
kubectl config delete-user clusterUser_langsmith-rg<identifier>_langsmith-aks<identifier>
```

> **Key Vault soft-delete:** Even with `purge_protection = false`, Azure applies a 7-day soft-delete retention on Key Vault. If `terraform destroy` fails on the Key Vault resource, wait a minute and retry. If you need to immediately reuse the same Key Vault name, purge it manually: `az keyvault purge --name langsmith-kv<identifier>`.

> **Data loss:** All in-cluster DB data (Postgres, Redis, ClickHouse) is deleted with the PVCs in step 1. There is no recovery path — this is expected for demo/POC deployments.

---

## Verified Working Output (2026-03-23)

Deployment: chart 0.13.29, AKS 1.32.11, eastus, Standard_DS4_v2 × 1 node (autoscaled), sslip.io + Let's Encrypt prod TLS.

**Pods:**
```
NAME                                          READY   STATUS      RESTARTS   AGE
langsmith-ace-backend-85c5c88f5f-klmd8        1/1     Running     0          8m
langsmith-backend-78957f7fd6-bszfl            1/1     Running     0          8m
langsmith-backend-auth-bootstrap-7z959        0/1     Completed   0          8m
langsmith-backend-ch-migrations-d8bb2         0/1     Completed   0          6m
langsmith-backend-migrations-qbwr9            0/1     Completed   0          8m
langsmith-clickhouse-0                        1/1     Running     0          8m
langsmith-frontend-bb87c459d-cmhdh            1/1     Running     0          8m
langsmith-platform-backend-78f968fbdd-6w6c9   1/1     Running     2          8m
langsmith-playground-6cdcb756dc-6z92d         1/1     Running     0          8m
langsmith-postgres-0                          1/1     Running     0          8m
langsmith-queue-9ff776fff-tvqzh               1/1     Running     0          8m
langsmith-redis-0                             1/1     Running     0          8m
```

**Ingress:**
```
NAME                CLASS   HOSTS                    ADDRESS         PORTS
langsmith-ingress   nginx   57-151-68-189.sslip.io   57.151.68.189   80, 443
```

**TLS certificate:**
```
NAME            READY   SECRET          AGE
langsmith-tls   True    langsmith-tls   5m
```

**Access URL:** `https://57-151-68-189.sslip.io`
