# GCP LangSmith — Pass 1 Test Cycle

Repeatable runbook for deploying and tearing down the GCP infra layer (Pass 1 — Terraform only).
Run this before merging changes to validate everything works end-to-end.

**Scope**: Terraform infra only. Helm/Pass 2 is a separate cycle — stop after the verification
checklist below.

---

## Prerequisites

**Tools required** (all must be in PATH):
- `gcloud` CLI — authenticated to the target project
- `terraform` v1.5+
- `kubectl`
- `helm` v3+

**GCP roles required** (verify with `gcloud projects get-iam-policy <project-id>`):
- `roles/container.admin` — GKE cluster create/delete
- `roles/compute.networkAdmin` — VPC, subnets, Cloud NAT, firewall rules
- `roles/iam.serviceAccountAdmin` + `roles/iam.workloadIdentityUser` — Workload Identity setup
- `roles/cloudsql.admin` — Cloud SQL instance create/delete
- `roles/redis.admin` — Memorystore instance create/delete
- `roles/storage.admin` — GCS bucket create/delete
- `roles/servicenetworking.networksAdmin` — VPC peering for Cloud SQL / Memorystore
- `roles/secretmanager.admin` — Secret Manager (if `enable_secret_manager_module = true`)

**Bootstrap requirement**: `cloudresourcemanager.googleapis.com` must be enabled before first apply:
```bash
gcloud services enable cloudresourcemanager.googleapis.com --project <project-id>
```

---

## Bare Minimum Test Config

`gcp/infra/terraform.tfvars` must include:

```hcl
project_id                    = "your-gcp-project-id"
name_prefix                   = "yourname"      # lowercase, ≤ 11 chars
environment                   = "dev"
postgres_deletion_protection  = false           # required for clean terraform destroy after test
gke_deletion_protection       = false           # required for clean terraform destroy after test
tls_certificate_source        = "none"          # HTTP only — no cert-manager or Let's Encrypt needed
```

All other defaults are fine for testing. A typical dev config:
- GKE: `e2-standard-4`, `REGULAR` release channel, 2–4 nodes
- Cloud SQL: `db-custom-2-8192`, 50 GB
- Memorystore: 5 GB, `STANDARD_HA`

---

## Pass 1 Procedure

Run all commands from the `gcp/` directory.

### Step 0 — Verify GCP credentials
```bash
gcloud auth print-access-token > /dev/null && echo "Authenticated"
gcloud config get-value project
```
Confirm the project ID matches the target deployment.

### Step 1 — Preflight check
```bash
./infra/scripts/preflight.sh
```
All checks must be green before proceeding.

### Step 2 — Init
```bash
terraform -chdir=infra init
```
Downloads all providers and modules. Typical duration: 1–2 min.

### Step 3 — Validate
```bash
terraform -chdir=infra validate
```
Must return `Success! The configuration is valid.` — fix any errors before continuing.

### Step 4 — Plan
```bash
terraform -chdir=infra plan
```
Review the plan. Expected resource categories:
- VPC, subnet, secondary IP ranges (pods/services), Cloud NAT, Cloud Router
- GKE cluster, node pool, Workload Identity binding
- Cloud SQL PostgreSQL instance, database, user, private IP allocation
- Memorystore Redis instance
- Cloud Storage bucket + lifecycle rules
- GCP service account + IAM bindings (storage.objectAdmin, secretmanager.secretAccessor)
- Kubernetes namespace `langsmith`, K8s Secrets (`langsmith-postgres`, `langsmith-redis`)
- Helm releases: ESO (external-secrets), optionally KEDA, optionally cert-manager
- Envoy Gateway (GatewayClass + Gateway resources)
- GCP API enablement (12 services)

Confirm no unexpected `destroy` or `replace` actions on existing resources.

### Step 5 — Apply
```bash
terraform -chdir=infra apply
```
Typical duration: **25–40 min** (GKE cluster provisioning takes ~15–20 min; Cloud SQL adds 10 min).

If apply fails partway through, it is safe to re-run — Terraform is idempotent.

---

## Verification Checklist

Run these after `apply` completes successfully.

### Cluster access
```bash
eval "$(terraform -chdir=infra output -raw get_credentials_command)"
kubectl get nodes
```
Expected: 2+ nodes in `Ready` state.

### System pods
```bash
kubectl get pods -n kube-system
```
Expected `Running`: `coredns-*`, `fluentbit-*`, `kube-dns-*`, `kube-proxy-*`, `metrics-server-*`.

### Bootstrap components (Pass 2 prerequisites)
```bash
kubectl get pods -n external-secrets   # ESO controller + cert-controller + webhook
kubectl get pods -n keda               # KEDA controller (if enable_langsmith_deployment=true)
kubectl get pods -n cert-manager       # cert-manager (if tls_certificate_source=letsencrypt)
kubectl get pods -n envoy-gateway-system  # Envoy Gateway controller
```

### LangSmith namespace
```bash
kubectl get all -n langsmith
kubectl get secret -n langsmith
```
Expected: namespace exists, `langsmith-postgres` and `langsmith-redis` secrets present.

### Workload Identity
```bash
terraform -chdir=infra output workload_identity_service_account_email
terraform -chdir=infra output workload_identity_annotation
```
Both must be non-null if `enable_gcp_iam_module = true` (default).

### Gateway
```bash
kubectl get gateway -n langsmith
```
Expected: `PROGRAMMED = True`. External IP may show as `pending` until a `HTTPRoute` (Helm) is deployed.

### Terraform outputs
```bash
terraform -chdir=infra output storage_bucket_name
terraform -chdir=infra output cluster_name
terraform -chdir=infra output ingress_type
```

