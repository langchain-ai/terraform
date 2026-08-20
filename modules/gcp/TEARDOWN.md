---
title: "Teardown Guide"
description: "Step-by-step instructions for safely destroying a LangSmith deployment on GCP."
provider: "gcp"
type: "teardown"
---

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
# Re-auth first if Terraform/gcloud shows:
# oauth2: "invalid_grant" "reauth related error (invalid_rapt)"
gcloud auth login
gcloud auth application-default login

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

Use the provided script. The script removes the Helm release and operator-managed resources.

```bash
cd terraform/gcp
make uninstall
```

You can also run the same script directly:

```bash
cd terraform/gcp
./helm/scripts/uninstall.sh
```

**Sandboxes and JuiceFS:** The JuiceFS CSI driver is part of the LangSmith Helm release. A Helm-first uninstall removes the controller before it can clear `juicefs.com/finalizer`. The uninstall script deletes the sandbox-host workload and JuiceFS claims first. The script then clears finalizers from any remaining `Terminating` pods.

**In-cluster ClickHouse disks:** The `data-langsmith-clickhouse-*` claim uses the `premium-rwo` storage class. The GCE PD CSI driver provisions the Persistent Disk, so Terraform does not track it. The uninstall script keeps the claim by default to support a clean Helm reinstall.

For full infrastructure teardown, delete the claim during uninstall. The CSI driver can then reclaim the disk before Terraform destroys GKE:

```bash
cd terraform/gcp
DELETE_DATA_PVCS=true make uninstall
```

After a full teardown uninstall, delete the namespace if it still exists:

```bash
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

If the `langsmith` namespace gets stuck in `Terminating` after A2, JuiceFS finalizers are the first cause to check (`kubectl get pods -n langsmith | grep juicefs`). Use the uninstall script on a current checkout rather than patching PVCs by hand.

If JuiceFS is already gone, KEDA ScaledObject finalizers are the next cause — the KEDA controller is already gone so it cannot clear them. Fix:

```bash
for obj in $(kubectl get scaledobjects -n langsmith -o name 2>/dev/null); do
  kubectl patch "$obj" -n langsmith --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

## A5 — Pre-Destroy: Export Data, Then Disable Deletion Protection

### 5a — Export anything you need to keep

Cloud SQL has no final-snapshot-on-delete. Automated backups, on-demand backups,
and PITR logs are all deleted along with the instance, so an export to GCS is the
only copy that survives teardown. Skip this step for a disposable dev/test stack.

```bash
PROJECT_ID=your-project
BACKUP_BUCKET=gs://your-export-bucket
PG=$(terraform -chdir=infra output -raw postgres_instance_name)

# Cloud SQL exports run as the instance's own service agent, which needs write
# access to the target bucket first.
SA=$(gcloud sql instances describe "$PG" --project "$PROJECT_ID" \
  --format="value(serviceAccountEmailAddress)")
gcloud storage buckets add-iam-policy-binding "$BACKUP_BUCKET" \
  --member="serviceAccount:$SA" --role=roles/storage.objectAdmin

gcloud sql export sql "$PG" "$BACKUP_BUCKET/${PG}-final.sql.gz" \
  --database=langsmith --project "$PROJECT_ID"
```

Repeat for the SmithDB metastore when `enable_smithdb = true` and
`smithdb_metastore_source = "create"`. Its trace segments live in the SmithDB GCS
bucket, which is separate from the metastore and survives unless
`smithdb_bucket_force_destroy = true`.

```bash
META=$(terraform -chdir=infra output -raw smithdb_metastore_instance_name)
gcloud sql export sql "$META" "$BACKUP_BUCKET/${META}-final.sql.gz" \
  --database=smithdb --project "$PROJECT_ID"
```

### 5b — Disable deletion protection

Protection covers both Terraform and the Cloud SQL API, so flipping the tfvars is
not enough on its own — the change has to be applied before the destroy.

```hcl
# terraform.tfvars
gke_deletion_protection      = false
postgres_deletion_protection = false

# Only when enable_smithdb = true and smithdb_metastore_source = "create"
smithdb_metastore_deletion_protection = false
smithdb_bucket_force_destroy          = true   # skip if you want to keep the segments
```

Apply the change first (targeted — avoids reconciling in-cluster addons like KEDA/cert-manager/ingress):

```bash
cd terraform/gcp
terraform -chdir=infra apply \
  -target=module.gke_cluster \
  -target=module.cloudsql \
  -target=module.smithdb
```

Drop the `module.smithdb` target when SmithDB was never enabled. Do not rerun the
production quickstart profile after this edit — it regenerates the tfvars with
protection back on.

> Why not `make apply` here? A full infra apply can re-run Kubernetes/Helm bootstrap paths and recreate components you just removed.

