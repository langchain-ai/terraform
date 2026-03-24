# Azure LangSmith — Pass 1 Test Cycle

Repeatable runbook for deploying and tearing down the Azure infra layer (Pass 1 — Terraform only).
Run this before merging changes to validate everything works end-to-end.

**Scope**: Terraform infra only. Helm/Pass 2 is a separate cycle — stop after the verification
checklist below.

---

## Prerequisites

**Tools required** (all must be in PATH):
- `az` CLI >= 2.50 — authenticated to the target subscription
- `terraform` v1.5+
- `kubectl`
- `helm` v3.12+

**Azure RBAC required** (verify with `az role assignment list --assignee <your-id>`):

| Role | Purpose |
|------|---------|
| `Contributor` | Create and manage all Azure resources |
| `User Access Administrator` | Create role assignments for Key Vault, Blob, cert-manager identities |

Owner includes both. Contributor alone is insufficient — role assignments require UAA.

---

## Bare Minimum Test Config

`azure/infra/terraform.tfvars` must include:

```hcl
subscription_id              = "your-azure-subscription-id"
identifier                   = "-dev"
environment                  = "dev"
location                     = "eastus"
aks_deletion_protection      = false   # required for clean terraform destroy after test
postgres_deletion_protection = false   # required for clean terraform destroy after test
keyvault_purge_protection    = false   # required for clean terraform destroy after test
create_frontdoor             = true
langsmith_domain             = "langsmith.example.com"
letsencrypt_email            = "you@example.com"
default_node_pool_min_count  = 3       # critical — autoscaler starts here; 1 causes pod pending
default_node_pool_max_pods   = 60      # immutable — must be set before first apply
```

All other defaults are fine for testing. A typical dev config uses:
- AKS: `Standard_D8s_v3`, 3 min / 10 max nodes
- PostgreSQL: Flexible Server (GeneralPurpose_Standard_D2s_v3)
- Redis: P1 (6 GB RAM)

---

## Pass 1 Procedure

Run all commands from the `azure/` directory.

### Step 0 — Verify Azure credentials
```bash
az account show
```
Confirm the subscription ID and name match the target deployment.

### Step 1 — Secrets setup
```bash
make setup-env
```
This script:
- Reads `identifier` and `environment` from `terraform.tfvars` to build Key Vault name
- Prompts for new values on first run: `postgres_password`, `license_key`, `admin_password`, `admin_email`
- Auto-generates stable secrets on first run: `api_key_salt`, `jwt_secret`, Fernet keys
- Writes `secrets.auto.tfvars` — automatically loaded by Terraform

**Critical invariants — never violate on a live deployment:**
- `api_key_salt` is write-once: rotating it invalidates all API keys
- `jwt_secret` is write-once: rotating it invalidates all active user sessions
- `admin_password` must meet Azure password complexity requirements

> **`secrets.auto.tfvars` is gitignored — never commit it.**
> On subsequent runs, `setup-env` reads from Key Vault — no prompts.

### Step 2 — Preflight check
```bash
make preflight
```
All checks must be green before proceeding. Fix any permission or provider-registration errors first.

### Step 3 — Init
```bash
make init
```
Downloads all providers and modules. Typical duration: 1–2 min.

### Step 4 — Validate
```bash
terraform -chdir=infra validate
```
Must return `Success! The configuration is valid.` — fix any errors before continuing.

### Step 5 — Plan
```bash
make plan
```
Review the plan. Expected resource categories:
- Resource group
- VNet, subnets (main, postgres, redis), private DNS zones
- AKS cluster, default node pool, large node pool, OIDC issuer, managed identity, federated credentials
- Azure Blob storage account + container
- Azure Key Vault + all application secrets
- Azure DB for PostgreSQL Flexible Server + private endpoint
- Azure Cache for Redis Premium + private endpoint
- Azure Front Door Standard profile + endpoint + origin group
- cert-manager, KEDA, NGINX ingress Helm releases
- Kubernetes namespace `langsmith`, K8s ServiceAccount

Confirm no unexpected `destroy` or `replace` actions on existing resources.

### Step 6 — Apply
```bash
make apply
```
Typical duration: **15–25 min** (AKS cluster provisioning takes ~10–15 min; PostgreSQL and Redis add ~5 min each).

If apply fails partway through, it is safe to re-run — Terraform is idempotent.

---

## Verification Checklist

Run these after `apply` completes successfully.

### Cluster access
```bash
make kubeconfig
kubectl get nodes
```
Expected output:
```
NAME                              STATUS   ROLES    AGE   VERSION
aks-default-13798291-vmss000000   Ready    <none>   18m   v1.32.11
aks-default-13798291-vmss000001   Ready    <none>   18m   v1.32.11
aks-default-13798291-vmss000002   Ready    <none>   18m   v1.32.11
```

