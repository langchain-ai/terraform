# LangSmith Azure — Quick Reference

Copy-paste commands for each deployment pass. **All commands run from `terraform/azure/infra/`** unless noted.

---

## Choose Your Path

Pick one before you start. Both use the same Terraform module — only the variables differ.

| Path | `ingress_controller` | TLS | Multi-dataplane | Cost add |
|---|---|---|---|---|
| **A — Standard** (most customers) | `nginx` | Front Door Standard | No | ~$35/mo |
| **B — Multi-dataplane / Istio** | `istio-addon` | Front Door Standard | Yes | ~$35/mo |

**Front Door is the recommended TLS path for both.** It handles managed certificates automatically — no cert-manager configuration, no Azure DNS zone required. Works the same way regardless of which ingress controller is running.

> **Advanced TLS option:** DNS-01 + cert-manager (cert lives on-cluster, no CDN cost). See [Pass 1.6 Advanced — DNS-01](#pass-16-advanced--tls-dns-01--cert-manager) if you need this.

> **Dev/POC (no domain, all in-cluster DBs):** see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md).

---

## Prerequisites

Before running anything, confirm these are in place:

```bash
# Azure CLI — must be logged in to the right subscription
az account show                          # verify login
az account show --query id -o tsv        # copy your subscription ID

# Tools
kubectl version --client                 # must be installed
helm version                             # must be installed
terraform version                        # must be ≥ 1.5
```

**Required RBAC roles on your subscription:**
- `Contributor` — creates all Azure resources
- `User Access Administrator` — assigns IAM roles (Managed Identity, DNS Zone Contributor)

Check your roles:
```bash
az role assignment list --assignee $(az account show --query user.name -o tsv) \
  --scope /subscriptions/$(az account show --query id -o tsv) \
  --query "[].roleDefinitionName" -o tsv
```

**Domain name required for production TLS.** You need a domain (or subdomain) you control — e.g. `langsmith.example.com`. Front Door will issue a managed certificate for it. You will add two DNS records at your registrar (CNAME + TXT) in Pass 1.6.

**Network egress required** — LangSmith pods must be able to reach `https://beacon.langchain.com` for license validation. If your cluster has restrictive egress rules or firewall policies, add an allow rule for this endpoint before deploying.

---

## Quick Start

End-to-end walkthrough for **Path A (NGINX + Front Door)**. If you are following Path B, set `ingress_controller = "istio-addon"` in step 2 — everything else is identical.

> **Total time:** ~30–35 min (AKS ~12 min, PostgreSQL ~5 min, Front Door cert issuance ~5–15 min, Helm ~5 min)

---

### Step 0 — Run preflight checks

Catches missing az login, unregistered resource providers, missing RBAC roles, and incomplete config before anything is created.

```bash
cd terraform/azure/infra
./scripts/preflight.sh
```

All checks must pass before continuing. Fix any `[✗]` items — they will cause `terraform apply` to fail.

---

### Step 1 — Copy and configure terraform.tfvars

```bash
cd terraform/azure/infra
cp terraform.tfvars.example terraform.tfvars
```

Fill in the values below. Everything else in the example file can stay as-is for your first deployment:

```hcl
# ── Required ──────────────────────────────────────────────────────────────────
subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # az account show --query id -o tsv
identifier      = "-prod"           # suffix for all resource names: langsmith-aks-prod, etc.
location        = "eastus"          # Azure region
environment     = "prod"

# ── Compute ───────────────────────────────────────────────────────────────────
# Medium load (1 Control Plane + 3 Dataplanes): 10× Standard_D8s_v3 recommended
default_node_pool_vm_size   = "Standard_D8s_v3"   # 8 vCPU, 32 GiB
default_node_pool_max_count = 12                   # 10 target + 2 headroom

additional_node_pools = {
  large = {
    vm_size   = "Standard_D16s_v3"   # 16 vCPU, 64 GiB — for ClickHouse
    min_count = 0
    max_count = 2
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────
postgres_source   = "external"    # Azure DB for PostgreSQL Flexible Server
redis_source      = "external"    # Azure Cache for Redis Premium
clickhouse_source = "in-cluster"  # ClickHouse always in-cluster (dev/POC)
                                  # Production: use LangChain Managed ClickHouse

# ── Ingress ───────────────────────────────────────────────────────────────────
ingress_controller = "nginx"      # Path A — change to "istio-addon" for Path B

# ── TLS via Azure Front Door ───────────────────────────────────────────────────
# Front Door issues a managed TLS certificate for your domain automatically.
# No cert-manager setup needed — just add two DNS records at your registrar (Step 7).
langsmith_domain  = "langsmith.example.com"   # subdomain you control
create_frontdoor  = true
# frontdoor_origin_hostname = ""              # fill after Step 6 (get ingress IP)

# ── PostgreSQL ────────────────────────────────────────────────────────────────
postgres_admin_username = "langsmith"
postgres_database_name  = "langsmith"

# ── Key Vault ─────────────────────────────────────────────────────────────────
keyvault_purge_protection = false   # set true for production
```

> **What is `identifier`?** It is appended to every Azure resource name to distinguish deployments in the same subscription. `-prod` gives you `langsmith-aks-prod`, `langsmith-rg-prod`, etc. Use `-staging` for staging, `-dz` for personal dev.

---

### Step 2 — Bootstrap secrets

`setup-env.sh` keeps credentials out of `terraform.tfvars` and shell history. It writes a `secrets.auto.tfvars` file (gitignored, `chmod 600`) that Terraform picks up automatically.

```bash
bash setup-env.sh
```

**On first run it prompts for three values:**

| Prompt | What to enter |
|---|---|
| `PostgreSQL admin password` | Password for the Azure DB for PostgreSQL admin user — you choose it |
| `LangSmith license key` | Your LangSmith enterprise license key from LangChain |
| `LangSmith admin password` | Password for the first org admin account created on first boot |

**Everything else is generated automatically** — JWT secret, API key salt, and four Fernet encryption keys. These are stable: generated once, stored in Azure Key Vault after Pass 1, and read from Key Vault on every subsequent `bash setup-env.sh` run.

```
LangSmith — secret bootstrap
  identifier : -prod
  key_vault  : langsmith-kv-prod

  Resolving stable secrets...
  Generated langsmith-api-key-salt      → .api_key_salt
  Generated langsmith-jwt-secret        → .jwt_secret
  Generated langsmith-deployments-encryption-key → .deployments_key
  ...

  Wrote secrets.auto.tfvars (chmod 600)
```

> **Never commit `secrets.auto.tfvars`.** The `.gitignore` blocks it, but verify with `git status` before committing anything.

On a new machine or CI, run `bash setup-env.sh` again — it reads from Key Vault silently and regenerates `secrets.auto.tfvars`. No prompts needed after the first run.

---

### Step 3 — Initialize Terraform (first run only)

```bash
terraform init
```

Expected output:
```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 3.0"...
- Finding hashicorp/kubernetes versions matching "~> 2.0"...
...
Terraform has been successfully initialized!
```

---

### Step 4 — Preview and apply infrastructure (~20 min)

```bash
terraform plan    # review the plan — no changes made
terraform apply   # confirm with "yes" when prompted
```

**What `terraform apply` creates (~70 resources):**

