# LangSmith Azure — Teardown Guide

> Before destroying, back up any traces or data you want to keep — PostgreSQL and Blob Storage are permanently deleted.

---

## Overview

Teardown happens in **reverse deployment order** across three layers:

```
Layer 3 (top)  — LangGraph Platform custom resources (kubectl)
Layer 2        — Helm releases + Kubernetes namespaces (kubectl / helm)
Layer 1 (base) — Azure infrastructure (terraform destroy)
```

You must clear Layer 3 and Layer 2 **before** running `terraform destroy`. If you skip this,
Terraform cannot contact the now-deleted cluster and will fail on Helm/K8s resources still in state.

---

## Step 1 — Remove LangGraph Platform Deployments (if enabled)

**Skip this step** if you never ran Pass 3/4/5 (LangSmith Deployments, Agent Builder, Insights were never enabled).

LangGraph Platform creates `lgp` custom resources — pods and services that the operator manages **outside Helm**. Deleting the Helm release first would remove the operator before cleaning up its children, leaving orphaned pods.

```bash
# See what LGP deployments exist
kubectl get lgp -n langsmith

# Delete all of them — this cascades to operator-managed pods/services
kubectl delete lgp --all -n langsmith

# Confirm the operator-managed pods are terminating
kubectl get pods -n langsmith | grep -E "^agent-builder|^clio-|^lg-"

# Wait until they're gone (re-run until output is empty)
kubectl get pods -n langsmith | grep -E "^agent-builder|^clio-|^lg-"
```

Once the LGP pods are gone, delete the CRD:

```bash
# The CRD has helm.sh/resource-policy: keep — Helm intentionally leaves it behind
# to protect live deployments. Delete it manually after confirming pods are gone.
kubectl delete crd lgps.apps.langchain.ai
```

> **What is a CRD?** A Custom Resource Definition teaches Kubernetes about a new resource type.
> `lgps.apps.langchain.ai` is what enables `kubectl get lgp`. The `keep` policy means Helm
> uninstall will NOT delete it — you must do so explicitly.

---

## Step 2 — Uninstall Helm Releases

Uninstall in dependency order: **LangSmith first** (depends on cert-manager + ingress), then the infrastructure charts.

```bash
helm uninstall langsmith     -n langsmith
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall cert-manager  -n cert-manager
helm uninstall keda          -n keda
```

Wait for all pods to terminate:

```bash
# Re-run until no non-system pods remain
kubectl get pods -A | grep -v "kube-system"
```

---

## Step 3 — Delete Namespaces

```bash
kubectl delete namespace langsmith ingress-nginx cert-manager keda
```

> Deleting a namespace deletes everything inside it: ConfigMaps, Secrets, ServiceAccounts,
> NetworkPolicies, PVCs. Faster than deleting resources individually and guarantees no orphans.
> These namespaces are recreated automatically on the next `terraform apply`.

---

## Step 4 — Clear Stale Terraform State

