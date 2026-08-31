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

`setup-env.sh` names its secrets `langsmith-<name_prefix>-<environment>-<key>`. In a shared
project, scope the listing to your own stack — `name~langsmith` alone matches every tenant.

```bash
PROJECT_ID="<your-project-id>"
PREFIX="<name_prefix>-<environment>"

# List this stack's secrets — review before deleting
gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith-$PREFIX-" \
  --format="value(name)"

# Delete each one (explicit names — do not widen the filter)
gcloud secrets delete "langsmith-${PREFIX}-postgres-password" --project "$PROJECT_ID" --quiet
gcloud secrets delete "langsmith-${PREFIX}-langsmith-license-key" --project "$PROJECT_ID" --quiet
gcloud secrets delete "langsmith-${PREFIX}-jwt-secret" --project "$PROJECT_ID" --quiet
gcloud secrets delete "langsmith-${PREFIX}-api-key-salt" --project "$PROJECT_ID" --quiet
gcloud secrets delete "langsmith-${PREFIX}-admin-password" --project "$PROJECT_ID" --quiet
gcloud secrets delete "langsmith-${PREFIX}-sandbox-callback-signing-jwk" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "langsmith-${PREFIX}-deployments-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "langsmith-${PREFIX}-agent-builder-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "langsmith-${PREFIX}-insights-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
gcloud secrets delete "langsmith-${PREFIX}-polly-encryption-key" --project "$PROJECT_ID" --quiet 2>/dev/null || true
```

## A8 — Verify Cleanup

Replace `<name_prefix>` and `<environment>` with your values from `terraform.tfvars`.

```bash
PROJECT_ID="<your-project-id>"
REGION="<region>"
PREFIX="<name_prefix>-<environment>"
NAME_PREFIX="<name_prefix>"          # without environment — for the service account

# GKE cluster
gcloud container clusters list --project "$PROJECT_ID"

# Cloud SQL
gcloud sql instances list --project "$PROJECT_ID"

# Memorystore
gcloud redis instances list --region "$REGION" --project "$PROJECT_ID"

# GCS bucket
gcloud storage ls --project "$PROJECT_ID" 2>/dev/null | grep "$PREFIX" || echo "No matching buckets"

# VPC
gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX"

# Service accounts (WI uses name_prefix only; sandbox-node and SmithDB use PREFIX)
gcloud iam service-accounts list --project "$PROJECT_ID" \
  --filter="email~$NAME_PREFIX-langsmith OR email~$PREFIX-sbox-node OR email~$PREFIX-smithdb-sa"

# Secret Manager (scoped to this stack)
gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith-$PREFIX-"

# GCE Persistent Disks (in-cluster ClickHouse on premium-rwo is not in Terraform state)
gcloud compute disks list --project "$PROJECT_ID" --filter="name~$PREFIX OR name~clickhouse" \
  --format='value(name,zone,sizeGb,status)'
```

---

# Option B: Teardown Without Terraform State

Use this when Terraform state is lost (deleted, corrupted, or never configured a remote backend). Everything must be deleted manually via gcloud CLI in reverse dependency order.

**How this happens:** State loss typically occurs when using a local backend (`terraform.tfstate` file) and the file is deleted during a directory restructure, or a remote GCS backend was never configured.

> ### ⚠️ Shared projects — scope every delete
>
> A GCP project frequently hosts more than one LangSmith stack (several engineers'
> test deployments, or test alongside prod). Broad filters such as
> `--filter="name~langsmith"` match **every** tenant. Filter-based delete loops
> (firewall, subnets) are not interactive. B6 asks for confirmation and deletes
> only the captured list.
>
> Before running anything below, list what else lives in the project:
>
> ```bash
> gcloud container clusters list --project "$PROJECT_ID"
> gcloud sql instances list --project "$PROJECT_ID"
> ```
>
> If anything other than your own stack appears, delete by **explicit resource name**
> rather than by filter. Each step below is scoped to `$PREFIX`; do not widen it.

## B0 — Inventory What Exists

### Naming reference