## A6 — Destroy GCP Infrastructure

```bash
cd terraform/gcp
source infra/scripts/setup-env.sh   # re-export TF_VAR_postgres_password
make destroy
```

Terraform destroys in dependency order:
- k8s-bootstrap (KEDA, cert-manager Helm releases)
- Cloud SQL PostgreSQL instance
- SmithDB metastore Cloud SQL instance and its GCS bucket (only when `enable_smithdb = true`)
- Memorystore Redis instance
- GCS bucket (only if `storage_force_destroy = true` or bucket is empty)
- Workload Identity service accounts + IAM bindings (LangSmith and SmithDB)
- GKE cluster and node pools, including the SmithDB Local SSD and compute pools
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

# GCE Persistent Disks (in-cluster ClickHouse on premium-rwo is not in Terraform state)
gcloud compute disks list --project "$PROJECT_ID" --filter="name~$PREFIX OR name~clickhouse" \
  --format='value(name,zone,sizeGb,status)'
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

Then remove Kubernetes resources in order. Do not run `helm uninstall langsmith` first when sandboxes are enabled. That removes the JuiceFS CSI controller while mount pods still hold `juicefs.com/finalizer`. Prefer the uninstall script, which deletes sandbox-host and JuiceFS claims first:

```bash
# Delete LGP CRD (retained by resource policy)
kubectl delete crd lgps.apps.langchain.ai 2>/dev/null || true

# Delete ScaledObjects before KEDA (clears finalizers)
kubectl delete scaledobjects --all -A 2>/dev/null || true

# LangSmith release: use the script so JuiceFS volumes unmount while CSI is up.
# DELETE_DATA_PVCS=true reclaims the in-cluster ClickHouse GCE PD.
DELETE_DATA_PVCS=true ./helm/scripts/uninstall.sh

# Remaining bootstrap releases
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

## B3 — Delete Cloud SQL Instances

Export anything you need first (see A5a) — deleting the instance deletes its
backups and PITR logs with it.

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

Repeat all three commands for `$PREFIX-smithdb-pg-<suffix>` when SmithDB was
enabled with a Terraform-created metastore. List both with:

```bash
gcloud sql instances list --project "$PROJECT_ID" --filter="name~$PREFIX"
```

Cloud SQL reserves a deleted instance name for about a week, so a rebuild under
the identical name will fail. The module sidesteps this with `unique_suffix`,
which appends a random suffix to instance names.

## B4 — Delete Memorystore Redis Instance

```bash
gcloud redis instances delete "$PREFIX-redis-<suffix>" \
  --region "$REGION" --project "$PROJECT_ID" --quiet
```

If sandboxes were enabled, a second instance exists for JuiceFS metadata (`$PREFIX-jfs-redis-<suffix>`). Delete that too:

```bash
gcloud redis instances list --region "$REGION" --project "$PROJECT_ID" --filter="name~$PREFIX"
gcloud redis instances delete "$PREFIX-jfs-redis-<suffix>" \
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
- **JuiceFS CSI lives in the LangSmith Helm release.** Uninstall the sandbox-host workload and JuiceFS claims before `helm uninstall`, or mount pods stay `Terminating` with `juicefs.com/finalizer` and namespace delete hangs. Use `./helm/scripts/uninstall.sh`.
- **In-cluster ClickHouse uses a dynamically provisioned GCE PD** (`premium-rwo`). Terraform does not track it. Run `DELETE_DATA_PVCS=true make uninstall` before `terraform destroy`, or the disk is orphaned.
- **Terraform validates `postgres_password` on destroy.** Source `infra/scripts/setup-env.sh` first. If the Secret Manager secret is already gone, set `export TF_VAR_postgres_password="any-placeholder"`.
- **KEDA finalizers block namespace deletion** if the KEDA controller is uninstalled first — delete ScaledObjects before uninstalling KEDA, or patch out finalizers manually.
- **The LGP CRD is kept by resource policy** — `helm uninstall` will not remove it; delete it manually with `kubectl delete crd lgps.apps.langchain.ai`.
- **GKE deletion releases the external IP** — if you re-deploy, a new IP is issued. Update your DNS A record. To avoid this, use a static regional IP (not currently wired in this stack).
- **Private service connection peering** (`servicenetworking-googleapis-com`) must be removed before the VPC can be deleted. It's not created by Terraform directly — it's managed by the `servicenetworking` API. The `gcloud services vpc-peerings delete` command removes it.
- **Cloud SQL deletion takes ~2 minutes** — the VPC peering is not released until the instance is fully gone. Wait before attempting VPC cleanup.
- **GCS bucket with versioned objects** — requires `gsutil rm -a` (all versions) before `gsutil rb` will succeed.