Terraform's state file still thinks all the Helm releases and K8s objects exist. If you run
`terraform destroy` now it will try to delete them again and fail (they're already gone).

`terraform state rm` removes an entry from the state file **without touching the actual resource** —
it tells Terraform "stop tracking this, I handled it."

```bash
cd azure/infra/langsmith

# Remove Helm releases
terraform state rm \
  'module.aks.helm_release.nginx_ingress[0]' \
  'module.k8s_bootstrap.helm_release.cert_manager' \
  'module.k8s_bootstrap.helm_release.keda' \
  'module.k8s_bootstrap.helm_release.langsmith[0]'

# Remove Kubernetes resources
terraform state rm \
  'module.k8s_bootstrap.kubernetes_namespace_v1.langsmith' \
  'module.k8s_bootstrap.kubernetes_network_policy_v1.langsmith_allow_internal' \
  'module.k8s_bootstrap.kubernetes_network_policy_v1.langsmith_default_deny' \
  'module.k8s_bootstrap.kubernetes_resource_quota_v1.langsmith' \
  'module.k8s_bootstrap.kubernetes_role_binding_v1.backend_bootstrap[0]' \
  'module.k8s_bootstrap.kubernetes_role_v1.backend_bootstrap[0]' \
  'module.k8s_bootstrap.kubernetes_secret_v1.license[0]' \
  'module.k8s_bootstrap.kubernetes_secret_v1.postgres[0]' \
  'module.k8s_bootstrap.kubernetes_secret_v1.redis[0]' \
  'module.k8s_bootstrap.kubernetes_service_account_v1.langsmith'

# Remove null_resource bootstrap entries (present if Pass 3/4/5 was run)
terraform state rm \
  'module.k8s_bootstrap.null_resource.letsencrypt_issuers[0]' \
  'module.k8s_bootstrap.null_resource.insights_bootstrap[0]' \
  'module.k8s_bootstrap.null_resource.agent_builder_bootstrap[0]'
```

> The `null_resource` entries are bootstrap scripts that ran via `local-exec`. They don't
> correspond to real cloud resources — just remove whichever ones appear in `terraform state list`.

Verify only Azure resources remain:

```bash
terraform state list | grep -E "helm_release|kubernetes_|null_resource"
# Expected: no output
```

---

## Step 5 — Destroy Azure Infrastructure

```bash
cd azure/infra/langsmith

# Preview what will be destroyed (~31 resources)
terraform plan -destroy

# Destroy everything
terraform destroy
```

**Resources destroyed (~20–30 minutes):**
- AKS cluster + all node pools
- PostgreSQL Flexible Server + configuration + private DNS zone
- Redis Cache Premium
- Blob Storage account + container + managed identity + federated credentials
- Azure Key Vault (enters soft-delete — see Step 6)
- VNet + subnets
- Resource group

---

## Step 6 — Handle Key Vault Soft-Delete

Key Vault is created with `purge_protection_enabled = true` by default (prevents accidental
permanent deletion). After `terraform destroy`, the vault enters **soft-delete** — the name
is globally reserved for **90 days**. A re-deploy with the same identifier will fail with:

```
A vault with the same name already exists in a deleted state.
```

### If purge protection is disabled (dev/test)

```bash
# Purge the soft-deleted vault immediately — frees the name
az keyvault purge --name "langsmith-kv-<identifier>" --location <region>

# Verify it's gone
az keyvault list-deleted --query "[].name" -o table
```

### If purge protection is enabled (default)

You cannot purge the vault during the 90-day retention window. Your options:

**Option A — Change the identifier for the re-deploy:**

The `identifier` variable in `azure/infra/langsmith/terraform.tfvars` drives all resource names.
Change it to avoid the reserved vault name:
```hcl
# azure/infra/langsmith/terraform.tfvars
identifier = "-prod2"  # change to any unused suffix
```

**Option B — Disable purge protection *before* the next teardown:**
```bash
# First disable purge protection (while vault exists)
terraform apply -var="keyvault_purge_protection=false"

# Then destroy — vault can now be purged immediately after
terraform destroy
az keyvault purge --name "langsmith-kv-<identifier>" --location <region>
```

**Option C — Wait 90 days** for the retention period to expire.

---

## Step 7 — Verify Clean State

```bash
# Resource group should be gone
az group show --name langsmith-rg-<identifier>
# Expected: ResourceGroupNotFound

# Kubectl context is now stale — cluster is gone
kubectl cluster-info
# Expected: connection refused or timeout

# Check for soft-deleted Key Vaults
az keyvault list-deleted --query "[].name" -o table

# Terraform state should be empty
terraform state list
# Expected: no output
```

---

## Redeploy After Teardown

After a full teardown, Terraform state is empty. You can re-deploy immediately — **except**
if the Key Vault name is still reserved (see Step 7 above).

```bash
cd azure/infra/langsmith

# Set environment variables
export ARM_SUBSCRIPTION_ID="<your-subscription-id>"
export LANGSMITH_ADMIN_EMAIL="you@example.com"
export LANGSMITH_LICENSE_KEY="<your-license-key>"

# Pass 1 — provision infrastructure
source ./setup-env.sh
terraform apply

# Get cluster credentials
az aks get-credentials \
  --resource-group langsmith-rg-<identifier> \
  --name langsmith-aks-<identifier> \
  --overwrite-existing

# Pass 2 — deploy LangSmith
source ./setup-env.sh --deploy
terraform apply
```

See `QUICK_REFERENCE.md` for the full multi-pass sequence.