Resource names come from `infra/locals.tf`. The random `unique_suffix` is **not** applied
uniformly — getting this wrong is the most common source of "resource not found" errors.
`unique_suffix` defaults to `true`. When it is `false`, the rows marked "if enabled"
have no `-<suffix>` (for example Cloud SQL is `$PREFIX-pg`).

| Resource | Name | Suffix? |
|---|---|---|
| GKE cluster | `$PREFIX-gke` | no |
| Node pool | `$PREFIX-nodepool` | no |
| VPC | `$PREFIX-vpc` | no |
| Subnet | `$PREFIX-subnet` | no |
| Cloud Router | `$PREFIX-router` | no |
| Cloud NAT | `$PREFIX-nat` | no |
| PSA reserved range | `$PREFIX-vpc-private-ip` | no |
| Cloud SQL | `$PREFIX-pg` or `$PREFIX-pg-<suffix>` | if `unique_suffix=true` (default) |
| Memorystore Redis | `$PREFIX-redis` or `$PREFIX-redis-<suffix>` | if enabled |
| JuiceFS Redis | `$PREFIX-jfs-redis` or `$PREFIX-jfs-redis-<suffix>` | if enabled |
| GCS traces bucket | `$PROJECT_ID-$PREFIX-traces` or `...-traces-<suffix>` | if enabled; always prefixed with the project ID |
| SmithDB object-store bucket | `$PROJECT_ID-$PREFIX-smithdb` or `...-smithdb-<suffix>` | if enabled; only when `enable_smithdb=true` |
| SmithDB metastore | `$PREFIX-smithdb-pg` or `$PREFIX-smithdb-pg-<suffix>` | if enabled |
| Workload Identity SA | `<name_prefix>-langsmith` | no — **`name_prefix` only, no `environment`** |
| Sandbox-host node SA | `$PREFIX-sbox-node` | no — only when `enable_sandboxes=true` |
| SmithDB SA | `$PREFIX-smithdb-sa` | no — only when `enable_smithdb=true` |
| Secret Manager | `langsmith-$PREFIX-<key>` | no |

Two names break the `$PREFIX-*` pattern and are easy to miss: GCS buckets are prefixed
with the **project ID**, and the Workload Identity SA uses **`name_prefix` alone** — for
`name_prefix=acme`, `environment=test`, the SA is `acme-langsmith`, not `acme-test-langsmith`.
The sandbox-host node SA and the SmithDB SA do include `environment` (`$PREFIX-...`).

### Build the inventory

```bash
PROJECT_ID="<your-project-id>"
REGION="<region>"
PREFIX="<name_prefix>-<environment>"
NAME_PREFIX="<name_prefix>"          # without environment — for the service account

echo "=== GKE ===" && gcloud container clusters list --project "$PROJECT_ID" --filter="name~$PREFIX"
echo "=== Cloud SQL ===" && gcloud sql instances list --project "$PROJECT_ID" --filter="name~$PREFIX"
echo "=== Memorystore ===" && gcloud redis instances list --region "$REGION" --project "$PROJECT_ID" --filter="name~$PREFIX"
echo "=== GCS ===" && gcloud storage ls --project "$PROJECT_ID" 2>/dev/null | grep "$PREFIX"
echo "=== VPC ===" && gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX"
echo "=== Subnets ===" && gcloud compute networks subnets list --project "$PROJECT_ID" --filter="network~$PREFIX-vpc"
echo "=== Firewall ===" && gcloud compute firewall-rules list --project "$PROJECT_ID" --filter="network~$PREFIX-vpc"
echo "=== PSA range ===" && gcloud compute addresses list --project "$PROJECT_ID" --global --filter="name~$PREFIX"
echo "=== Peerings ===" && gcloud services vpc-peerings list --network="$PREFIX-vpc" --project "$PROJECT_ID"
echo "=== Service Accounts ===" && gcloud iam service-accounts list --project "$PROJECT_ID" \
  --filter="email~$NAME_PREFIX-langsmith OR email~$PREFIX-sbox-node OR email~$PREFIX-smithdb-sa"
echo "=== Secret Manager ===" && gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith-$PREFIX-"
```

Also record the dynamically provisioned Persistent Disks before touching the cluster —
they are not Terraform-managed and are orphaned if the cluster goes first (see B1):

