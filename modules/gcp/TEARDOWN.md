# LangSmith on GCP — Teardown Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before destroying for any notes on data migration or export.

This guide covers two teardown scenarios:

1. **With Terraform state** — the happy path using `terraform destroy`
2. **Without Terraform state** — manual teardown via gcloud CLI when state is lost

Both follow the same reverse-dependency order. Pick the section that matches your situation.

---

## Pre-Teardown Checklist

Before starting, confirm:

```bash
# Verify GCP identity and active project
gcloud auth list
gcloud config get-value project

# Get cluster credentials
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>

# Verify kubectl is pointing to the right cluster
kubectl config current-context

# Check what's running
helm list -A
kubectl get namespaces
```

**Data warning:** Teardown permanently deletes the Cloud SQL instance, GCS bucket contents, and Secret Manager secrets. Export any data you need to retain before proceeding.

---

# Option A: Teardown With Terraform State

Use this when `terraform state list` returns resources. Teardown happens in reverse order of deployment:

```
Pass 3 (if enabled) — Remove LangGraph deployments (LGP CRDs + pods)
Pass 2              — Uninstall LangSmith Helm release
Pass 1              — Destroy all GCP infrastructure (terraform destroy)
```

## A1 — Remove LangGraph Platform Deployments (if enabled)

If Pass 3 (LangSmith Deployments) was enabled, remove LGP resources before uninstalling Helm.

The uninstall script (Step A2) handles LGP pod/service/deployment cleanup automatically. **The LGP CRD is kept due to a resource policy and must be deleted manually** — the Helm chart's `helm.sh/resource-policy: keep` annotation prevents the CRD from being removed by `helm uninstall`. Without manually deleting it, the CRD persists indefinitely and causes confusing `kubectl get lgp` results after reinstall.

```bash
# Delete all LangGraph deployments (operator cleans up pods)
kubectl delete lgp --all -n langsmith

# Wait for operator to finish cleaning up pods
kubectl get pods -n langsmith -w

# Delete the LGP CRD — kept due to resource policy, must be done manually
kubectl delete crd lgps.apps.langchain.ai
```

## A2 — Uninstall LangSmith Helm Release

```bash
cd terraform/gcp
make uninstall
```

Or manually:

```bash
helm uninstall langsmith -n langsmith
kubectl get pods -n langsmith   # verify all pods removed
```

After uninstalling:

```bash
# Delete the namespace if it wasn't removed automatically
kubectl delete namespace langsmith
```

## A3 — Remove Kubernetes Bootstrap Resources

Uninstall in this order — cert-manager must go before KEDA to avoid blocking on finalizers, and KEDA must go after deleting any ScaledObjects.

```bash
# Delete ScaledObjects first to clear KEDA finalizers (see A4 for stuck-namespace fix)
kubectl delete scaledobjects --all -n langsmith 2>/dev/null || true

# Uninstall cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager

# Uninstall KEDA (only installed if enable_langsmith_deployment = true)
helm uninstall keda -n keda
kubectl delete namespace keda

# Uninstall Envoy Gateway
helm uninstall envoy-gateway -n envoy-gateway-system
kubectl delete namespace envoy-gateway-system
```

> **Envoy Gateway IP:** When you uninstall Envoy Gateway, GCP releases the external IP address. If you re-deploy later, a new IP is issued and you must update your DNS A record. Uninstall → reinstall cannot preserve the same IP unless you pre-allocate a static regional address and bind it to the Gateway (not currently wired in this stack).

## A4 — Handle KEDA ScaledObject Finalizers (if namespace stuck)

If the `langsmith` namespace gets stuck in `Terminating`, KEDA ScaledObject finalizers are the likely cause — the KEDA controller is already gone so it can't clear them. Fix:

```bash
for obj in $(kubectl get scaledobjects -n langsmith -o name 2>/dev/null); do
  kubectl patch "$obj" -n langsmith --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

## A5 — Pre-Destroy: Disable Deletion Protection

Two tfvars must be set to `false` before `terraform destroy` will succeed on GKE and Cloud SQL:

```hcl
# terraform.tfvars
gke_deletion_protection      = false
postgres_deletion_protection = false
```

Apply the change first:

```bash
cd terraform/gcp
make apply   # pushes the deletion-protection change
```

## A6 — Destroy GCP Infrastructure

```bash
cd terraform/gcp
source infra/scripts/setup-env.sh   # re-export TF_VAR_postgres_password
make destroy
```

Terraform destroys in dependency order:
- k8s-bootstrap (KEDA, cert-manager Helm releases)
- Cloud SQL PostgreSQL instance
- Memorystore Redis instance
- GCS bucket (only if `storage_force_destroy = true` or bucket is empty)
- Workload Identity service account + IAM bindings
- GKE cluster and node pools
- VPC, subnet, Cloud Router, Cloud NAT

> **Note on `source infra/scripts/setup-env.sh`:** Terraform needs `TF_VAR_postgres_password` even during destroy for provider validation. If the Secret Manager secret no longer exists, set it manually: `export TF_VAR_postgres_password="any-placeholder"`

## A7 — Clean Up Secret Manager Secrets (if enabled)

If `enable_secret_manager_module = true` was set, the Secret Manager secrets are destroyed by Terraform. If you stored additional secrets manually (via `setup-env.sh`), clean them up:

```bash
PROJECT_ID="<your-project-id>"
PREFIX="<name_prefix>-<environment>"