### Bootstrap components (Pass 2 prerequisites)
```bash
kubectl get pods -n cert-manager    # cert-manager controller + cainjector + webhook
kubectl get pods -n keda            # KEDA operator + metrics adapter
kubectl get pods -n ingress-nginx   # NGINX ingress controller
```
Expected output:
```
# cert-manager
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-7c4b5b58df-tbd68              1/1     Running   0          96s
cert-manager-cainjector-7bf5c557bb-dfrrz   1/1     Running   0          96s
cert-manager-webhook-596c6cdc7b-6mlqm      1/1     Running   0          96s

# keda
NAME                                              READY   STATUS    RESTARTS   AGE
keda-admission-webhooks-59489d5cf6-q4h9q          1/1     Running   0          97s
keda-operator-78875c99-kktmk                      1/1     Running   0          97s
keda-operator-metrics-apiserver-5bd8f8bb6-vvblq   1/1     Running   0          97s

# ingress-nginx (deployed by k8s-cluster module)
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-7558b45cf6-k8q9l   1/1     Running   0          16m
ingress-nginx-controller-7558b45cf6-tf9cq   1/1     Running   0          16m
```

### LangSmith namespace
```bash
kubectl get secret -n langsmith
kubectl get serviceaccount langsmith-ksa -n langsmith -o yaml | grep -A3 "annotations:"
kubectl get clusterissuer
```
Expected:
```
NAME                        TYPE     DATA
langsmith-config-secret     Opaque   8
langsmith-license           Opaque   1
langsmith-postgres-secret   Opaque   1
langsmith-redis-secret      Opaque   1

# WI annotation
annotations:
  azure.workload.identity/client-id: <client-id>

# ClusterIssuer
NAME               READY   STATUS
letsencrypt-prod   True    The ACME account was registered with the ACME server
```

### Terraform outputs
```bash
# Run from terraform/azure/
terraform -chdir=infra output
```
Expected key outputs:
```
aks_cluster_name       = "langsmith-aks-<identifier>"
keyvault_name          = "langsmith-kv-<identifier>"
langsmith_url          = "https://<nginx_dns_label>.eastus.cloudapp.azure.com"
resource_group_name    = "langsmith-rg-<identifier>"
storage_account_name   = "langsmithblob<identifier>"
```

### Full health check
```bash
make status
```
All 9 sections must show `✔`. Expected final line: `All checks passed — deployment looks healthy`

---

## Optional Modules

Test each module as an incremental apply on top of the existing baseline.

### WAF Policy

```hcl
# terraform.tfvars
create_waf = true
```

**Expected plan**: `+1` resource — `azurerm_cdn_frontdoor_firewall_policy.waf`.

**Verify**:
```bash
az network front-door waf-policy list -g <resource-group> --query '[].name'
```

---

### Log Analytics + Diagnostics

```hcl
# terraform.tfvars
create_diagnostics = true
```

**Expected plan**: Log Analytics workspace + diagnostic settings for AKS, Key Vault, and Blob.

**Verify**:
```bash
az monitor log-analytics workspace list -g <resource-group> --query '[].name'
```

---

### Bastion

```hcl
# terraform.tfvars
create_bastion     = true
bastion_admin_ssh_public_key = "ssh-rsa AAAA..."
```

**Expected plan**: Azure Bastion VM + NIC + NSG + public IP.

**Verify**:
```bash
az vm list -g <resource-group> --query '[].name'
```

---

### Multi-AZ

```hcl
# terraform.tfvars
availability_zones                   = ["1", "2", "3"]
postgres_standby_availability_zone   = "2"
postgres_geo_redundant_backup        = true
```

**Expected plan**: AKS node pool zones updated; PostgreSQL HA mode set to `ZoneRedundant`.

> Zone-redundant PostgreSQL requires `GeneralPurpose` or `MemoryOptimized` SKU.

---

