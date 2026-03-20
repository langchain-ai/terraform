# LangSmith Azure — Light Deploy (All In-Cluster DBs)

Full copy-paste guide for deploying LangSmith with all databases running in-cluster (no Azure DB for PostgreSQL, no Azure Cache for Redis).

**Use this for:** demos, POC evaluation, cost-sensitive testing.
**For production with external managed services see:** [QUICK_REFERENCE.md](QUICK_REFERENCE.md)

> In-cluster Postgres and Redis are not HA and have no backup policy. Do not use for customer data or sustained workloads.

---

## Pass 1 — Infrastructure

All commands run from `azure/infra/`.

### 1a — Configure terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
```

**Complete `terraform.tfvars` for light deploy:**
```hcl
# ── Required ──────────────────────────────────────────────────────────────────
subscription_id = ""              # az account show --query id -o tsv
identifier      = "-demo"         # suffix appended to every resource name
location        = "eastus"        # Azure region

# ── Naming & tagging ──────────────────────────────────────────────────────────
environment = "dev"
owner       = "platform-team"
cost_center = "engineering"

# ── Data sources — all in-cluster ─────────────────────────────────────────────
postgres_source   = "in-cluster"  # Helm chart manages Postgres pod
redis_source      = "in-cluster"  # Helm chart manages Redis pod
clickhouse_source = "in-cluster"  # ClickHouse always runs in-cluster

# ── AKS ───────────────────────────────────────────────────────────────────────
# Upsize to DS4_v2 — in-cluster Postgres, Redis, and ClickHouse all share this pool
default_node_pool_vm_size   = "Standard_DS4_v2"  # 8 vCPU, 28 GB RAM
default_node_pool_max_count = 3
aks_deletion_protection     = false

# ── Blob storage ──────────────────────────────────────────────────────────────
blob_ttl_enabled    = true
blob_ttl_short_days = 14
blob_ttl_long_days  = 400

# ── Key Vault ─────────────────────────────────────────────────────────────────
keyvault_purge_protection = false

# ── TLS ───────────────────────────────────────────────────────────────────────
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "you@example.com"

# ── LangSmith ─────────────────────────────────────────────────────────────────
langsmith_namespace    = "langsmith"
langsmith_release_name = "langsmith"
```

> No `additional_node_pools` needed — light deploy skips the `large` pool since ClickHouse shares the default pool (DS4_v2 has 28 GB, enough for ClickHouse's 15 GB request).

### 1b — Bootstrap secrets and apply

```bash
# Get your subscription ID
az account show --query id -o tsv

# Bootstrap secrets → writes secrets.auto.tfvars (gitignored, chmod 600)
# First run:        prompts for passwords, generates stable keys → local files + secrets.auto.tfvars
#                   Terraform apply then creates Key Vault and stores all secrets in it
# Subsequent runs:  reads silently from Key Vault → secrets.auto.tfvars (no prompts)
# setup-env.sh is read-only against Key Vault — Terraform is the sole KV writer
./setup-env.sh

# Init (first run only)
terraform init

terraform plan
terraform apply
```

**What gets created (~28 resources):**
- Resource group: `langsmith-rg<identifier>`
- VNet + AKS subnet (no Postgres/Redis subnets — in-cluster mode)
- AKS cluster: `langsmith-aks<identifier>`
- Blob storage account + Managed Identity + federated credentials
- Key Vault: `langsmith-kv<identifier>`
- K8s: `langsmith` namespace, `langsmith-ksa` ServiceAccount, cert-manager, KEDA

---

## Pass 1.5 — Cluster Access

```bash
az aks get-credentials \
  --resource-group langsmith-rg<identifier> \
  --name langsmith-aks<identifier> \
  --overwrite-existing

kubectl get nodes
kubectl get pods -n cert-manager
kubectl get pods -n keda
kubectl get svc ingress-nginx-controller -n ingress-nginx   # note EXTERNAL-IP
```

---

## Pass 1.6 — TLS Cluster Issuers

```bash
kubectl get crd clusterissuers.cert-manager.io