# List all LangSmith secrets
gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith"

# Delete each one
gcloud secrets delete "${PREFIX}-postgres-password" --project "$PROJECT_ID" --quiet
gcloud secrets delete "${PREFIX}-langsmith-license-key" --project "$PROJECT_ID" --quiet
gcloud secrets delete "${PREFIX}-langsmith-jwt-secret" --project "$PROJECT_ID" --quiet
gcloud secrets delete "${PREFIX}-langsmith-api-key-salt" --project "$PROJECT_ID" --quiet
gcloud secrets delete "${PREFIX}-langsmith-admin-password" --project "$PROJECT_ID" --quiet
gcloud secrets delete "${PREFIX}-deployments-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "${PREFIX}-agent-builder-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "${PREFIX}-insights-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
```

## A8 — Verify Cleanup

Replace `<name_prefix>` and `<environment>` with your values from `terraform.tfvars`.

```bash
PROJECT_ID="<your-project-id>"
REGION="<region>"
PREFIX="<name_prefix>-<environment>"

# GKE cluster
gcloud container clusters list --project "$PROJECT_ID"

# Cloud SQL
gcloud sql instances list --project "$PROJECT_ID"

# Memorystore
gcloud redis instances list --region "$REGION" --project "$PROJECT_ID"

# GCS bucket
gsutil ls 2>/dev/null | grep "$PREFIX" || echo "No matching buckets"

# VPC
gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX"

# Service accounts
gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$PREFIX"

# Secret Manager
gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith"
```

---

# Option B: Teardown Without Terraform State

Use this when Terraform state is lost (deleted, corrupted, or never configured a remote backend). Everything must be deleted manually via gcloud CLI in reverse dependency order.

**How this happens:** State loss typically occurs when using a local backend (`terraform.tfstate` file) and the file is deleted during a directory restructure, or a remote GCS backend was never configured.

## B0 — Inventory What Exists

Before deleting anything, build a complete inventory using the naming convention `<name_prefix>-<environment>-{resource}`:

```bash
PROJECT_ID="<your-project-id>"
REGION="<region>"
PREFIX="<name_prefix>-<environment>"

echo "=== GKE ===" && gcloud container clusters list --project "$PROJECT_ID"
echo "=== Cloud SQL ===" && gcloud sql instances list --project "$PROJECT_ID"
echo "=== Memorystore ===" && gcloud redis instances list --region "$REGION" --project "$PROJECT_ID"
echo "=== GCS ===" && gsutil ls 2>/dev/null | grep "$PREFIX"
echo "=== VPC ===" && gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX"
echo "=== Service Accounts ===" && gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$PREFIX"
echo "=== Secret Manager ===" && gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith"
```

## B1 — Remove Kubernetes Resources

Get cluster credentials first:

```bash
gcloud container clusters get-credentials "$PREFIX-gke-<suffix>" \
  --region "$REGION" --project "$PROJECT_ID"
```

Then remove Kubernetes resources in order:

```bash
# Delete LGP CRD (retained by resource policy)
kubectl delete crd lgps.apps.langchain.ai 2>/dev/null || true

# Delete ScaledObjects before KEDA (clears finalizers)
kubectl delete scaledobjects --all -A 2>/dev/null || true

# Uninstall Helm releases
helm uninstall langsmith -n langsmith 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
helm uninstall envoy-gateway -n envoy-gateway-system 2>/dev/null || true

# Delete namespaces
kubectl delete namespace langsmith cert-manager keda envoy-gateway-system 2>/dev/null || true
```

**Known issue — KEDA finalizers:** If the `langsmith` namespace gets stuck in `Terminating`, patch out the finalizers:

```bash
for obj in $(kubectl get scaledobjects -n langsmith -o name 2>/dev/null); do
  kubectl patch "$obj" -n langsmith --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

## B2 — Delete GKE Cluster

```bash
# List clusters to find the exact name
gcloud container clusters list --project "$PROJECT_ID"

# Delete the cluster (this also deletes node pools)
gcloud container clusters delete "$PREFIX-gke-<suffix>" \
  --region "$REGION" --project "$PROJECT_ID" --quiet
```

> GKE cluster deletion takes ~5 minutes. It automatically releases the external IP used by the Envoy Gateway.

## B3 — Delete Cloud SQL Instance

```bash
# Check deletion protection
gcloud sql instances describe "$PREFIX-pg-<suffix>" \
  --project "$PROJECT_ID" --format="value(settings.deletionProtectionEnabled)"

# Disable deletion protection if needed
gcloud sql instances patch "$PREFIX-pg-<suffix>" \
  --project "$PROJECT_ID" --no-deletion-protection

# Delete the instance
gcloud sql instances delete "$PREFIX-pg-<suffix>" \
  --project "$PROJECT_ID" --quiet
```

## B4 — Delete Memorystore Redis Instance