```bash
kubectl get pv -o custom-columns='PV:.metadata.name,SIZE:.spec.capacity.storage,CLAIM:.spec.claimRef.name'
```

## B1 — Remove Kubernetes Resources

Get cluster credentials first, then **confirm the context** — every command below is
destructive and `kubectl` silently targets whatever context is active:

```bash
gcloud container clusters get-credentials "$PREFIX-gke" \
  --region "$REGION" --project "$PROJECT_ID"

kubectl config current-context     # must be gke_<project>_<region>_<PREFIX>-gke
```

> **`./helm/scripts/uninstall.sh` does not work in this scenario.** It resolves the target
> cluster from `infra/terraform.tfvars` plus `terraform output`, and exits with
> `ERROR: terraform.tfvars not found` when either is missing — which is exactly the
> Option B situation. Use the manual sequence below instead. (With state intact, prefer
> the script — see A2.)

Remove Kubernetes resources in this order:

```bash
# 1. LangGraph Platform deployments. The operator reclaims their PVCs, so let it
#    finish before deleting the CRD.
kubectl delete lgp --all -n langsmith --timeout=300s 2>/dev/null || true
kubectl delete crd lgps.apps.langchain.ai 2>/dev/null || true

# 2. ScaledObjects before KEDA (clears finalizers)
kubectl delete scaledobjects --all -n langsmith 2>/dev/null || true

# 3. Sandboxes / JuiceFS — ONLY if enabled. Delete the consumer and its claims while
#    the CSI driver is still running, or mount pods hang on juicefs.com/finalizer with
#    no controller left to clear it.
#    Use while-read (not xargs -r): -r is GNU-only and macOS xargs rejects it, so
#    the deletes would be skipped and helm uninstall would hang on JuiceFS finalizers.
while IFS= read -r _obj; do
  [[ -z "$_obj" ]] && continue
  kubectl delete "$_obj" -n langsmith --timeout=120s
done < <(kubectl get deployments,statefulsets -n langsmith -o name 2>/dev/null | grep -i 'sandbox-host' || true)
while IFS= read -r _obj; do
  [[ -z "$_obj" ]] && continue
  kubectl delete "$_obj" -n langsmith --timeout=120s
done < <(kubectl get pvc -n langsmith -o name 2>/dev/null | grep -Ei 'juicefs|smithbox' || true)

# 4. LangSmith release
helm uninstall langsmith -n langsmith --timeout=10m

# 5. Operator-managed leftovers (no Helm owner reference). Label-scoped so other
#    teams' workloads in a shared namespace are untouched.
kubectl delete deployments,services,pods,jobs,statefulsets,replicasets \
  -l "app.kubernetes.io/instance=langsmith" -n langsmith --ignore-not-found --timeout=120s
kubectl delete deployments,pods \
  -l "langsmith.dev/managed-by=operator" -n langsmith --ignore-not-found --timeout=120s

# 6. ClickHouse data PVC — reclaims the GCE PD while CSI is alive. TRACE DATA IS DELETED.
kubectl delete pvc -n langsmith -l app.kubernetes.io/component=clickhouse --ignore-not-found --timeout=120s
while IFS= read -r _obj; do
  [[ -z "$_obj" ]] && continue
  kubectl delete "$_obj" -n langsmith --timeout=120s
done < <(kubectl get pvc -n langsmith -o name 2>/dev/null | grep -i clickhouse || true)

# 7. Remaining bootstrap releases
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
helm uninstall envoy-gateway -n envoy-gateway-system 2>/dev/null || true

# 8. Namespaces
kubectl delete namespace langsmith cert-manager keda envoy-gateway-system 2>/dev/null || true
```

**Verify the disks were reclaimed before deleting the cluster.** PVs use reclaim policy
`Delete`, so the CSI driver removes the backing PD when the claim goes — but only while the
cluster still exists. Anything left here becomes an untracked orphan that is very hard to
attribute later:

```bash
kubectl get pv 2>/dev/null            # expect: no resources
gcloud compute disks list --project "$PROJECT_ID" --filter="name~^pvc-" \
  --format="table(name,zone,sizeGb,users)"
```