# Replace email then apply (path relative to azure/infra/)
sed 's/ACME_EMAIL_PLACEHOLDER/you@example.com/g' ../kubectl/letsencrypt-issuers.yaml \
  | kubectl apply -f -

kubectl get clusterissuers   # both should show READY: True
```

---

## Pass 2 — LangSmith (Light — all in-cluster DBs)

### 2a — Collect terraform outputs

Run from `azure/infra/`:

```bash
NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
HOSTNAME="${NGINX_IP//./-}.sslip.io"

KV_NAME=$(terraform output -raw keyvault_name)
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
STORAGE_CONTAINER=$(terraform output -raw storage_container_name)
WI_CLIENT_ID=$(terraform output -raw storage_account_k8s_managed_identity_client_id)

echo "HOSTNAME:          $HOSTNAME"
echo "KV_NAME:           $KV_NAME"
echo "STORAGE_ACCOUNT:   $STORAGE_ACCOUNT"
echo "STORAGE_CONTAINER: $STORAGE_CONTAINER"
echo "WI_CLIENT_ID:      $WI_CLIENT_ID"
```

### 2b — Prepare values-overrides.yaml

```bash
cp ../helm/values/values-overrides-demo.yaml.example ../helm/values/values-overrides.yaml

sed -i '' "s|<your-domain.com>|${HOSTNAME}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_account_name>|${STORAGE_ACCOUNT}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: storage_container_name>|${STORAGE_CONTAINER}|g" ../helm/values/values-overrides.yaml
sed -i '' "s|<tf output: workload_identity_client_id>|${WI_CLIENT_ID}|g" ../helm/values/values-overrides.yaml

vi ../helm/values/values-overrides.yaml   # set initialOrgAdminEmail
```

### 2c — Create K8s config secret from Key Vault

```bash
# Step 1 — fetch each secret into a variable
KV_NAME=$(terraform output -raw keyvault_name)
API_KEY_SALT=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-api-key-salt --query value -o tsv)
JWT_SECRET=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-jwt-secret --query value -o tsv)
LICENSE_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-license-key --query value -o tsv)
ADMIN_PASSWORD=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-admin-password --query value -o tsv)
DEPLOY_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-deployments-encryption-key --query value -o tsv)
AGENT_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-agent-builder-encryption-key --query value -o tsv)
INSIGHTS_KEY=$(az keyvault secret show --vault-name "$KV_NAME" --name langsmith-insights-encryption-key --query value -o tsv)
```

```bash
# Step 2 — create the secret (single line — no multiline paste issues)
kubectl create secret generic langsmith-config-secret --namespace langsmith --from-literal=api_key_salt="$API_KEY_SALT" --from-literal=jwt_secret="$JWT_SECRET" --from-literal=langsmith_license_key="$LICENSE_KEY" --from-literal=initial_org_admin_password="$ADMIN_PASSWORD" --from-literal=deployments_encryption_key="$DEPLOY_KEY" --from-literal=agent_builder_encryption_key="$AGENT_KEY" --from-literal=insights_encryption_key="$INSIGHTS_KEY" --dry-run=client -o yaml | kubectl apply -f -
```

```bash
# Verify
kubectl get secrets -n langsmith | grep langsmith
```
```
langsmith-config-secret    Opaque   7      ...
```

> In light deploy, `langsmith-postgres-secret` and `langsmith-redis-secret` are **not created** — the Helm chart manages those pods directly.

### 2d — Deploy LangSmith

```bash
helm repo add langsmith https://langchain-ai.github.io/helm
helm repo update
helm search repo langsmith/langsmith --versions | head -5

helm upgrade --install langsmith langsmith/langsmith \
  --version 0.13.27 \
  --namespace langsmith --create-namespace \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

### 2e — Verify

```bash
kubectl get pods -n langsmith        # all Running or Completed
kubectl get ingress -n langsmith     # host + TLS assigned
kubectl get certificate -n langsmith # READY: True
```

Open `https://<HOSTNAME>` — login with `initialOrgAdminEmail` + admin password from Key Vault.

---

## Teardown

```bash
helm uninstall langsmith -n langsmith --wait
kubectl delete namespace langsmith --timeout=60s
terraform destroy
```