```bash
gcloud redis instances delete "$PREFIX-redis-<suffix>" \
  --region "$REGION" --project "$PROJECT_ID" --quiet
```

## B5 — Empty and Delete GCS Bucket

```bash
# Delete all objects (including versioned objects)
gsutil -m rm -r gs://"$PREFIX-traces-<suffix>"

# Delete the bucket
gsutil rb gs://"$PREFIX-traces-<suffix>"
```

If the bucket has versioned objects, use:

```bash
gsutil -m rm -a gs://"$PREFIX-traces-<suffix>"/**
gsutil rb gs://"$PREFIX-traces-<suffix>"
```

## B6 — Delete Secret Manager Secrets

```bash
for secret in $(gcloud secrets list --project "$PROJECT_ID" \
  --filter="name~langsmith" --format="value(name)"); do
  gcloud secrets delete "$secret" --project "$PROJECT_ID" --quiet
done
```

## B7 — Delete Workload Identity Service Account

```bash
# Find the SA
gcloud iam service-accounts list --project "$PROJECT_ID" \
  --filter="email~$PREFIX"

# Delete it
gcloud iam service-accounts delete "$PREFIX-langsmith@$PROJECT_ID.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" --quiet
```

## B8 — Delete VPC and Networking

**Must be done last.** Order matters — subnets cannot be deleted while GKE is still running.

```bash
VPC_NAME="$PREFIX-vpc-<suffix>"

# 1. Delete Cloud NAT
gcloud compute routers nats delete "$PREFIX-nat-<suffix>" \
  --router="$PREFIX-router-<suffix>" \
  --region="$REGION" --project "$PROJECT_ID" --quiet

# 2. Delete Cloud Router
gcloud compute routers delete "$PREFIX-router-<suffix>" \
  --region="$REGION" --project "$PROJECT_ID" --quiet

# 3. Delete subnets
for subnet in $(gcloud compute networks subnets list \
  --network="$VPC_NAME" --project "$PROJECT_ID" --format="value(name)"); do
  gcloud compute networks subnets delete "$subnet" \
    --region="$REGION" --project "$PROJECT_ID" --quiet
done

# 4. Remove private service connection (VPC peering for Cloud SQL / Memorystore)
gcloud services vpc-peerings delete \
  --network="$VPC_NAME" --project "$PROJECT_ID" --quiet 2>/dev/null || true

# 5. Delete the VPC
gcloud compute networks delete "$VPC_NAME" --project "$PROJECT_ID" --quiet
```

**Known issue — private service connection:** If the VPC deletion fails with `"has active peerings"`, the private service peering for Cloud SQL / Memorystore is still attached. The `gcloud services vpc-peerings delete` command above handles it. If that fails, wait ~2 minutes for the Cloud SQL instance deletion to propagate and retry.

## B9 — Verify Cleanup

```bash
gcloud container clusters list --project "$PROJECT_ID" | grep "$PREFIX" || echo "GKE: clean"
gcloud sql instances list --project "$PROJECT_ID" | grep "$PREFIX" || echo "Cloud SQL: clean"
gcloud redis instances list --region "$REGION" --project "$PROJECT_ID" | grep "$PREFIX" || echo "Redis: clean"
gsutil ls 2>/dev/null | grep "$PREFIX" || echo "GCS: clean"
gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX" | grep "$PREFIX" || echo "VPC: clean"
gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$PREFIX" | grep "$PREFIX" || echo "IAM SA: clean"
gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith" | grep langsmith || echo "Secrets: clean"
```

---

## Parallelization Notes

Several resources can be deleted in parallel since they have no dependencies on each other:

| Can run in parallel | Wait required before |
|---|---|
| Cloud SQL, Memorystore, GCS, Secret Manager | Independent — start all at once after GKE is deleted |
| GKE cluster | Must complete before VPC deletion |
| Cloud NAT + Router | Must complete before subnet deletion |
| Subnet deletion | Must complete before VPC deletion |

## Lessons Learned

- **Always configure a remote backend** (GCS bucket) before `terraform apply` — local state is fragile and easily lost. See `backend.tf.example` in `infra/`.
- **KEDA finalizers block namespace deletion** if the KEDA controller is uninstalled first — delete ScaledObjects before uninstalling KEDA, or patch out finalizers manually.
- **The LGP CRD is kept by resource policy** — `helm uninstall` will not remove it; delete it manually with `kubectl delete crd lgps.apps.langchain.ai`.
- **GKE deletion releases the external IP** — if you re-deploy, a new IP is issued. Update your DNS A record. To avoid this, use a static regional IP (not currently wired in this stack).
- **Private service connection peering** (`servicenetworking-googleapis-com`) must be removed before the VPC can be deleted. It's not created by Terraform directly — it's managed by the `servicenetworking` API. The `gcloud services vpc-peerings delete` command removes it.
- **Cloud SQL deletion takes ~2 minutes** — the VPC peering is not released until the instance is fully gone. Wait before attempting VPC cleanup.
- **GCS bucket with versioned objects** — requires `gsutil rm -a` (all versions) before `gsutil rb` will succeed.