---

## Optional Modules

Test each module as an incremental apply on top of the existing baseline.

### Secret Manager

```hcl
# terraform.tfvars
enable_secret_manager_module = true
```

**Expected plan**: `+N` resources — `google_secret_manager_secret.*`, `google_secret_manager_secret_version.*`.

**Verify**:
```bash
NAME_PREFIX=$(grep '^name_prefix' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
ENVIRONMENT=$(grep '^environment' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
gcloud secrets list --filter="name:${NAME_PREFIX}-${ENVIRONMENT}" --project <project-id>
terraform -chdir=infra output secret_manager_secret_id
```

---

### DNS + Managed Certificate

```hcl
# terraform.tfvars
enable_dns_module    = true
langsmith_domain     = "langsmith.example.com"
dns_create_zone      = true
dns_create_certificate = true
```

**Expected plan**: `google_dns_managed_zone.*`, `google_certificate_manager_certificate.*`.

**Verify**:
```bash
terraform -chdir=infra output dns_name_servers
terraform -chdir=infra output managed_certificate_name
```
Delegate the domain to the returned name servers, then wait for the certificate to provision (can take 10–60 min after DNS propagates).

---

### Let's Encrypt TLS

```hcl
# terraform.tfvars
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "ops@example.com"
langsmith_domain       = "langsmith.example.com"
```

**Expected plan**: cert-manager Helm release, `ClusterIssuer` resources.

**Verify**:
```bash
kubectl get clusterissuer -n cert-manager
kubectl get certificate -n langsmith
```

---

### KEDA (Deployments feature)

```hcl
# terraform.tfvars
enable_langsmith_deployment = true
```

**Expected plan**: KEDA Helm release.

**Verify**:
```bash
kubectl get pods -n keda
terraform -chdir=infra output keda_installed   # true
```

---

## Known Issues & Fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| APIs not enabled | `Error 403: ... has not been used in project ... before or it is disabled` | Enable bootstrap API first: `gcloud services enable cloudresourcemanager.googleapis.com` then re-apply |
| `null_resource.wait_for_cluster` times out | `ERROR: API server did not become accessible in time` | GKE cluster provisioning took longer than expected. Re-run `terraform apply` — the cluster is likely ready by the time you retry. |
| Workload Identity binding not ready | `Error: googleapi: Error 400: Service account does not exist` | The GCP service account may not have fully propagated. Wait 30 s and re-apply. |
| ESO or KEDA Helm release times out | `context deadline exceeded` on k8s_bootstrap module | Uninstall the stuck release, then re-apply: `helm uninstall external-secrets -n external-secrets` |
| Cloud SQL private IP allocation fails | `Error: servicenetworking.services.addPeering ... quota exceeded` | The project may have hit the default limit for VPC peering connections. Check in GCP Console → VPC Network → VPC Network Peering. |
| GKE node pool not ready during apply | Pods `Pending`, StorageClass creation fails | Wait for node pool to become active — typically resolves on re-apply. |
| `redis_prevent_destroy = true` blocks destroy | `Error: Instance is protected from destroy` | Set `redis_prevent_destroy = false` in terraform.tfvars and re-apply before destroying. |
| Envoy Gateway `Gateway` stuck Pending | `kubectl get gateway -n langsmith` shows no address | No HTTPRoute deployed yet — install LangSmith via Helm (Pass 2) to trigger route creation and external IP assignment. |
| GKE cluster deletion protection | `Error: Cluster has deletion protection enabled` | Set `gke_deletion_protection = false` in terraform.tfvars and re-apply before destroying. |

---

## Teardown

```bash
# 1. Remove Helm releases managed by k8s-bootstrap (prevents stuck finalizers)
helm uninstall external-secrets -n external-secrets 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
helm uninstall envoy-gateway -n envoy-gateway-system 2>/dev/null || true

# 2. Destroy all infrastructure
terraform -chdir=infra destroy
```

**Before destroy, verify:**
- `postgres_deletion_protection = false` is set in `terraform.tfvars`
- `gke_deletion_protection = false` is set in `terraform.tfvars`
- `redis_prevent_destroy = false` (default) in `terraform.tfvars`

**If destroy hangs on the VPC**: Envoy Gateway or other controllers may have created load balancer resources with forwarding rules attached to the VPC. Check GCP Console → Network Services → Load Balancing and delete any LangSmith-related forwarding rules manually, then re-run destroy.

---

## Secret Reference

Core secrets are written as K8s Secrets by the k8s-bootstrap Terraform module:

| K8s Secret | Namespace | Contents |
|------------|-----------|---------|
| `langsmith-postgres` | `langsmith` | `connection_url` — full Postgres connection string |
| `langsmith-redis` | `langsmith` | `connection_url` — Redis connection URL |

Secrets that must be provided for Helm (via `--set` or in `values-overrides.yaml`):

| Secret | How to generate | Rotatable |
|--------|----------------|-----------|
| `config.langsmithLicenseKey` | Provided by LangChain | N/A |
| `config.apiKeySalt` | `openssl rand -base64 32` | **Never** — invalidates all API keys |
| `config.basicAuth.jwtSecret` | `openssl rand -base64 32` | **Never** — invalidates all sessions |
| `config.basicAuth.initialOrgAdminPassword` | User-defined | Yes |
| `config.agentBuilder.encryptionKey` | `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` | Requires re-encryption |
| `config.insights.encryptionKey` | Same as above | Requires re-encryption |
| `config.blobStorage.accessKey` | GCP Console → Cloud Storage → Interoperability → HMAC Keys | Yes |
| `config.blobStorage.accessKeySecret` | Same | Yes |