| Resource | Name | Notes |
|---|---|---|
| Resource group | `langsmith-rg<id>` | Container for all resources |
| VNet + 3 subnets | `langsmith-vnet<id>` | AKS / PostgreSQL / Redis subnets |
| AKS cluster | `langsmith-aks<id>` | OIDC + Workload Identity enabled |
| NGINX ingress | via Helm | LoadBalancer service gets public IP |
| PostgreSQL Flexible Server | `langsmith-postgres<id>` | Private subnet, VNet-linked DNS |
| Redis Premium | `langsmith-redis<id>` | Private subnet |
| Blob storage | `langsmithblob<id>` | Managed Identity + federated creds |
| Key Vault | `langsmith-kv<id>` | All secrets stored here |
| Front Door profile | `langsmith-fd<id>` | Standard SKU, custom domain configured |
| K8s namespace | `langsmith` | ResourceQuota + NetworkPolicy |
| K8s ServiceAccount | `langsmith-ksa` | Workload Identity annotated |
| cert-manager | v1.x via Helm | Pod identity for DNS-01 (if needed) |
| KEDA | v2.x via Helm | Queue-based autoscaling |

> **AKS takes ~12 min. PostgreSQL takes ~5 min. These run in parallel.** Total apply time is ~15–20 min.

Expected final output:
```
Apply complete! Resources: 70 added, 0 changed, 0 destroyed.

Outputs:

aks_cluster_name                            = "langsmith-aks-prod"
frontdoor_endpoint_hostname                 = "langsmith-fd-prod-xyz123.z01.azurefd.net"
frontdoor_validation_token                  = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
langsmith_url                               = "https://langsmith.example.com"
resource_group_name                         = "langsmith-rg-prod"
keyvault_name                               = "langsmith-kv-prod"
...
```

---

### Step 5 — Configure kubectl

```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name $(terraform output -raw aks_cluster_name) \
  --overwrite-existing
```

Expected:
```
Merged "langsmith-aks-prod" as current context in /Users/<you>/.kube/config
```

Verify nodes are ready:
```bash
kubectl get nodes
```
```
NAME                              STATUS   ROLES    AGE   VERSION
aks-default-xxxxxxxxx-vmss000000  Ready    <none>   8m    v1.32.x
aks-default-xxxxxxxxx-vmss000001  Ready    <none>   8m    v1.32.x
```

---

### Step 6 — Get the ingress IP

The NGINX LoadBalancer gets a public IP from Azure after AKS is ready. This usually takes 2–3 minutes after the cluster finishes provisioning.

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
```
```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)
ingress-nginx-controller   LoadBalancer   10.0.xx.xx    52.x.x.x         80,443
```

> If `EXTERNAL-IP` shows `<pending>`, wait 2–3 minutes and retry.

**For Path B (istio-addon):**
```bash
kubectl get svc -n aks-istio-ingress
```
```
NAME                                TYPE           EXTERNAL-IP
aks-istio-ingressgateway-external   LoadBalancer   52.x.x.x
```

Add the IP to `terraform.tfvars`:
```hcl
frontdoor_origin_hostname = "52.x.x.x"   # paste your EXTERNAL-IP here
```

Then re-apply to wire Front Door to the AKS ingress LB:
```bash
terraform apply
```

---

### Step 7 — Configure DNS at your registrar

After `terraform apply` in Step 4, note these two outputs:

```bash
terraform output frontdoor_endpoint_hostname   # e.g. langsmith-fd-prod-xyz.z01.azurefd.net
terraform output frontdoor_validation_token    # e.g. abc123...
```

Go to your domain registrar (Squarespace, GoDaddy, Cloudflare, Route 53, etc.) and add **two DNS records** for your subdomain:

| Record type | Host | Value | Purpose |
|---|---|---|---|
| `CNAME` | `langsmith` | `frontdoor_endpoint_hostname` | Routes traffic to Front Door |
| `TXT` | `_dnsauth.langsmith` | `frontdoor_validation_token` | Proves domain ownership for managed cert |

> **Example for `langsmith.example.com` at Squarespace:**
> - CNAME: host = `langsmith`, value = `langsmith-fd-prod-xyz.z01.azurefd.net`
> - TXT: host = `_dnsauth.langsmith`, value = `abc123...`

**After saving the records:**
- Azure picks up the TXT record automatically and begins certificate issuance
- No Terraform re-apply needed for cert issuance — it happens asynchronously
- Certificate issuance typically takes 5–15 minutes
- You can track progress: `kubectl get certificate -n langsmith` (if cert-manager cert) or check Front Door portal

> **DNS propagation:** New DNS records propagate in 1–15 minutes with most registrars. If Front Door shows the cert as "pending" after 30 minutes, verify the records are correct with `dig CNAME langsmith.example.com` and `dig TXT _dnsauth.langsmith.example.com`.

---

### Step 8 — Verify cluster health before deploying LangSmith

```bash
# All 3 cert-manager pods should be Running
kubectl get pods -n cert-manager
```
```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxxx-xxxxx              1/1     Running   0          10m
cert-manager-cainjector-xxxxxxxxxx-xxxxx   1/1     Running   0          10m
cert-manager-webhook-xxxxxxxxxx-xxxxx      1/1     Running   0          10m
```

```bash
# All 3 KEDA pods should be Running
kubectl get pods -n keda
```
```
NAME                                              READY   STATUS    RESTARTS   AGE
keda-admission-webhooks-xxxxxxxxxx-xxxxx          1/1     Running   0          10m
keda-operator-xxxxxxxxxx-xxxxx                    1/1     Running   0          10m
keda-operator-metrics-apiserver-xxxxxxxxxx-xxxxx  1/1     Running   0          10m
```

```bash
# Workload Identity annotation on the LangSmith service account
kubectl get sa langsmith-ksa -n langsmith \
  -o jsonpath='{.metadata.annotations}' && echo
```
```
{"azure.workload.identity/client-id":"<managed-identity-client-id>"}
```

```bash
# K8s secrets created by Terraform (postgres + redis connection URLs)
kubectl get secrets -n langsmith
```
```
langsmith-postgres-secret   Opaque   1   10m
langsmith-redis-secret      Opaque   1   10m
```

---

### Step 9 — Deploy LangSmith (Pass 2)

See [Secret Architecture](#secret-architecture--how-secrets-flow) for a full explanation of all three K8s secrets before running this step.

See [Pass 2 — LangSmith (External Postgres + Redis)](#pass-2--langsmith-external-postgres--redis) for the full walkthrough. Quick version:

```bash
# Collect outputs
HOSTNAME=$(terraform output -raw langsmith_url | sed 's|https://||')
KV_NAME=$(terraform output -raw keyvault_name)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
STORAGE_CONTAINER=$(terraform output -raw storage_container_name)
WI_CLIENT_ID=$(terraform output -raw storage_account_k8s_managed_identity_client_id)

# Prepare values file
cp ../helm/values/values-overrides-pass-2.yaml.example ../helm/values/values-overrides.yaml
sed -i '' "s|<your-domain.com>|${HOSTNAME}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g" ../helm/values/values-overrides.yaml
vi ../helm/values/values-overrides.yaml   # set initialOrgAdminEmail

# Create langsmith-config-secret from Key Vault — verifies all 8 keys after creation
./scripts/create-k8s-secrets.sh

# Deploy
helm repo add langsmith https://langchain-ai.github.io/helm && helm repo update
helm search repo langsmith/langsmith --versions | head -5   # pick VERSION

helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> \
  --namespace langsmith --create-namespace \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

---

### Step 10 — Verify LangSmith is running

```bash
kubectl get pods -n langsmith        # all Running or Completed
kubectl get ingress -n langsmith     # host shows your domain, TLS assigned
```