Cross-check any remaining `pvc-*` disks against the PV list captured in B0. A disk with no
`users` and no matching PV is an orphan from this stack.

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

# Delete the cluster (this also deletes node pools). The cluster name carries no suffix.
gcloud container clusters delete "$PREFIX-gke" \
  --region "$REGION" --project "$PROJECT_ID" --quiet
```

> GKE cluster deletion takes ~5 minutes. It automatically releases the external IP used by the Envoy Gateway.

Deleting the cluster also removes its node boot disks, the GKE-managed private-endpoint
subnet (`gke-$PREFIX-gke-<hash>-pe-subnet`), and the `gke-$PREFIX-gke-<hash>-*` firewall
rules. It does **not** reliably remove the `k8s-*` firewall rules created for
LoadBalancer services — check for leftovers in B8, since a rule still attached to the VPC
blocks the VPC delete.

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
the identical name will fail. The module sidesteps this with `unique_suffix`
(default `true`), which appends a random suffix to instance names. If
`unique_suffix=false`, the instance is `$PREFIX-pg` with no suffix — list first
and use the exact name.

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

The bucket name is prefixed with the **project ID**, unlike every other resource — confirm
it before deleting:

```bash
gcloud storage ls --project "$PROJECT_ID" | grep "$PREFIX"
```

Use the exact names from that listing. Default names when `unique_suffix=true`:

```bash
TRACES_BUCKET="gs://$PROJECT_ID-$PREFIX-traces-<suffix>"
# unique_suffix=false: gs://$PROJECT_ID-$PREFIX-traces

# Remove all objects including noncurrent versions, then the bucket itself
gcloud storage rm -r --all-versions "$TRACES_BUCKET" --project "$PROJECT_ID"
```

When `enable_smithdb=true`, a second bucket holds SmithDB segments. Delete it the same way:

```bash
SMITHDB_BUCKET="gs://$PROJECT_ID-$PREFIX-smithdb-<suffix>"
# unique_suffix=false: gs://$PROJECT_ID-$PREFIX-smithdb
gcloud storage rm -r --all-versions "$SMITHDB_BUCKET" --project "$PROJECT_ID"
```

`gcloud storage rm -r` removes the bucket along with its contents, so a separate
`buckets delete` is normally unnecessary. If a bucket survives (objects added mid-delete),
remove it explicitly:

```bash
gcloud storage buckets delete "$TRACES_BUCKET" --project "$PROJECT_ID"
# gcloud storage buckets delete "$SMITHDB_BUCKET" --project "$PROJECT_ID"
```

## B6 — Delete Secret Manager Secrets

> ### 🛑 Do not filter on `langsmith` alone
>
> Secrets are named `langsmith-<name_prefix>-<environment>-<key>`, so **every** stack in
> the project starts with `langsmith-`. A filter of `name~langsmith` matches all of them,
> and piping that into `gcloud secrets delete --quiet` destroys other tenants' credentials
> with no prompt and no undo. Always include `$PREFIX` **and** the trailing hyphen:
> `name~langsmith-$PREFIX-`.
>
> Without the trailing hyphen, `PREFIX=acme-test` also matches `acme-test-2`.

Two naming patterns exist. The `setup-env.sh` / `manage-secrets.sh` scripts create
`langsmith-$PREFIX-<key>`; the Terraform `secrets` module creates a single
`$PREFIX-langsmith`. Capture the list once, read it, confirm, then delete **that**
list — do not re-run the filter into `delete`.

```bash
# Capture and review — do not delete yet
SECRETS=$(gcloud secrets list --project "$PROJECT_ID" \
  --filter="name~langsmith-$PREFIX- OR name=$PREFIX-langsmith" \
  --format="value(name)")
printf '%s\n' "$SECRETS"

printf "Delete only the secrets printed above? [y/N] "
read -r _confirm
if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
  echo "Skipped secret deletion."
else
  while IFS= read -r secret; do
    [[ -z "$secret" ]] && continue
    echo "deleting $secret"
    gcloud secrets delete "$secret" --project "$PROJECT_ID" --quiet
  done <<< "$SECRETS"