## Known Issues & Fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| `make plan` fails on fresh deploy | `cannot create REST client: no client config` on `kubernetes_manifest.cluster_issuer_http01` | Expected — the Kubernetes provider can't connect during plan because the cluster doesn't exist yet. Skip `make plan` on a fresh deploy and run `make apply` directly. `make apply` handles this with a three-stage apply. |
| `kubernetes_manifest` ClusterIssuer fails during apply | `API did not recognize GroupVersionKind: no matches for kind "ClusterIssuer"` | cert-manager CRDs not registered yet. Fixed by `make apply` Stage 2 (installs cert-manager first) before Stage 3 applies the ClusterIssuer. If you ran a plain `terraform apply`, run `make apply` again — it will pick up from the correct stage. |
| vCPU quota exceeded | `ErrCode_InsufficientVCPUQuota: Insufficient vcpu quota... remaining 2 for standardDSv3Family` | Request quota increase: Portal → Subscriptions → Usage + Quotas → DSv3 → Request 32. Or: `az quota update --resource-name standardDSv3Family ...` See TROUBLESHOOTING.md. |
| `max_pods` too low — autoscaler backoff | `pod didn't trigger scale-up: in backoff after failed scale-up` | Set `default_node_pool_max_pods = 60` **before** first apply — this field is immutable. With 30 pods/node, Pass 2's ~37 pods trigger autoscaler which hits quota. |
| `default_node_pool_min_count = 1` causes pod pending | All 14+ vCPU of Pass 2 must schedule but only 1 node starts | Set `default_node_pool_min_count = 3` — autoscaler waits for pending pods before adding nodes, causing initial deploy to stall. |
| Istio addon revision not supported | `Revision asm-1-XX is not supported by the service mesh add-on` | Check supported revisions: `az aks mesh get-revisions --location eastus -o table`. Update `istio_addon_revision` in tfvars. |
| Key Vault soft-delete conflict | `VaultAlreadyExists: A vault with the same name already exists in deleted state` | Purge the old vault: `az keyvault purge --name <name> --location eastus`. Or use `keyvault_name` in tfvars to pick a new name. |
| cert-manager or KEDA Helm timeout | `context deadline exceeded` on k8s-bootstrap module | Uninstall the stuck release and re-apply: `helm uninstall cert-manager -n cert-manager` |
| PostgreSQL provisioning takes >20 min | `apply` appears hung on postgres module | Normal for Azure DB for PostgreSQL — it can take 10–15 min. Wait for it to complete. |
| Front Door origin not wired | `frontdoor_origin_hostname` is empty — Front Door routes to nothing | After Pass 1, get the NGINX LB IP: `kubectl get svc -n ingress-nginx`. Set `frontdoor_origin_hostname = "<IP>"` in tfvars, then `make apply` again. |
| `secrets.auto.tfvars` not found | `terraform plan` fails: variables have no value | Run `make setup-env` first. The file is gitignored and must be generated locally. |
| NGINX LB IP pending | `kubectl get svc -n ingress-nginx` shows `<pending>` for EXTERNAL-IP | Wait 1–3 min for Azure LB provisioning. If still pending after 5 min, check AKS node status: `kubectl get nodes`. |

---

## Teardown

**Required order — do not skip steps or reorder:**

```bash
# 1. Uninstall Helm release — removes Azure Load Balancer (blocks VNet deletion if left)
make uninstall

# 2. Destroy all Azure infrastructure (~10–15 min)
make destroy

# 3. Clean local secrets and generated files — ONLY after destroy
make clean
```

> **`make clean` before `make destroy` = unrecoverable.** `make clean` deletes `terraform.tfstate`.
> Without state, Terraform cannot destroy anything. You'll have to delete Azure resources manually:
> `az group delete --name langsmith-rg-<identifier> --yes`

**Before destroy, verify these are set in `terraform.tfvars`:**
- `aks_deletion_protection      = false`
- `postgres_deletion_protection = false`
- `keyvault_purge_protection    = false`

**If destroy hangs on the VNet**: the NGINX ingress controller may have created Azure LB rules
that hold the subnet. Delete the LB manually from Azure Portal → Load Balancers → find the
`kubernetes` LB → delete, then re-run `make destroy`.

**Key Vault soft-delete after destroy:** Even with `purge_protection = false`, Azure retains the
Key Vault in soft-deleted state for 7 days. If you re-deploy with the same `identifier`:
```bash
az keyvault purge --name langsmith-kv-<identifier> --location <region>
```
Or use a different `identifier` suffix for the next deploy.

---

## Key Vault Secret Reference

Secrets stored in Azure Key Vault at `langsmith-kv<identifier>`:

| Secret name | Auto-generated | Rotatable |
|-------------|---------------|-----------|
| `postgres-password` | No (prompted) | Yes, with app restart |
| `langsmith-api-key-salt` | Yes (base64-32) | **Never** — invalidates all API keys |
| `langsmith-jwt-secret` | Yes (base64-32) | **Never** — invalidates all sessions |
| `langsmith-license-key` | No (prompted) | N/A |
| `langsmith-admin-password` | No (prompted) | Yes |
| `langsmith-deployments-encryption-key` | Yes (Fernet) | Requires re-encryption |
| `langsmith-agent-builder-encryption-key` | Yes (Fernet) | Requires re-encryption |
| `langsmith-insights-encryption-key` | Yes (Fernet) | Requires re-encryption |
| `langsmith-polly-encryption-key` | Yes (Fernet) | Requires re-encryption |

To inspect:
```bash
az keyvault secret list --vault-name <vault-name> -o table
az keyvault secret show --vault-name <vault-name> --name langsmith-api-key-salt --query value -o tsv
```