Open `https://langsmith.example.com` — log in with `initialOrgAdminEmail` + admin password from Key Vault.

---

## Makefile Shortcuts

Run from `terraform/azure/`:

```bash
make help        # list all available targets
make preflight   # validate az CLI login, resource providers, RBAC roles, terraform.tfvars
make init        # terraform init
make plan        # terraform plan (sources setup-env.sh automatically)
make apply       # terraform apply — Pass 1 infrastructure
make kubeconfig  # az aks get-credentials (reads cluster/RG names from terraform output)
make deploy      # helm deploy LangSmith — Pass 2
make status      # kubectl get pods/svc/ingress/certificate in langsmith namespace
make destroy     # terraform destroy
```

> Run `make preflight` before `make apply` on a new machine or subscription to catch missing az login, unregistered resource providers, missing RBAC roles, and incomplete `terraform.tfvars` early.

---

## Pass 1 — Infrastructure (detailed)

The Quick Start above covers Pass 1 end-to-end. Use this section for reference when you need details on specific steps.

### Full terraform.tfvars reference

```hcl
# ── Required ──────────────────────────────────────────────────────────────────
subscription_id = ""              # az account show --query id -o tsv
identifier      = "-prod"         # suffix appended to every resource name
location        = "eastus"        # Azure region
environment     = "prod"          # dev | staging | prod

# ── Naming / tagging (optional) ───────────────────────────────────────────────
# owner       = "platform-team"
# cost_center = "engineering"

# ── Data sources ──────────────────────────────────────────────────────────────
postgres_source   = "external"    # Azure DB for PostgreSQL Flexible Server
redis_source      = "external"    # Azure Cache for Redis Premium
clickhouse_source = "in-cluster"  # ClickHouse always in-cluster

# ── AKS sizing — medium load (1 Control Plane + 3 Dataplanes) ─────────────────
default_node_pool_vm_size   = "Standard_D8s_v3"   # 8 vCPU, 32 GiB
default_node_pool_max_count = 12

additional_node_pools = {
  large = {
    vm_size   = "Standard_D16s_v3"   # 16 vCPU, 64 GiB — ClickHouse + agent pods
    min_count = 0
    max_count = 2
  }
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
postgres_admin_username      = "langsmith"
postgres_database_name       = "langsmith"
postgres_deletion_protection = false   # set true for production

# ── Redis ─────────────────────────────────────────────────────────────────────
redis_capacity = 1   # P1 = 6 GB RAM (sufficient for most deployments)

# ── Blob storage ──────────────────────────────────────────────────────────────
blob_ttl_enabled    = true
blob_ttl_short_days = 14    # short-lived trace payloads
blob_ttl_long_days  = 400   # run attachments (~13 months)

# ── Key Vault ─────────────────────────────────────────────────────────────────
keyvault_purge_protection = false   # set true for production

# ── Ingress controller ────────────────────────────────────────────────────────
# Path A: nginx     — NGINX ingress via Helm (standard)
# Path B: istio-addon — Azure managed Istio add-on (multi-dataplane)
# Other:  istio (self-managed Helm), none (bring your own)
ingress_controller = "nginx"

# ── TLS: Azure Front Door (recommended) ───────────────────────────────────────
langsmith_domain          = "langsmith.example.com"
create_frontdoor          = true
# frontdoor_origin_hostname = ""   # set after Step 6 (get ingress IP)
# frontdoor_sku             = "Standard_AzureFrontDoor"  # or Premium for WAF

# ── LangSmith ─────────────────────────────────────────────────────────────────
langsmith_namespace    = "langsmith"
langsmith_release_name = "langsmith"

# ── Optional modules ──────────────────────────────────────────────────────────
# create_diagnostics = true   # Log Analytics + diagnostic settings (recommended for prod)
# create_bastion     = true   # Jump VM for private AKS access
# create_waf         = true   # Azure WAF policy — requires frontdoor_sku = "Premium_AzureFrontDoor"

# ── Multi-AZ (optional) ───────────────────────────────────────────────────────
# availability_zones                 = ["1", "2", "3"]   # zone-redundant HA
# postgres_standby_availability_zone = "2"
# postgres_geo_redundant_backup      = true
```

### 1b — Bootstrap secrets with setup-env.sh

`setup-env.sh` is the only place sensitive values enter the system. It keeps credentials out of `terraform.tfvars` and out of shell history.

**Run it:**
```bash
bash setup-env.sh
```

> **Always use `bash setup-env.sh`, not `./setup-env.sh` or `source setup-env.sh`.** The script uses bash-specific syntax (`${!var}` indirect expansion) that fails silently in zsh, writing empty passwords to `secrets.auto.tfvars` and causing `terraform apply` to fail with empty password errors.

**What it prompts for (first run only):**

| Prompt | What to enter |
|---|---|
| `PostgreSQL admin password` | Password for the Azure DB for PostgreSQL admin user |
| `LangSmith license key` | Your LangSmith enterprise license key from LangChain |
| `LangSmith admin password` | Password for the first org admin account created on first boot |

**What it generates automatically (stable — never rotated):**

| Secret | How generated | Purpose |
|---|---|---|
| `api_key_salt` | `openssl rand -base64 32` | Salts all LangSmith API keys |
| `jwt_secret` | `openssl rand -base64 32` | Signs JWT session tokens |
| `deployments_encryption_key` | Fernet key | Encrypts LangGraph deployment metadata |
| `agent_builder_encryption_key` | Fernet key | Encrypts Agent Builder data |
| `insights_encryption_key` | Fernet key | Encrypts Insights / Clio data |
| `polly_encryption_key` | Fernet key | Encrypts Polly agent data |

**Storage behavior — two phases:**

| Phase | KV exists? | What setup-env.sh does | What terraform apply does |
|---|---|---|---|
| First run | No | Generates secrets → local dot-files + `secrets.auto.tfvars` | Creates KV + stores all secrets in KV |
| Subsequent runs | Yes | Reads secrets from KV → `secrets.auto.tfvars` only | Secrets already in KV state — no-op |

`setup-env.sh` is read-only against Key Vault — Terraform is the sole KV writer. Running `bash setup-env.sh → terraform apply` is always safe to repeat on any machine.

**What `secrets.auto.tfvars` contains** (gitignored, `chmod 600`):
```hcl
# Auto-generated by setup-env.sh — DO NOT COMMIT
postgres_admin_password                = "<your-postgres-password>"
langsmith_license_key                  = "<your-license-key>"
langsmith_admin_password               = "<your-admin-password>"
langsmith_api_key_salt                 = "<generated>"
langsmith_jwt_secret                   = "<generated>"
langsmith_deployments_encryption_key   = "<fernet-key>"
langsmith_agent_builder_encryption_key = "<fernet-key>"
langsmith_insights_encryption_key      = "<fernet-key>"
langsmith_polly_encryption_key         = "<fernet-key>"
```

---

## Pass 1.5 — Cluster Access

```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name $(terraform output -raw aks_cluster_name) \
  --overwrite-existing
```
```
Merged "langsmith-aks-prod" as current context in /Users/<you>/.kube/config
```

```bash
kubectl get nodes
```
```
NAME                              STATUS   ROLES    AGE   VERSION
aks-default-xxxxxxxxx-vmss000000  Ready    <none>   8m    v1.32.x
aks-default-xxxxxxxxx-vmss000001  Ready    <none>   8m    v1.32.x
```