fi
```

If `enable_secret_manager_module = false` and secrets were never seeded, this step returns
nothing — that is expected, not an error.

## B7 — Delete Workload Identity Service Account

The Workload Identity SA uses **`name_prefix` only** — it does not include `environment`.
For `name_prefix=acme`, `environment=test`, the account is `acme-langsmith`, not
`acme-test-langsmith`, so a `$PREFIX`-based filter finds nothing. The sandbox-host node
SA and the SmithDB SA **do** include environment (`$PREFIX-sbox-node`, `$PREFIX-smithdb-sa`).

```bash
# List first — confirm each email belongs to this stack
gcloud iam service-accounts list --project "$PROJECT_ID" \
  --filter="email~$NAME_PREFIX-langsmith OR email~$PREFIX-sbox-node OR email~$PREFIX-smithdb-sa" \
  --format="value(email)"

# Workload Identity (enable_gcp_iam_module=true)
gcloud iam service-accounts delete "$NAME_PREFIX-langsmith@$PROJECT_ID.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" --quiet

# Sandbox-host node (enable_sandboxes=true)
gcloud iam service-accounts delete "$PREFIX-sbox-node@$PROJECT_ID.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" --quiet 2>/dev/null || true

# SmithDB (enable_smithdb=true)
gcloud iam service-accounts delete "$PREFIX-smithdb-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --project "$PROJECT_ID" --quiet 2>/dev/null || true
```

Nothing is returned when the matching module flag is false. In a shared project take care
that `$NAME_PREFIX` is specific enough — a short prefix can substring-match another
stack's Workload Identity account.

## B8 — Delete VPC and Networking

**Must be done last.** Order matters — subnets cannot be deleted while GKE is still running.

The VPC, subnet, router, and NAT names carry **no** random suffix.

```bash
VPC_NAME="$PREFIX-vpc"

# 1. Delete Cloud NAT
gcloud compute routers nats delete "$PREFIX-nat" \
  --router="$PREFIX-router" \
  --region="$REGION" --project "$PROJECT_ID" --quiet

# 2. Delete Cloud Router
gcloud compute routers delete "$PREFIX-router" \
  --region="$REGION" --project "$PROJECT_ID" --quiet

# 3. Delete firewall rules. A rule still attached to the VPC blocks the VPC delete.
#    This catches both the module's own rules and any k8s-* LoadBalancer leftovers.
for fw in $(gcloud compute firewall-rules list --project "$PROJECT_ID" \
  --filter="network~$VPC_NAME" --format="value(name)"); do
  gcloud compute firewall-rules delete "$fw" --project "$PROJECT_ID" --quiet
done

# 4. Delete subnets
for subnet in $(gcloud compute networks subnets list \
  --network="$VPC_NAME" --project "$PROJECT_ID" --format="value(name)"); do
  gcloud compute networks subnets delete "$subnet" \
    --region="$REGION" --project "$PROJECT_ID" --quiet
done

# 5. Remove private service connection (VPC peering for Cloud SQL / Memorystore)
gcloud services vpc-peerings delete \
  --network="$VPC_NAME" --project "$PROJECT_ID" --quiet

# 6. Release the PSA reserved range. Terraform creates this global address for the
#    private service connection; it is not removed with the peering.
gcloud compute addresses delete "$VPC_NAME-private-ip" \
  --global --project "$PROJECT_ID" --quiet

# 7. Delete the VPC
gcloud compute networks delete "$VPC_NAME" --project "$PROJECT_ID" --quiet
```

### Known issue — private service connection will not delete

Step 5 commonly fails with:

```
Failed to delete connection; Producer services (e.g. CloudSQL, Cloud Memstore, etc.)
are still using this connection.   [FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION]
```

This is usually stale state in the service-networking backend rather than a real consumer.
**First rule out an actual leftover** — note that `--region=-` searches all regions, which
matters if an instance was created outside `$REGION`:

```bash
gcloud sql instances list --project "$PROJECT_ID" \
  --format="value(name,settings.ipConfiguration.privateNetwork)" | grep "$VPC_NAME"
gcloud redis instances list --region=- --project "$PROJECT_ID" \
  --format="value(name,authorizedNetwork)" | grep "$VPC_NAME"
