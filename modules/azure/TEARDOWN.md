# LangSmith Azure — Teardown Guide

> Before destroying, back up any traces or data you want to keep — PostgreSQL and Blob Storage are permanently deleted.

---

## Overview

Teardown happens in three make commands:

```
make uninstall   → removes Helm releases + LGP CRD + namespaces
make destroy     → destroys all Azure infrastructure via terraform destroy
make clean       → removes generated secrets, helm values, and tfstate lock
```

All three are idempotent — safe to re-run if something fails partway through.

---

## Step 1 — Uninstall Helm + Kubernetes Resources

```bash
cd azure
make uninstall
```

`uninstall.sh` does, in order:

1. Deletes all `lgp` custom resources (LangGraph Platform deployments) and waits for operator-managed pods to terminate
2. Deletes the `lgps.apps.langchain.ai` CRD (has `helm.sh/resource-policy: keep` — Helm leaves it behind intentionally)
3. Helm uninstall: `langsmith`, `ingress-nginx`, `cert-manager`, `keda`
4. Deletes namespaces: `langsmith`, `ingress-nginx`, `cert-manager`, `keda`

> If `make uninstall` hangs on namespace deletion (finalizers from a stuck resource), run:
> ```bash
> kubectl delete namespace langsmith --grace-period=0 --force
> ```

---

## Step 2 — Destroy Azure Infrastructure

```bash
cd azure
make destroy
```

Runs `terraform destroy -auto-approve` from `azure/infra/`.

**Resources destroyed (~20–30 minutes):**
- AKS cluster + all node pools
- PostgreSQL Flexible Server + configuration + private DNS zone
- Redis Cache Premium
- Blob Storage account + container + managed identity + federated credentials
- Azure Key Vault (enters soft-delete — see below)
- VNet + subnets
- Resource group

---

## Step 3 — Clean Up Generated Files

```bash
cd azure
make clean
```

Removes:
- `azure/infra/secrets/` — generated environment files with secrets
- `azure/helm/values/langsmith-values-*.yaml` — generated helm override files
- `azure/infra/.terraform.tfstate.lock.info` — stale lock file (if terraform was interrupted)

Does **not** remove `terraform.tfstate` — that stays in place for state tracking.

---

## Key Vault Soft-Delete

Key Vault enters **soft-delete** after `terraform destroy` — the name is globally reserved for
**90 days**. A re-deploy with the same identifier will fail:

```
A vault with the same name already exists in a deleted state.
```

### If purge protection is disabled (dev/test — default in terraform.tfvars)

```bash
az keyvault purge --name "langsmith-kv-<identifier>" --location <region>

# Verify it's gone
az keyvault list-deleted --query "[].name" -o table
```

### If purge protection is enabled

**Option A — Change the identifier:**
```hcl
# azure/infra/terraform.tfvars
identifier = "-azonf2"  # any unused suffix
```

**Option B — Disable purge protection before next teardown:**
```bash
cd azure/infra
terraform apply -var="keyvault_purge_protection=false"
make destroy
az keyvault purge --name "langsmith-kv-<identifier>" --location <region>
```

**Option C — Wait 90 days** for the retention period to expire.

---

## Verify Clean State

```bash
# Resource group should be gone
az group show --name "langsmith-rg-<identifier>"
# Expected: ResourceGroupNotFound

# Check for soft-deleted Key Vaults
az keyvault list-deleted --query "[].name" -o table

# Kubectl context is now stale — cluster is gone
kubectl cluster-info
# Expected: connection refused or timeout

# Terraform state should be empty (or just the backend config)
cd azure/infra && terraform state list
```

---

## Redeploy After Teardown

After a full teardown, re-deploy with the standard make workflow:

```bash
cd azure
make setup-env          # set ARM_SUBSCRIPTION_ID, LANGSMITH_LICENSE_KEY, etc.
make init               # terraform init
make apply              # terraform apply → AKS + managed services
make kubeconfig         # az aks get-credentials
make k8s-secrets        # create langsmith-config-secret in the cluster
make init-values        # generate helm override files from tfvars
make deploy             # helm upgrade --install + DNS label + ClusterIssuer
```

See `QUICK_REFERENCE.md` for the full 5-pass sequence with exact commands.