```bash
# Verify NGINX ingress (Path A)
kubectl get svc ingress-nginx-controller -n ingress-nginx
```
```
NAME                       TYPE           EXTERNAL-IP
ingress-nginx-controller   LoadBalancer   52.x.x.x
```

```bash
# Verify Istio ingress (Path B — istio-addon)
kubectl get svc -n aks-istio-ingress
```
```
NAME                                TYPE           EXTERNAL-IP
aks-istio-ingressgateway-external   LoadBalancer   52.x.x.x
```

```bash
# Verify cert-manager
kubectl get pods -n cert-manager
```
```
cert-manager-xxxxxxxxxx-xxxxx              1/1     Running   0   10m
cert-manager-cainjector-xxxxxxxxxx-xxxxx   1/1     Running   0   10m
cert-manager-webhook-xxxxxxxxxx-xxxxx      1/1     Running   0   10m
```

```bash
# Verify KEDA
kubectl get pods -n keda
```
```
keda-admission-webhooks-xxxxxxxxxx-xxxxx          1/1     Running   0   10m
keda-operator-xxxxxxxxxx-xxxxx                    1/1     Running   0   10m
keda-operator-metrics-apiserver-xxxxxxxxxx-xxxxx  1/1     Running   0   10m
```

---

## Pass 1.6 — TLS: Front Door (recommended)

> Front Door Standard is the recommended production TLS path. Managed certificates, no cert-manager setup, no Azure DNS zone required. Works with `nginx`, `istio-addon`, and `istio`.
>
> AWS equivalent: CloudFront + ACM. Cost: ~$35/month base (Standard SKU).

### Step 1 — Get the two outputs needed for DNS configuration

```bash
terraform output frontdoor_endpoint_hostname
```
```
langsmith-fd-prod-xyz123.z01.azurefd.net
```

```bash
terraform output frontdoor_validation_token
```
```
abc123def456...
```

### Step 2 — Add DNS records at your registrar

Two records are required. Add them for your subdomain (e.g. `langsmith.example.com`):

| Record type | Host | Value |
|---|---|---|
| `CNAME` | `langsmith` | `langsmith-fd-prod-xyz123.z01.azurefd.net` |
| `TXT` | `_dnsauth.langsmith` | `abc123def456...` |

**Registrar-specific notes:**
- **Squarespace / Google Domains:** DNS → Custom Records → add both records
- **GoDaddy:** DNS Management → Add Record
- **Cloudflare:** DNS → Add record (set CNAME proxy to DNS-only / grey cloud — not proxied)
- **Route 53:** Hosted zone → Create record

### Step 3 — Verify certificate issuance (5–15 min)

Azure begins issuing the managed certificate as soon as it sees the TXT record. No Terraform re-apply needed.

```bash
# Verify DNS records are resolving correctly
dig CNAME langsmith.example.com          # should return the FD endpoint hostname
dig TXT _dnsauth.langsmith.example.com   # should return the validation token
```

Check cert status in the Azure Portal: **Front Door & CDN profiles → \<your-profile\> → Custom domains → TLS status**. Look for `Approved` or `Certificate provisioned`.

> If the cert stays `Pending` after 30 minutes, verify both DNS records are correct and that the CNAME has no Cloudflare proxy (must be DNS-only / grey cloud).

### Step 4 — Wire Front Door origin to the AKS ingress LB

Set the ingress IP (from Pass 1.5) in `terraform.tfvars`:
```hcl
frontdoor_origin_hostname = "52.x.x.x"   # EXTERNAL-IP from kubectl get svc
```

```bash
terraform apply   # connects Front Door → AKS ingress LB
```

> LangSmith is now reachable at `https://langsmith.example.com` via Front Door managed TLS. The ingress controller receives plain HTTP internally — no TLS configuration on the cluster side needed.

---

## Pass 1.6 Advanced — TLS: DNS-01 + cert-manager

> Use this path if you need cert-manager to manage certificates on-cluster (e.g. no CDN cost, private cluster, internal CA). Requires an Azure DNS zone.
>
> Skip if you are using Front Door (above).

### terraform.tfvars settings for DNS-01

Replace the Front Door block with:
```hcl
# Remove or comment out create_frontdoor = true

tls_certificate_source = "dns01"                    # cert-manager DNS-01 via Azure DNS
letsencrypt_email      = "you@example.com"
langsmith_domain       = "langsmith.example.com"
create_dns_zone        = true                       # Terraform creates the Azure DNS zone
# ingress_ip           = ""                         # fill after first apply
```

### Step 1 — Apply and get Azure nameservers

```bash
terraform apply
terraform output -json | jq -r '.dns_nameservers.value[]'
```
```
ns1-01.azure-dns.com.
ns2-01.azure-dns.net.
ns3-01.azure-dns.org.
ns4-01.azure-dns.info.
```

### Step 2 — Delegate subdomain at your registrar

Add 4 NS records pointing your subdomain to the Azure nameservers. Example for `langsmith.example.com`:

| Type | Host | Value |
|---|---|---|
| NS | `langsmith` | `ns1-01.azure-dns.com.` |
| NS | `langsmith` | `ns2-01.azure-dns.net.` |
| NS | `langsmith` | `ns3-01.azure-dns.org.` |
| NS | `langsmith` | `ns4-01.azure-dns.info.` |

> Propagation: 1–60 min. After this, Azure DNS is authoritative for the subdomain — cert-manager handles TXT record creation automatically.

### Step 3 — Set ingress IP and re-apply

```bash
# ingress_ip = "<EXTERNAL-IP>"   # set in terraform.tfvars
terraform apply   # creates the A record in Azure DNS
```

### Step 4 — Verify cert-manager ClusterIssuer

```bash
kubectl get clusterissuers
```
```
NAME               READY   AGE
letsencrypt-prod   True    30s
```

> ClusterIssuer is created by Terraform — no manual YAML needed. cert-manager uses Azure Workload Identity to create/delete TXT challenge records automatically.

---

## Secret Architecture — How Secrets Flow

> **Read this before Pass 2.** The most common deployment questions are about secrets — wrong key names, missing secrets, confusion about what creates what. This section explains the full picture.

### The three Kubernetes secrets

LangSmith requires exactly three K8s secrets in the `langsmith` namespace before the Helm chart will start successfully.

| Secret | Created by | Contains | Used by |
|---|---|---|---|
| `langsmith-postgres-secret` | **Terraform** (k8s-bootstrap module, Pass 1) | `connection_url` — full PostgreSQL connection string with credentials | backend, platformBackend, queue, ingestQueue, hostBackend, all Jobs |
| `langsmith-redis-secret` | **Terraform** (k8s-bootstrap module, Pass 1) | `connection_url` — Redis TLS connection string (`rediss://`) | queue, ingestQueue, listener, platformBackend |
| `langsmith-config-secret` | **You** (Pass 2c — pulled from Key Vault) | license key, API key salt, JWT secret, admin password, 4 Fernet encryption keys | All LangSmith pods via `config.existingSecretName` |

**Blob Storage has no K8s secret.** It uses Azure Workload Identity — pods get a federated Azure AD token automatically. No static storage keys anywhere.

---

### The full secret flow

```
setup-env.sh (first run)
  prompts:   postgres password, license key, admin password
  generates: api_key_salt, jwt_secret, 4 Fernet encryption keys
  writes:    secrets.auto.tfvars  (gitignored, chmod 600 — never commit)

terraform apply  (Pass 1)
  reads:    secrets.auto.tfvars
  creates:  Azure Key Vault
  stores:   all 9 values as Key Vault secrets
  creates:  langsmith-postgres-secret  ← connection URL built from Terraform outputs
            langsmith-redis-secret     ← connection URL built from Terraform outputs

Pass 2c  (manual — you run this)
  reads:    8 secrets from Key Vault via  az keyvault secret show
  creates:  langsmith-config-secret  ← application keys + license
```