gcloud filestore instances list --project "$PROJECT_ID" \
  --format="value(name,networks.network)" | grep "$VPC_NAME"
```

If a producer instance is listed, delete it and retry. If all three return nothing, the
connection is stale. Retry step 5 periodically — propagation is usually a couple of minutes
but has been observed to exceed 15 with no upper bound.

When retrying is not converging, remove the peering at the compute layer instead. This
bypasses the service-networking API and takes effect immediately:

```bash
gcloud compute networks peerings delete servicenetworking-googleapis-com \
  --network="$VPC_NAME" --project "$PROJECT_ID"
```

Only do this once the three checks above come back empty — with a live producer instance
it strands the resource behind an unreachable peering. It is safe when the VPC is being
deleted anyway, which is the case here.

### Verifying peering removal

Check **both** sides. `gcloud compute networks peerings list --format="value(name)"` is a
trap: `name` there is the *network* name, not the peering name, so grepping it for
`servicenetworking` never matches and an unfinished delete looks complete. Use:

```bash
# Service-networking side — empty output means removed
gcloud services vpc-peerings list --network="$VPC_NAME" --project "$PROJECT_ID" \
  --format="value(peering)"

# Compute side — "Listed 0 items." means removed
gcloud compute networks peerings list --project "$PROJECT_ID" --network="$VPC_NAME"
```

## B9 — Verify Cleanup

```bash
chk() {
  local label="$1"
  shift
  local r
  r=$("$@" 2>&1) || true
  if [[ -z "$r" ]]; then
    echo "OK $label: clean"
  else
    echo "FAIL $label: still present"
    echo "$r"
  fi
}

