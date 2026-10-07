# Azure LangSmith — Pass 1 Test Cycle

Repeatable runbook for deploying and tearing down the Azure infra layer (Pass 1 — Terraform only).
Run this before merging changes to validate everything works end-to-end.

**Scope**: Terraform infra only. Helm/Pass 2 is a separate cycle — stop after the verification
checklist below.

---

## Prerequisites

**Tools required** (all must be in PATH):
- `az` CLI >= 2.50 — authenticated to the target subscription
- `terraform` v1.11.0+
- `kubectl`
- `helm` v3.12+

**Azure RBAC required** (verify with `az role assignment list --assignee <your-id>`):

| Role | Purpose |
|------|---------|
| `Contributor` | Create and manage all Azure resources |
| `User Access Administrator` | Create role assignments for Key Vault, Blob, cert-manager identities |

Owner includes both. Contributor alone is insufficient — role assignments require UAA. If UAA is delegated through an ABAC condition on `principalType`, the apply fails with a generic 403 and needs either `terraform_principal_type` set or, where the condition admits only `ServicePrincipal`, `keyvault_manage_terraform_admin_assignment = false` (see [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).

---

## Bare Minimum Test Config

Start from the minimum profile rather than a hand-written config:

```bash
cp infra/terraform.tfvars.minimum infra/terraform.tfvars
```

Then set `subscription_id`, the one value with no working placeholder. Also change
`name_prefix`, `dns_label` and `letsencrypt_email`, which it fills with
examples: `dns_label` names a public hostname, so two testers who keep the same
one collide in the same region. Everything this cycle checks below assumes
that file, so edit it rather than copying settings into a new one. What it gives
you:

- One `Standard_D4s_v5` node (4 vCPU, 16 GiB), autoscaling to 3, no additional pools
- Postgres, Redis and ClickHouse **in-cluster**: no Flexible Server, no Managed Redis, and no data subnets or private DNS zones for them
- `unique_resource_names = true`, so the globally unique names carry a six-character hash (see [Terraform outputs](#terraform-outputs))
- `keyvault_purge_protection = false`, which a clean `make destroy` needs
- `default_node_pool_max_pods = 60` and `aks_network_mode = "overlay"`, both fixed at creation
- `sizing_profile = "minimum"` for Pass 2

To test the managed data tier as well, see [External Postgres and Redis](#external-postgres-and-redis)
under Optional Modules. It adds cost and time, and the checklist below notes where its results differ.

---

## Pass 1 Procedure

Run all commands from the `azure/` directory.

### Step 0 — Verify Azure credentials
```bash
az account show
```
Confirm the subscription ID and name match the target deployment.

### Step 1 — Terraform input setup
```bash
make setup-env
```
This script:
- Prompts for `postgres_admin_password`, `langsmith_license_key`, `admin_email`
- Writes `secrets.auto.tfvars` — automatically loaded by Terraform

Those three are the only secrets Terraform sees, because it needs them to build
something. The LangSmith app secrets are seeded separately in Step 7 so their
plaintext never lands in Terraform state.

> **`secrets.auto.tfvars` is gitignored — never commit it.**
> Upgrading from a release before the secret split? The seven removed variables
> still sitting in your file produce a `Value for undeclared variable` warning
> each and are otherwise ignored. Delete those lines to quiet it.

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
Review the plan. Expected resource categories with `terraform.tfvars.minimum`:
- Resource group
- VNet and the AKS subnet
- AKS cluster and its default node pool, OIDC issuer, managed identities, federated credentials
- Azure Blob storage account + container
- Azure Key Vault, its RBAC role assignments, and two secrets (`postgres-admin-password`, `langsmith-license-key`)
- cert-manager, KEDA, and Envoy Gateway Helm releases
- Kubernetes namespace `langsmith` with its ServiceAccounts, ResourceQuota, LimitRange, NetworkPolicies and the `langsmith-license` secret

With external Postgres and Redis the plan also has the Postgres and Redis subnets, a
PostgreSQL Flexible Server and an Azure Managed Redis with their private DNS zones and
endpoints, and the `langsmith-postgres-secret` and `langsmith-redis-secret` secrets.

Confirm no unexpected `destroy` or `replace` actions on existing resources.

### Step 6 — Apply
```bash
make apply
```
Typical duration: **10–15 min**, most of it AKS cluster provisioning. External PostgreSQL and Redis add ~5 min each.

If apply fails partway through, it is safe to re-run — Terraform is idempotent.

### Step 7 — Seed Key Vault
```bash
make seed-secrets
```
Prompts for the initial LangSmith admin password (or reads
`$LANGSMITH_ADMIN_PASSWORD`) and generates the API key salt, JWT secret, and the
four Fernet encryption keys, writing all seven directly to Key Vault. Requires
the Key Vault Secrets Officer role, which `make apply` grants to the deployer.

**Critical invariants — never violate on a live deployment:**
- Every seeded secret is write-once. The script skips any that already exists, so re-running it is safe and never rotates a value.
- Rotating `langsmith-api-key-salt` invalidates all API keys.
- Rotating `langsmith-jwt-secret` invalidates all active user sessions.
- Rotating any Fernet key makes existing encrypted data unreadable.
- The admin password needs 12+ characters with a lowercase letter, an uppercase letter, and a symbol. The script rejects a bad one up front; the chart's auth-bootstrap job would otherwise fail ~10 minutes into the release.

Rotate deliberately via `make keyvault` when you actually intend to.

### Step 8 — Cluster credentials and app secret (Pass 1.5)
```bash
make kubeconfig
make k8s-secrets
```
`make kubeconfig` fetches the AKS credentials; it is harmless to repeat if you already ran
it for the Pass 1 checks. `make k8s-secrets` reads the eight app
secrets from Key Vault and creates `langsmith-config-secret` in the `langsmith`
namespace, which Pass 2 reads. It needs Step 7 first: the secrets it copies do not
exist until `make seed-secrets` writes them.

---

## Verification Checklist

The checklist follows the order things are created. Run the Pass 1 checks after
Step 6, and the Pass 1.5 checks after Step 8. Items that only exist after Pass 2
are listed at the end so a healthy Pass 1 is not read as a failure.

### After Pass 1 (Step 6, `make apply`)

#### Cluster access
```bash
make kubeconfig
kubectl get nodes
```
Expected: one node `Ready`, since `terraform.tfvars.minimum` sets `default_node_pool_min_count = 1`.
```
NAME                              STATUS   ROLES    AGE   VERSION
aks-default-<id>-vmss000000       Ready    <none>   18m   v1.<minor>.<patch>
```

#### Bootstrap components (Pass 2 prerequisites)
```bash
kubectl get pods -n cert-manager    # cert-manager controller + cainjector + webhook
kubectl get pods -n keda            # KEDA operator + metrics adapter
kubectl get pods -n envoy-gateway-system   # Envoy Gateway controller
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

# envoy-gateway-system (deployed by k8s-cluster module)
NAME                    READY   STATUS    RESTARTS   AGE
envoy-gateway-<hash>    1/1     Running   0          16m

# With ingress_controller = "nginx", check ingress-nginx instead:
# kubectl get pods -n ingress-nginx
```

#### LangSmith namespace
```bash
kubectl get secret -n langsmith
kubectl get serviceaccount langsmith-ksa -n langsmith -o yaml | grep -A3 "annotations:"
```
Expected with in-cluster Postgres and Redis:
```
NAME                TYPE     DATA
langsmith-license   Opaque   1

# WI annotation
annotations:
  azure.workload.identity/client-id: <client-id>
```
With external Postgres and Redis, two more secrets are present:
```
langsmith-postgres-secret   Opaque   3
langsmith-redis-secret      Opaque   3
```
No ClusterIssuer exists yet. Terraform installs cert-manager but creates no issuer;
`make deploy` applies them in Pass 2.

#### Terraform outputs
```bash
terraform -chdir=infra output
```
Expected key outputs, with `unique_resource_names = true` as in `terraform.tfvars.minimum`.
`<hash>` is six hex characters derived from the subscription ID, `name_prefix` and
`name_suffix_salt`, so it is the same on every run:
```
aks_cluster_name       = "ls-aks-<name_prefix>"
keyvault_name          = "ls-kv-<name_prefix>-<hash>"
langsmith_url          = "https://<dns_label>.<location>.cloudapp.azure.com"
resource_group_name    = "ls-rg-<name_prefix>"
storage_account_name   = "lsblob<name_prefix><hash>"
```
With `unique_resource_names = false` the prefix is `langsmith` and there is no hash, for
example `langsmith-kv-<name_prefix>`.

#### `make status` after Pass 1
```bash
make status
```
Sections 1 to 5 (configuration, secrets file, credentials, Key Vault, Terraform) should
show `✔`, except that the Key Vault section reports the app secrets missing until Step 7
runs. The later sections describe Pass 1.5 and Pass 2 and show `○`, `⚠` or `✘` for what does
not exist yet. The **Next Step** line names what to run, which is `make seed-secrets`
until Step 7 has run.

### After Pass 1.5 (Step 8, `make k8s-secrets`)

```bash
kubectl get secret langsmith-config-secret -n langsmith
```
Expected:
```
NAME                      TYPE     DATA
langsmith-config-secret   Opaque   8
```
`make status` now shows sections 1 to 6 as `✔` and names `make init-values` as the next
step, which is where this cycle stops. Section 8 lists `langsmith-config-secret` as
present; on an in-cluster deployment it also lists `langsmith-postgres-secret` and
`langsmith-redis-secret` as `○ not created yet`, which is expected, because only the
external data tier creates them.

### What Pass 2 adds

These fail on a correct Pass 1 and are not part of this cycle. Check them after
`make init-values && make deploy`:

- The `letsencrypt-prod` ClusterIssuer, `READY=True`
- `values-overrides.yaml` and the Helm release, sections 7 to 9 of `make status`
- `All checks passed — deployment looks healthy` as the final line of `make status`

---

## Optional Modules

Test each module as an incremental apply on top of the existing baseline.

### External Postgres and Redis

```hcl
# terraform.tfvars
postgres_source = "external"
redis_source    = "external"
```

**Expected plan**: the Postgres and Redis subnets, a PostgreSQL Flexible Server and an
Azure Managed Redis with their private DNS zones and endpoints, and two Kubernetes
secrets, `langsmith-postgres-secret` and `langsmith-redis-secret`. Adds about 10 minutes to
the apply and the cost of both managed services. Set these before the first Pass 2 to
avoid a data migration: switching an installed deployment from in-cluster to external
does not move its data.

On an MSDN or Visual Studio subscription, `make preflight` may warn with
`LocationIsOfferRestricted`: that offer type cannot create a Flexible Server in some
regions.

---

### WAF Policy

```hcl
# terraform.tfvars
create_waf = true
```

**Expected plan**: `+1` resource — `azurerm_web_application_firewall_policy.waf`.

**Verify**:
```bash
az network application-gateway waf-policy list -g <resource-group> --query '[].name'
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
postgres_high_availability           = true
availability_zones                   = ["1", "2", "3"]
postgres_standby_availability_zone   = "2"
postgres_geo_redundant_backup        = true
```

**Expected plan**: PostgreSQL HA mode set to `ZoneRedundant`, standby in zone 2.
Dropping `postgres_standby_availability_zone` keeps HA and leaves the standby
zone to Azure.

> Zone-redundant PostgreSQL requires `GeneralPurpose` or `MemoryOptimized` SKU.

> Set `availability_zones` before the first apply. On an existing cluster the
> AKS node pool keeps the zones it was created with: the module ignores zone
> changes so the provider cannot cycle the system node pool out from under
> running pods. Plan reports the mismatch as a `Check block assertion failed`
> warning naming both the live and the requested zones, and exits 0. Expect that
> warning here rather than a node pool change. The `[]` default requests no zone
> and never warns.

---

## Known Issues & Fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| `letsencrypt-prod` ClusterIssuer missing after apply | `clusterissuers.cert-manager.io "letsencrypt-prod" not found` on the langsmith-tls certificate | Terraform does not create the issuer. `make deploy` applies it, so run Pass 2 before checking the certificate. See TROUBLESHOOTING.md. |
| vCPU quota exceeded | `ErrCode_InsufficientVCPUQuota: Insufficient vcpu quota... remaining 2 for standardDSv5Family` | Request quota increase: Portal → Subscriptions → Usage + Quotas → DSv5 → Request 32. Or: `az quota update --resource-name standardDSv5Family ...` See TROUBLESHOOTING.md. |
| `max_pods` too low — autoscaler backoff | `pod didn't trigger scale-up: in backoff after failed scale-up` | Set `default_node_pool_max_pods = 60` **before** first apply — this field is immutable. With 30 pods/node, Pass 2's ~37 pods trigger autoscaler which hits quota. |
| Pass 2 pods `Pending` while the autoscaler adds nodes | The first deploy waits on scale-ups when the node floor is below what the chosen sizing needs | Not seen with `terraform.tfvars.minimum`: one `Standard_D4s_v5` schedules a minimum-profile Pass 2 (about 1,560m CPU requested against about 3,920m allocatable). With a larger `sizing_profile` or addons enabled, raise `default_node_pool_min_count` so the floor already fits the requests. |
| Istio addon revision not supported | `Revision asm-1-XX is not supported by the service mesh add-on` | Check supported revisions: `az aks mesh get-revisions --location eastus -o table`. Update `istio_addon_revision` in tfvars. |
| Key Vault soft-delete conflict | `VaultAlreadyExists: A vault with the same name already exists in deleted state` | Purge the old vault: `az keyvault purge --name <name> --location eastus`. Or use `keyvault_name` in tfvars to pick a new name. |
| cert-manager or KEDA Helm timeout | `context deadline exceeded` on k8s-bootstrap module | Uninstall the stuck release and re-apply: `helm uninstall cert-manager -n cert-manager` |
| PostgreSQL provisioning takes >20 min | `apply` appears hung on postgres module | Normal for Azure DB for PostgreSQL — it can take 10–15 min. Wait for it to complete. |
| `secrets.auto.tfvars` not found | `terraform plan` fails: variables have no value | Run `make setup-env` first. The file is gitignored and must be generated locally. |
| Envoy LB IP pending | `kubectl get gateway langsmith-gateway -n langsmith` shows no address | Wait 1–3 min for Azure LB provisioning. Check the proxy service: `kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway`. If still pending after 5 min, check AKS node status: `kubectl get nodes`. |
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
> `az group delete --name <resource_group_name> --yes` (`ls-rg-<name_prefix>` with `unique_resource_names = true`)

**Before destroy, verify this is set in `terraform.tfvars`:**
- `keyvault_purge_protection    = false`

**If destroy hangs on the VNet**: the ingress controller's LoadBalancer service (the Envoy proxy service, or ingress-nginx with `nginx`) may have created Azure LB rules
that hold the subnet. Delete the LB manually from Azure Portal → Load Balancers → find the
`kubernetes` LB → delete, then re-run `make destroy`.

**Key Vault soft-delete after destroy:** with `purge_protection = false`, `make destroy`
purges the vault as well as deleting it, because the provider's
`purge_soft_delete_on_destroy` default is on and `infra/versions.tf` does not change it.
Check with `az keyvault list-deleted`. A vault is left soft-deleted only when the destroy
was interrupted or the vault was deleted outside Terraform. A re-deploy with the same
`name_prefix` then fails with `VaultAlreadyExists`; purge it first:
```bash
az keyvault purge --name <keyvault_name> --location <region>
```

---

## Key Vault Secret Reference

Secrets stored in the Azure Key Vault named by `terraform -chdir=infra output keyvault_name`:

| Secret name | Auto-generated | Rotatable |
|-------------|---------------|-----------|
| `postgres-admin-password` | No (prompted) | Yes, with app restart |
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