**Why is `langsmith-config-secret` manual and not created by Terraform?**
Terraform manages infrastructure state. The K8s secret belongs to the application layer — its contents are defined by what the Helm chart expects, not what infrastructure produces. Keeping them separate means you can recreate or rotate the K8s secret without touching Terraform state, and you can update the Helm chart without a `terraform apply`.

---

### Exact key names in `langsmith-config-secret`

The Helm chart reads specific key names from `langsmith-config-secret`. If a key name is wrong or missing, the `langsmith-backend-auth-bootstrap` Job fails with `CreateContainerConfigError` and no meaningful error message.

| Key name in K8s secret | What it maps to in the Helm chart |
|---|---|
| `langsmith_license_key` | `config.langsmithLicenseKey` |
| `api_key_salt` | `config.apiKeySalt` |
| `jwt_secret` | `config.basicAuth.jwtSecret` |
| `initial_org_admin_password` | `config.basicAuth.initialOrgAdminPassword` |
| `deployments_encryption_key` | `config.deployment.encryptionKey` |
| `agent_builder_encryption_key` | `config.agentBuilder.encryptionKey` |
| `insights_encryption_key` | `config.insights.encryptionKey` |
| `polly_encryption_key` | `config.polly.encryptionKey` |

**Verify all 8 keys are present** (prints key names only — no values printed):
```bash
kubectl get secret langsmith-config-secret -n langsmith \
  -o jsonpath='{.data}' \
  | python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)]"
```
Expected output:
```
agent_builder_encryption_key
api_key_salt
deployments_encryption_key
initial_org_admin_password
insights_encryption_key
jwt_secret
langsmith_license_key
polly_encryption_key
```

**Decode and inspect a single value** (e.g., to verify the license key loaded correctly):
```bash
kubectl get secret langsmith-config-secret -n langsmith \
  -o jsonpath='{.data.langsmith_license_key}' | base64 -d && echo
```

---

### Fernet encryption keys — never rotate after first deploy

`deployments_encryption_key`, `agent_builder_encryption_key`, `insights_encryption_key`, and `polly_encryption_key` are Fernet symmetric encryption keys. They encrypt data at rest in PostgreSQL. **If you change them after the first deploy, all existing encrypted records become permanently unreadable.**

They are intentionally stable — generated once by `setup-env.sh`, stored in Key Vault, never changed. `setup-env.sh` is designed to always read them back from Key Vault rather than regenerate them.

---

### New machine or CI — regenerating secrets.auto.tfvars

If you need to run Terraform from a new machine (or in a CI pipeline), you do not need the original `secrets.auto.tfvars`. Just run `setup-env.sh` — it reads all secrets from Key Vault silently and regenerates the file:

```bash
bash setup-env.sh   # no prompts — reads from KV on all subsequent runs
```

This is always safe to re-run. `setup-env.sh` is read-only against Key Vault — Terraform is the sole KV writer.

---

### Updating `langsmith-config-secret` after a value change

If you need to update the secret (e.g., after a license key renewal):

```bash
# Re-fetch from Key Vault (run from terraform/azure/infra/)
KV_NAME=$(terraform output -raw keyvault_name)
API_KEY_SALT=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-api-key-salt --query value -o tsv)
JWT_SECRET=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-jwt-secret --query value -o tsv)
LICENSE_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-license-key --query value -o tsv)
ADMIN_PASSWORD=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-admin-password --query value -o tsv)
DEPLOY_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-deployments-encryption-key --query value -o tsv)
AGENT_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-agent-builder-encryption-key --query value -o tsv)
INSIGHTS_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-insights-encryption-key --query value -o tsv)
POLLY_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-polly-encryption-key --query value -o tsv)

# Re-apply (idempotent — safe to run even if secret already exists)
kubectl create secret generic langsmith-config-secret --namespace langsmith \
  --from-literal=api_key_salt="$API_KEY_SALT" \
  --from-literal=jwt_secret="$JWT_SECRET" \
  --from-literal=langsmith_license_key="$LICENSE_KEY" \
  --from-literal=initial_org_admin_password="$ADMIN_PASSWORD" \
  --from-literal=deployments_encryption_key="$DEPLOY_KEY" \
  --from-literal=agent_builder_encryption_key="$AGENT_KEY" \
  --from-literal=insights_encryption_key="$INSIGHTS_KEY" \
  --from-literal=polly_encryption_key="$POLLY_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

After updating the secret, restart pods to pick up the new values:
```bash
kubectl rollout restart deployment -n langsmith
```

> **Do not restart** if you only updated `langsmith_license_key` — the license is read at startup only. A rollout restart is required.

---

### Quick diagnostic — which secrets exist and how many keys

```bash
kubectl get secrets -n langsmith \
  -o custom-columns="NAME:.metadata.name,KEYS:.data" \
  | grep langsmith
```

Or more readable:
```bash
for secret in langsmith-config-secret langsmith-postgres-secret langsmith-redis-secret; do
  count=$(kubectl get secret $secret -n langsmith -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "MISSING")
  echo "$secret: $count keys"
done
```
Expected:
```
langsmith-config-secret: 8 keys
langsmith-postgres-secret: 1 keys
langsmith-redis-secret: 1 keys
```

---

## Pass 2 — LangSmith (External Postgres + Redis)

> Pass 1 provisions AKS, Blob Storage, Key Vault, cert-manager, KEDA, and — when `postgres_source = "external"` and `redis_source = "external"` — Azure DB for PostgreSQL and Azure Cache for Redis.
>
> Light deploy (all in-cluster DBs): see [BUILDING_LIGHT_LANGSMITH.md](BUILDING_LIGHT_LANGSMITH.md)

### Pass 1 terraform.tfvars settings (required before this pass)

```hcl
postgres_source = "external"
redis_source    = "external"
```

### 2a — Collect terraform outputs

```bash
# Domain hostname (strips https:// prefix from langsmith_url output)
HOSTNAME=$(terraform output -raw langsmith_url | sed 's|https://||')

# Key Vault name — all secrets read from here
KV_NAME=$(terraform output -raw keyvault_name)

# Blob storage — trace payload store (always required)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
STORAGE_CONTAINER=$(terraform output -raw storage_container_name)

# Workload Identity client ID — annotated on langsmith-ksa ServiceAccount
WI_CLIENT_ID=$(terraform output -raw storage_account_k8s_managed_identity_client_id)

echo "HOSTNAME:          $HOSTNAME"
echo "KV_NAME:           $KV_NAME"
echo "STORAGE_ACCOUNT:   $STORAGE_ACCOUNT"
echo "STORAGE_CONTAINER: $STORAGE_CONTAINER"
echo "WI_CLIENT_ID:      $WI_CLIENT_ID"
```
```
HOSTNAME:          langsmith.example.com
KV_NAME:           langsmith-kv-prod
STORAGE_ACCOUNT:   langsmithblob-prod
STORAGE_CONTAINER: langsmith-blob-prod-container
WI_CLIENT_ID:      <managed-identity-client-id>
```

### 2b — Prepare values-overrides.yaml

Each pass has its own example file. Copy the one matching your target pass:

| Pass | Example file | Pods added |
|---|---|---|
| 2 | `values-overrides-pass-2.yaml.example` | Core LangSmith (17 pods) |
| 3 | `values-overrides-pass-3.yaml.example` | + host-backend, listener, operator (20 pods) |
| 4 | `values-overrides-pass-4.yaml.example` | + agent-builder-tool-server, agent-builder-trigger-server (22 pods) |
| 5 | `values-overrides-pass-5.yaml.example` | + Insights/Clio via operator (dynamic) |

```bash
cp ../helm/values/values-overrides-pass-2.yaml.example ../helm/values/values-overrides.yaml