chk "GKE"       gcloud container clusters list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Cloud SQL" gcloud sql instances list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Redis"     gcloud redis instances list --region=- --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
# GCS: grep the listing yourself in a shared project — other buckets must remain.
_gcs=$(gcloud storage ls --project "$PROJECT_ID" 2>/dev/null | grep "$PREFIX" || true)
if [[ -z "$_gcs" ]]; then echo "OK GCS: clean"; else echo "FAIL GCS: still present"; echo "$_gcs"; fi
chk "VPC"       gcloud compute networks list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Subnets"   gcloud compute networks subnets list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Firewall"  gcloud compute firewall-rules list --project "$PROJECT_ID" --filter="network~$PREFIX-vpc" --format="value(name)"
chk "Routers"   gcloud compute routers list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Addresses" gcloud compute addresses list --project "$PROJECT_ID" --global --filter="name~$PREFIX" --format="value(name)"
chk "Disks (named)" gcloud compute disks list --project "$PROJECT_ID" --filter="name~$PREFIX" --format="value(name)"
chk "Disks (pvc-*)" gcloud compute disks list --project "$PROJECT_ID" --filter="name~^pvc-" --format="value(name)"
chk "IAM SA (WI)" gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$NAME_PREFIX-langsmith" --format="value(email)"
chk "IAM SA (sandbox node)" gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$PREFIX-sbox-node" --format="value(email)"
chk "IAM SA (SmithDB)" gcloud iam service-accounts list --project "$PROJECT_ID" --filter="email~$PREFIX-smithdb-sa" --format="value(email)"
chk "Secrets"   gcloud secrets list --project "$PROJECT_ID" --filter="name~langsmith-$PREFIX-" --format="value(name)"
```

`Firewall` is filtered by **network**, not by rule name. `k8s-*` LoadBalancer rules
do not contain `$PREFIX` in the name; a name filter would report clean while B8 still
fails. `Disks (pvc-*)` lists every dynamically provisioned disk in the project. In a
shared project that is not proof of ownership — compare against the B0 PV inventory.

### Blast-radius check (shared projects)

Confirm you removed only your own stack. Compare against the inventory taken before
teardown — everything else should still be there:

```bash
gcloud container clusters list --project "$PROJECT_ID" --format="value(name)"
gcloud sql instances list --project "$PROJECT_ID" --format="value(name)"
gcloud secrets list --project "$PROJECT_ID" --format="value(name)" | wc -l
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
- **Scope every filter in a shared project.** `--filter="name~langsmith"` matches every tenant's secrets, not just yours. Scope to `langsmith-$PREFIX-`, capture the list, confirm, then delete that captured list — do not re-run the filter into `gcloud secrets delete --quiet`.
- **`unique_suffix` is not applied uniformly.** Cluster, VPC, subnet, router, and NAT never carry a suffix. Cloud SQL, Redis, and buckets get `-<suffix>` only when `unique_suffix=true` (the default). The GCS buckets are additionally prefixed with the project ID. The Workload Identity SA uses `name_prefix` **without** `environment`; the sandbox-host node SA and SmithDB SA use `$PREFIX`. See the naming table in B0.
- **`./helm/scripts/uninstall.sh` cannot run without state.** It resolves the cluster from `terraform.tfvars` plus `terraform output`, so it fails in the very scenario Option B describes. B1 carries the manual equivalent.
- **Delete PVCs before the cluster, and verify the disks are gone.** Reclaim is the CSI driver's job and it dies with the cluster. Orphaned `pvc-*` disks carry no stack identifier — only a `created-for` namespace annotation — so when two clusters in a project share a namespace name, ownership becomes unprovable and the disks are stranded indefinitely.
- **`k8s-*` LoadBalancer firewall rules can survive cluster deletion** and will block the VPC delete. B8 step 3 sweeps every rule attached to the VPC.
- **The PSA reserved range is a separate resource.** `$PREFIX-vpc-private-ip` is not removed with the peering and must be deleted before the VPC.
- **Verify peering removal on both sides.** `gcloud compute networks peerings list --format="value(name)"` returns the *network* name, not the peering name — grepping it for `servicenetworking` silently reports success on an unfinished delete. Use `gcloud services vpc-peerings list --format="value(peering)"`.
- **The PSA delete can stay blocked well past "a couple of minutes."** `FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION` persists after the producer instances are gone. Once Cloud SQL, Redis (all regions), and Filestore all come back empty for the VPC, drop to `gcloud compute networks peerings delete`.
- **JuiceFS CSI lives in the LangSmith Helm release.** Uninstall the sandbox-host workload and JuiceFS claims before `helm uninstall`, or mount pods stay `Terminating` with `juicefs.com/finalizer` and namespace delete hangs. Use `./helm/scripts/uninstall.sh`.
- **In-cluster ClickHouse uses a dynamically provisioned GCE PD** (`premium-rwo`). Terraform does not track it. Run `DELETE_DATA_PVCS=true make uninstall` before `terraform destroy`, or the disk is orphaned.
- **Terraform validates `postgres_password` on destroy.** Source `infra/scripts/setup-env.sh` first. If the Secret Manager secret is already gone, set `export TF_VAR_postgres_password="any-placeholder"`.
- **The Cloud SQL database is destroyed before its user.** `google_sql_database` carries a `depends_on` for the matching `google_sql_user`, because Cloud SQL rejects `DROP ROLE` while the role owns objects (`role "langsmith" cannot be dropped because some objects depend on it`). On a stack built before that edge existed, re-run `terraform destroy` once the database is gone.
- **KEDA finalizers block namespace deletion** if the KEDA controller is uninstalled first — delete ScaledObjects before uninstalling KEDA, or patch out finalizers manually.
- **The LGP CRD is kept by resource policy** — `helm uninstall` will not remove it; delete it manually with `kubectl delete crd lgps.apps.langchain.ai`.
- **GKE deletion releases the external IP** — if you re-deploy, a new IP is issued. Update your DNS A record. To avoid this, use a static regional IP (not currently wired in this stack).
- **Private service connection peering** (`servicenetworking-googleapis-com`) must be removed before the VPC can be deleted. It's not created by Terraform directly — it's managed by the `servicenetworking` API. The `gcloud services vpc-peerings delete` command removes it.
- **Cloud SQL deletion takes ~2 minutes** — the VPC peering is not released until the instance is fully gone. Wait before attempting VPC cleanup.
- **GCS bucket with versioned objects** — requires `gcloud storage rm -r --all-versions` (noncurrent versions included); a plain recursive delete leaves them behind and the bucket delete then fails.