# Fill placeholders — one per line to avoid zsh multiline paste issues
# On Linux remove the '' from sed -i ''
sed -i '' "s|<your-domain.com>|${HOSTNAME}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g" ../helm/values/values-overrides.yaml
```

Set your admin email:
```bash
vi ../helm/values/values-overrides.yaml   # set initialOrgAdminEmail
```

### 2c — Create K8s config secret from Key Vault

> See [Secret Architecture](#secret-architecture--how-secrets-flow) for a full explanation of all three K8s secrets, key names, and the Fernet key stability requirement.
>
> `langsmith-postgres-secret` and `langsmith-redis-secret` are **already created by Terraform** (Pass 1). Only `langsmith-config-secret` needs to be created manually here.

Run from `terraform/azure/infra/`:

```bash
./scripts/create-k8s-secrets.sh
```

The script pulls all 8 secrets from Key Vault, creates `langsmith-config-secret`, and verifies every key is present. Or via Makefile:

```bash
make secrets
```

Expected output:
```
  [✓] api_key_salt
  [✓] jwt_secret
  [✓] langsmith_license_key
  [✓] initial_org_admin_password
  [✓] deployments_encryption_key
  [✓] agent_builder_encryption_key
  [✓] insights_encryption_key
  [✓] polly_encryption_key

  All 8 keys present. Ready for helm install.
```

### 2d — Create Istio Gateway (ASM addon only)

> Skip this step if using `ingress_controller = "nginx"`.

For `ingress_controller = "istio-addon"`, the LangSmith chart creates a `VirtualService` that references a `Gateway` resource. The `Gateway` must exist before the helm install.

The manifest is at `helm/values/use-cases/istio-mesh/istio-gateway.yaml`. Apply from `terraform/azure/`:

```bash
kubectl apply -f helm/values/use-cases/istio-mesh/istio-gateway.yaml
```

Verify:
```bash
kubectl get gateway -n aks-istio-ingress
# NAME                 AGE
# langsmith-gateway    1m
```

**Why `aks-istio-ingress` not `istio-system`:** Azure Service Mesh (ASM) uses different namespace names than standalone Istio. The external ingress gateway pod and its `Gateway` resources live in `aks-istio-ingress`. The values files reflect this: `istioGateway.namespace: "aks-istio-ingress"`.

### 2e — Deploy LangSmith

```bash
helm repo add langsmith https://langchain-ai.github.io/helm
helm repo update
helm search repo langsmith/langsmith --versions | head -5   # confirm latest version

helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> \
  --namespace langsmith --create-namespace \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

> **Note:** `--timeout 15m` — the `langsmith-backend-auth-bootstrap` post-upgrade Job runs DB migrations and auth init; it needs up to ~5 min on first install.

> Open a second terminal and watch pod status while helm runs:
> ```bash
> # macOS: install watch first
> brew install watch
> watch kubectl get pods -n langsmith
>
> # or without installing anything
> while true; do clear; kubectl get pods -n langsmith; sleep 3; done
> ```

Expected success output:
```
Thank you for installing LangSmith!
...
Release "langsmith" has been upgraded. Happy Helming!
```

### 2f — Verify

```bash
kubectl get pods -n langsmith           # all Running or Completed
kubectl get virtualservice -n langsmith # VirtualService created by chart (istio-addon)
kubectl get ingress -n langsmith        # Ingress (nginx only — empty for istio-addon)
kubectl get certificate -n langsmith    # READY: True (cert-manager TLS only)
```

Example pod output (all Running):
```
NAME                                          READY   STATUS      RESTARTS   AGE
langsmith-ace-backend-xxxxxxxxx-xxxxx         1/1     Running     0          5m
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running     0          5m
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running     0          5m
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running     0          5m
langsmith-backend-auth-bootstrap-xxxxx        0/1     Completed   0          5m
langsmith-backend-ch-migrations-xxxxx         0/1     Completed   0          5m
langsmith-backend-migrations-xxxxx            0/1     Completed   0          5m
langsmith-clickhouse-0                        1/1     Running     0          5m
langsmith-frontend-xxxxxxxxx-xxxxx            1/1     Running     0          5m
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running     0          5m
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running     0          5m
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running     0          5m
langsmith-platform-backend-xxxxxxxxx-xxxxx    1/1     Running     0          5m
langsmith-playground-xxxxxxxxx-xxxxx          1/1     Running     0          5m
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running     0          5m
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running     0          5m
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running     0          5m
```

Example ingress output:
```
NAME                CLASS   HOSTS                        ADDRESS     PORTS     AGE
langsmith-ingress   nginx   langsmith.example.com        52.x.x.x   80, 443   5m
```

Open `https://langsmith.example.com` — login with `initialOrgAdminEmail` + admin password from Key Vault.

> **WATCHOUT — `langsmith-config-secret` key name:** The Job expects `initial_org_admin_password` (not `admin_password`). Using the wrong key causes `CreateContainerConfigError` on the auth-bootstrap Job and the helm install will time out.

#### Pass 2 — Pod resource configuration

| Pod | Replicas | CPU req/limit | Mem req/limit | HPA min/max | WI |
|---|---|---|---|---|---|
| `langsmith-backend` | 1 (HPA) | 1000m / 2000m | 2000Mi / 4Gi | 3 / 10 | ✓ |
| `langsmith-platform-backend` | 1 (HPA) | 500m / 1000m | 1Gi / 2Gi | 1 / 10 | ✓ |
| `langsmith-frontend` | 1 (HPA) | 500m / 1000m | 1Gi / 2Gi | 1 / 10 | — |
| `langsmith-playground` | 1 (HPA) | 500m / 1000m | 1Gi / 2Gi | 1 / 10 | — |
| `langsmith-queue` | 1 (HPA+KEDA) | 1000m / 2000m | 2Gi / 4Gi | 3 / 10 | ✓ |
| `langsmith-ingest-queue` | 1 (HPA+KEDA) | 1000m / 2000m | 2Gi / 4Gi | 3 / 10 | ✓ |
| `langsmith-ace-backend` | 1 (HPA) | 500m / 1000m | 1Gi / 2Gi | 1 / 5 | — |
| `langsmith-clickhouse` | StatefulSet | 3500m / 8000m | 15Gi / 32Gi | — | — |
| Azure DB for PostgreSQL | managed | — | — | — | — |
| Azure Cache for Redis | managed | — | — | — | — |

> HPA scales on CPU ≥ 50% or Memory ≥ 80%. KEDA additionally scales `queue` and `ingest-queue` on Redis queue depth.

---

## Pass 3 — LangSmith Deployments (optional)

Enables LangGraph agent deployments: `hostBackend`, `listener`, `operator` pods.
Requires Pass 2 to be running.

**What gets added:**
- `langsmith-host-backend` — LangGraph control plane API
- `langsmith-listener` — watches for deployment changes, creates K8s CRDs
- `langsmith-operator` — manages per-deployment K8s Deployments

**Both `host-backend` and `listener` need Workload Identity** (blob access) — federated credentials already provisioned in `module.blob` during Pass 1.

### 3a — Enable Pass 3 block in values-overrides.yaml

In `../helm/values/values-overrides.yaml`:

1. Add both `deployment.enabled` and `deployment.url` inside the existing `config:` block (not as a new top-level key):
```yaml
config:
  # ... existing values ...
  deployment:
    enabled: true                        # REQUIRED — without this, listener and operator are skipped silently
    url: "https://<your-hostname>"       # must match config.hostname
```

2. Uncomment the `# ── Pass 3` section at the bottom of the file (`hostBackend`, `listener`, `operator`).

Get the WI client ID if needed:
```bash
terraform output -raw storage_account_k8s_managed_identity_client_id
```

### 3b — Deploy

Single `-f` flag — no overlays folder:

```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> \
  --namespace langsmith \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

### 3c — Verify

```bash
kubectl get pods -n langsmith
```

Expected — **17 pods total** (all Running, no Completed jobs shown after stabilisation):
```
NAME                                          READY   STATUS    RESTARTS   AGE
langsmith-ace-backend-xxxxxxxxx-xxxxx         1/1     Running   0          15h
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running   0          15h
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running   0          15h
langsmith-backend-xxxxxxxxx-xxxxx             1/1     Running   0          15h
langsmith-clickhouse-0                        1/1     Running   0          18h
langsmith-frontend-xxxxxxxxx-xxxxx            1/1     Running   0          15h
langsmith-host-backend-xxxxxxxxx-xxxxx        1/1     Running   0          15h  ★ Pass 3
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running   0          15h
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running   0          15h
langsmith-ingest-queue-xxxxxxxxx-xxxxx        1/1     Running   0          15h
langsmith-listener-xxxxxxxxx-xxxxx            1/1     Running   0          15h  ★ Pass 3
langsmith-operator-xxxxxxxxx-xxxxx            1/1     Running   0          15h  ★ Pass 3
langsmith-platform-backend-xxxxxxxxx-xxxxx    1/1     Running   0          15h
langsmith-playground-xxxxxxxxx-xxxxx          1/1     Running   0          15h
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running   0          15h
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running   0          15h
langsmith-queue-xxxxxxxxx-xxxxx               1/1     Running   0          15h
```

> **WATCHOUT — `config.deployment.enabled: true` is required.** Setting only `config.deployment.url` without `enabled: true` causes the chart to skip creating `listener` and `operator` deployments entirely — no error, they just won't appear.

#### Pass 3 — New pod resource configuration

| Pod | CPU req | Mem req | Replicas | WI |
|---|---|---|---|---|
| `langsmith-host-backend` | 100m | 500Mi | 1 | ✓ |
| `langsmith-listener` | 100m | 500Mi | 1 | ✓ |
| `langsmith-operator` | chart default | chart default | 1 | — |

---

## Pass 4 — Agent Builder (optional)

Enables `agentBuilderToolServer`, `agentBuilderTriggerServer`, and the `agentBootstrap` Job.
Requires Pass 3. Encryption key is read from `langsmith-config-secret` (set in Pass 2c).

**What gets added:**
- `langsmith-backend-agent-bootstrap` — one-time Job that registers the bundled Agent Builder agent via the operator
- `langsmith-agent-builder-tool-server` — MCP tool execution (WI)
- `langsmith-agent-builder-trigger-server` — webhooks and scheduled triggers (WI)

### 4a — Switch to Pass 4 values file

```bash
cp ../helm/values/values-overrides-pass-4.yaml.example ../helm/values/values-overrides.yaml

sed -i '' "s|<your-domain.com>|${HOSTNAME}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g" ../helm/values/values-overrides.yaml
```

Or keep your existing `values-overrides.yaml` and uncomment the `# ── Pass 4` block plus `config.agentBuilder` and `backend.agentBootstrap`.

### 4b — Deploy

```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> \
  --namespace langsmith \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

### 4c — Verify

```bash
kubectl get pods -n langsmith
```

Expected — **26 pods total** (static + dynamic agent deployment created by operator):

```
NAME                                                              READY   STATUS      RESTARTS   AGE
agent-builder-<hash>-xxxxxxxxx-xxxxx                              1/1     Running     0          7m   ★ dynamic
agent-builder-<hash>-queue-xxxxx                                  1/1     Running     0          7m   ★ dynamic
agent-builder-<hash>-redis-xxxxx                                  1/1     Running     0          7m   ★ dynamic
lg-<hash>-0                                                       1/1     Running     0          7m   ★ dynamic
langsmith-ace-backend-xxxxxxxxx-xxxxx                             1/1     Running     0          9m
langsmith-agent-bootstrap-xxxxx                                   0/1     Completed   0          8m   ★ Pass 4
langsmith-agent-builder-tool-server-xxxxxxxxx-xxxxx               1/1     Running     0          9m   ★ Pass 4
langsmith-agent-builder-trigger-server-xxxxxxxxx-xxxxx            1/1     Running     0          5m   ★ Pass 4
langsmith-backend-xxxxxxxxx-xxxxx                                 1/1     Running     0          9m
langsmith-backend-xxxxxxxxx-xxxxx                                 1/1     Running     0          9m
langsmith-backend-auth-bootstrap-xxxxx                            0/1     Completed   0          8m
langsmith-backend-ch-migrations-xxxxx                             0/1     Completed   0          8m
langsmith-backend-migrations-xxxxx                                0/1     Completed   0          8m
langsmith-clickhouse-0                                            1/1     Running     0          19h
langsmith-frontend-xxxxxxxxx-xxxxx                                1/1     Running     0          5m
langsmith-host-backend-xxxxxxxxx-xxxxx                            1/1     Running     0          9m
langsmith-ingest-queue-xxxxxxxxx-xxxxx                            1/1     Running     0          9m
langsmith-ingest-queue-xxxxxxxxx-xxxxx                            1/1     Running     0          9m
langsmith-ingest-queue-xxxxxxxxx-xxxxx                            1/1     Running     0          9m
langsmith-listener-xxxxxxxxx-xxxxx                                1/1     Running     0          9m
langsmith-operator-xxxxxxxxx-xxxxx                                1/1     Running     0          16h
langsmith-platform-backend-xxxxxxxxx-xxxxx                        1/1     Running     0          9m
langsmith-playground-xxxxxxxxx-xxxxx                              1/1     Running     0          9m
langsmith-queue-xxxxxxxxx-xxxxx                                   1/1     Running     0          9m
langsmith-queue-xxxxxxxxx-xxxxx                                   1/1     Running     0          9m
langsmith-queue-xxxxxxxxx-xxxxx                                   1/1     Running     0          9m
```

**Pass 4 adds 3 static pods + 4 dynamic pods:**
- `langsmith-agent-bootstrap` — one-time Job (Completed), registers the bundled Agent Builder agent via operator
- `langsmith-agent-builder-tool-server` — MCP tool execution (WI)
- `langsmith-agent-builder-trigger-server` — webhooks + scheduled triggers (WI)
- `agent-builder-<hash>` + `queue` + `redis` + `lg-<hash>-0` — operator-managed Agent Builder agent deployment (dynamic, hash = agent deployment ID)

> **Note:** `encryptionKey` is NOT set inline in values — it's read from `langsmith-config-secret` via `existingSecretName`. Setting it inline would override the secret and create a mismatch.

#### Pass 4 — New pod resource configuration

| Pod | CPU req | Mem req | Replicas | WI | Type |
|---|---|---|---|---|---|
| `langsmith-agent-builder-tool-server` | 100m | 500Mi | 1 | ✓ | static |
| `langsmith-agent-builder-trigger-server` | 100m | 500Mi | 1 | ✓ | static |
| `langsmith-agent-bootstrap` | — | — | — | — | Job (Completed) |
| `agent-builder-<hash>` | chart default | chart default | 1 | ✓ | dynamic |
| `agent-builder-<hash>-queue` | chart default | chart default | 1 | — | dynamic |
| `agent-builder-<hash>-redis` | chart default | chart default | 1 | — | dynamic |
| `lg-<hash>-0` | chart default | chart default | 1 | — | dynamic StatefulSet |

> Dynamic pods are created by the operator when `agentBootstrap` Job runs. The `<hash>` is the agent deployment ID assigned by the operator.

---

## Pass 5 — Insights (optional)

Enables AI-powered trace analytics (Clio). Requires Pass 3.
No additional static pods — Clio deploys as a dynamic LangGraph deployment via the operator when first invoked from the UI.

**Warning:** `insights_encryption_key` and `polly_encryption_key` must never change after first enable — changing either will permanently break access to existing data.

### 5a — Enable in values-overrides.yaml

Add inside the existing `config:` block:
```yaml
config:
  # ...
  insights:
    enabled: true
  polly:
    enabled: true
```

Or copy the Pass 5 example:
```bash
cp ../helm/values/values-overrides-pass-5.yaml.example ../helm/values/values-overrides.yaml
# fill placeholders same as Pass 2b
```

### 5b — Deploy

```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> \
  --namespace langsmith \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

### 5c — Verify

```bash
kubectl get pods -n langsmith
```

#### Pass 5 — Pod resource configuration

No new pods at deploy time. `config.insights.enabled: true` enables the feature flag only. Clio deploys lazily as a dynamic LangGraph deployment via the operator when first invoked from the UI — same `<hash>`-based pattern as `agent-builder-<hash>` in Pass 4.

Pod count after Pass 5 helm upgrade is identical to Pass 4 (22 running pods):
```
agent-builder-<hash>-xxxxxxxxx-xxxxx              1/1     Running   0   25m
agent-builder-<hash>-queue-xxxxx                  1/1     Running   0   25m
agent-builder-<hash>-redis-xxxxx                  1/1     Running   0   25m
lg-<hash>-0                                       1/1     Running   0   25m
langsmith-ace-backend-xxxxxxxxx-xxxxx             1/1     Running   0   28m
langsmith-agent-builder-tool-server-xxxxxxxxx     1/1     Running   0   8m
langsmith-agent-builder-trigger-server-xxxxxxxxx  1/1     Running   0   8m
langsmith-backend-xxxxxxxxx-xxxxx                 1/1     Running   0   8m
langsmith-backend-xxxxxxxxx-xxxxx                 1/1     Running   0   8m
langsmith-clickhouse-0                            1/1     Running   0   19h
langsmith-frontend-xxxxxxxxx-xxxxx                1/1     Running   0   8m
langsmith-host-backend-xxxxxxxxx-xxxxx            1/1     Running   0   8m
langsmith-ingest-queue-xxxxxxxxx-xxxxx            1/1     Running   0   8m
langsmith-ingest-queue-xxxxxxxxx-xxxxx            1/1     Running   0   8m
langsmith-ingest-queue-xxxxxxxxx-xxxxx            1/1     Running   0   8m
langsmith-listener-xxxxxxxxx-xxxxx                1/1     Running   0   8m
langsmith-operator-xxxxxxxxx-xxxxx                1/1     Running   0   16h
langsmith-platform-backend-xxxxxxxxx-xxxxx        1/1     Running   0   8m
langsmith-playground-xxxxxxxxx-xxxxx              1/1     Running   0   28m
langsmith-queue-xxxxxxxxx-xxxxx                   1/1     Running   0   8m
langsmith-queue-xxxxxxxxx-xxxxx                   1/1     Running   0   7m
langsmith-queue-xxxxxxxxx-xxxxx                   1/1     Running   0   7m
```

---

## Teardown

Uninstall Helm releases first — otherwise the Azure Load Balancer created by NGINX blocks VNet deletion and `terraform destroy` stalls.

```bash
# 1. Uninstall LangSmith (removes pods, services, Load Balancer)
helm uninstall langsmith -n langsmith --wait

# 2. Delete namespace (clears finalizers)
kubectl delete namespace langsmith --timeout=60s

# 3. Destroy infrastructure (from terraform/azure/infra/)
terraform destroy
```

---

## Common Commands

```bash
# Check pod status
kubectl get pods -n langsmith

# Check ingress / get IP
kubectl get svc ingress-nginx-controller -n ingress-nginx

# Check TLS certificate (cert-manager path only)
kubectl get certificate -n langsmith

# Tail logs
kubectl logs -n langsmith -l app=langsmith-backend --tail=100 -f

# Re-create config secret (e.g. after license key change)
# Set KV_NAME first: KV_NAME=$(terraform output -raw keyvault_name)
# Then re-run the kubectl create secret command from Pass 2c above
```

---

## Reference — Cluster Sizing

Node pool defaults for medium load (1 Control Plane + 3 Dataplanes):

| Pool | VM Size | vCPU | RAM | Min | Max | Purpose |
|---|---|---|---|---|---|---|
| default | Standard_D8s_v3 | 8 | 32 GiB | 1 | 12 | Core LangSmith, system pods, agent pods |
| large | Standard_D16s_v3 | 16 | 64 GiB | 0 | 2 | ClickHouse, memory-heavy dataplane workloads |

Recommended `default_node_pool_max_count` by pass:

| Pass | What's added | Recommended max_count |
|---|---|---|
| Pass 2 | Core LangSmith (Azure Postgres + Redis) | 4–6 |
| Pass 3 | hostBackend, listener, operator | 6 |
| Pass 4 | Agent Builder tool + trigger server | 8 |
| Pass 5 | Clio (Insights) analytics pods | 10–12 |

To increase capacity — update `terraform.tfvars` and re-apply:
```bash
default_node_pool_max_count = 10   # increase as needed
```
```bash
terraform apply   # AKS autoscaler picks up new max immediately — no node restart
```

> The `large` node pool (D16s_v3, 0→2) handles ClickHouse automatically. If ClickHouse is evicted under memory pressure, increase `max_count` on the `large` pool in `additional_node_pools`.

---

## Reference — Helm Chart Versions

**Always pin `--version`.** Without it, `helm upgrade` pulls the latest chart which may silently apply DB migrations or toggle feature flags that break existing deployments.

```bash
helm repo update
helm search repo langsmith/langsmith --versions | head -10
```

Example output (latest as of March 2026 is `0.13.28`):
```
NAME                   CHART VERSION   APP VERSION
langsmith/langsmith    0.13.28         0.13.31
langsmith/langsmith    0.13.27         0.13.28
langsmith/langsmith    0.13.23         0.13.23
langsmith/langsmith    0.13.21         0.13.21
langsmith/langsmith    0.13.20         0.13.21
langsmith/langsmith    0.13.19         0.13.20
```

> When upgrading — read the chart changelog first. `deployments_encryption_key`, `agent_builder_encryption_key`, `insights_encryption_key`, and `polly_encryption_key` must never change between upgrades.

---

*Commands verified during production deployment — updated as we go.*
