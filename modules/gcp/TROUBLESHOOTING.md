# LangSmith on GCP — Troubleshooting Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before upgrading for breaking changes and required variable updates.

Run `gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>` before using any `kubectl` commands.

---

## Known Issues

### Issue #1 — terraform apply fails: GCP APIs not enabled

**Symptom:**
```
Error 403: ... has not been used in project <project-id> before or it is disabled.
Enable it by visiting https://console.cloud.google.com/apis/api/container.googleapis.com/
```

**Cause:** Required GCP APIs are not enabled. Terraform enables them via `google_project_service` resources but needs `cloudresourcemanager.googleapis.com` to already be enabled to do so.

**Fix:** Enable the bootstrap API manually, then re-run apply:

```bash
gcloud services enable cloudresourcemanager.googleapis.com --project <project-id>

cd gcp/infra
terraform apply -var-file=terraform.tfvars
```

---

### Issue #2 — GKE cluster API server not accessible after apply

**Symptom:**
```
Error: Get "https://<cluster-endpoint>/api/v1/namespaces": dial tcp: connection refused
```
or `null_resource.wait_for_cluster` local-exec times out with `ERROR: API server did not become accessible in time`.

**Cause:** The GKE control plane takes 10–15 minutes to become fully operational. The `wait_for_cluster` resource polls for up to 10 minutes. On slow projects or new projects with cold-start API activation, this window can be exceeded.

**Fix:** Wait for the cluster to reach `RUNNING` status, then re-run apply:

```bash
gcloud container clusters describe <cluster-name> \
  --region <region> \
  --project <project-id> \
  --format="value(status)"
# Wait until output is: RUNNING

terraform apply -var-file=terraform.tfvars
```

---

### Issue #3 — GKE nodes not joining cluster (NotReady)

**Symptom:** `kubectl get nodes` shows no nodes or nodes stuck in `NotReady`.

**Cause:** Node pool service account lacks `roles/container.nodeServiceAccount`, or VPC firewall rules block node-to-control-plane communication.

**Fix:**

```bash
# Check the node pool service account
gcloud container node-pools describe <pool-name> \
  --cluster <cluster-name> --region <region> \
  --format="value(config.serviceAccount)"

# Grant required role if missing
gcloud projects add-iam-policy-binding <project-id> \
  --member="serviceAccount:<node-sa-email>" \
  --role="roles/container.nodeServiceAccount"

# Check firewall rules
gcloud compute firewall-rules list --filter="network:<vpc-name>"
```

---

### Issue #4 — Cloud SQL connection refused from GKE pods

**Symptom:** Backend logs show `connection refused` or `no route to host` for the Cloud SQL private IP.

**Cause:** The private service connection (VPC peering) is not established, or the allocated IP range is too small. This can happen if `servicenetworking.googleapis.com` was not enabled before the networking module ran.

**Fix:**

```bash
# Check VPC peerings
gcloud services vpc-peerings list --network <vpc-name> --project <project-id>

# Check Cloud SQL private IP
gcloud sql instances describe <instance-name> --format="value(ipAddresses)"

# Verify peering status
gcloud compute networks peerings list --network <vpc-name>
```

If peering is missing, ensure `enable_private_service_connection = true` in the networking module and re-apply:

```bash
terraform apply -var-file=terraform.tfvars -target=module.networking
terraform apply -var-file=terraform.tfvars
```

---

### Issue #5 — Memorystore Redis connection timeout

**Symptom:** Pods cannot connect to Redis. Logs show `dial tcp: connection timed out` or `redis: connection refused`.

**Cause:** The Memorystore instance `authorized_network` does not match the GKE VPC, or the Redis private IP is on a range not routable from the GKE subnet.

**Fix:**

```bash
# Check Redis instance details
gcloud redis instances describe <instance-name> --region <region> \
  --format="value(host,authorizedNetwork)"

# Test connectivity from a pod
kubectl run redis-test --rm -it --image=redis:7 -n langsmith -- \
  redis-cli -h <redis-private-ip> ping
# Expected: PONG
```

---

### Issue #6 — cert-manager fails to issue Let's Encrypt certificate

**Symptom:** `kubectl get certificate -n langsmith` shows `READY=False`. ACME HTTP01 challenge failing.

**Cause:** The DNS A record does not point to the Envoy Gateway IP, or port 80 is blocked by a firewall rule on the load balancer.

**Fix:**

```bash
# Get Gateway external IP
kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'

# Check certificate and challenge status
kubectl describe certificate <cert-name> -n langsmith
kubectl get challenges -n langsmith
kubectl describe challenge -n langsmith

# Verify DNS resolution
dig +short <your-langsmith-domain>
```

The DNS A record must resolve to the Gateway IP before the certificate can be issued. cert-manager's HTTP01 solver needs port 80 to be accessible from the internet.

---

### Issue #7 — GCS bucket access denied from LangSmith pods

**Symptom:** Backend logs show `AccessDeniedException: 403 Insufficient Permission` or `403 Forbidden` when writing to GCS.

**Cause:** HMAC credentials passed to Helm are incorrect, or the service account that owns the HMAC key does not have `roles/storage.objectAdmin` on the bucket.

**Fix:**

```bash
# Verify the bucket name in the Helm values
helm get values langsmith -n langsmith | grep bucketName

# Test HMAC credentials
gsutil config -a   # (configure with your HMAC key)
gsutil ls gs://<bucket-name>

# Check bucket IAM
gcloud storage buckets get-iam-policy gs://<bucket-name>
```

Create a new HMAC key in GCP Console: Storage > Settings > Interoperability > Create HMAC key. The key's service account must have `roles/storage.objectAdmin` on the bucket.

---

### Issue #8 — Envoy Gateway webhook blocking GKE operations

**Symptom:**
```
Error from server (InternalError): error when creating ...:
Internal error occurred: failed calling webhook "validate.gateway.envoyproxy.io": ...
```

**Cause:** The Envoy Gateway admission webhook is not ready or its `caBundle` is stale.

**Fix:**

```bash
# Check Envoy Gateway pods
kubectl get pods -n envoy-gateway-system

# Restart the deployment if pods are not Ready
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system
```

---

### Issue #9 — terraform destroy fails: deletion protection enabled

**Symptom:**
```
Error: Error deleting instance: googleapi: Error 409: The instance is protected from deletion.
```

**Cause:** `gke_deletion_protection = true` (default) or `postgres_deletion_protection = true` prevents Terraform from destroying the resources.

**Fix:** Disable deletion protection before destroying:

```hcl
# terraform.tfvars
gke_deletion_protection     = false
postgres_deletion_protection = false
```

```bash
terraform apply -var-file=terraform.tfvars
terraform destroy
```

---

### Issue #10 — Workload Identity not working (GCS permission denied)

**Symptom:**
```
AccessDeniedException: 403 <pod-service-account>@<project>.iam.gserviceaccount.com
  does not have storage.objects.create access to the Google Cloud Storage bucket.
```

**Cause:** The Kubernetes service account used by LangSmith pods is missing the Workload Identity annotation linking it to the GCP service account, or the GCP SA is missing the GCS IAM binding.

**Diagnosis:**
```bash
# Check annotation on the backend service account
kubectl get serviceaccount langsmith-backend -n langsmith \
  -o jsonpath='{.metadata.annotations}' | python3 -m json.tool

# Check the IAM binding on the GCS bucket
BUCKET=$(terraform -chdir=infra output -raw storage_bucket_name)
gsutil iam get gs://$BUCKET | grep -A3 "serviceAccount"

# Verify the GCP SA has the correct role
GSA=$(terraform -chdir=infra output -raw workload_identity_service_account_email)
gcloud projects get-iam-policy $(terraform -chdir=infra output -raw project_id 2>/dev/null || \
  grep project_id infra/terraform.tfvars | sed 's/.*=.*"\(.*\)".*/\1/') \
  --flatten="bindings[].members" --filter="bindings.members:$GSA"
```

**Fix:**
```bash
# Re-apply the IAM module to reset bindings
terraform -chdir=infra apply -target=module.iam

# Re-run init-values.sh to re-annotate all service accounts
make init-values

# Re-deploy to apply the annotations
make deploy
```

---

### Issue #11 — `langsmith-ksa` missing Workload Identity annotation

**Symptom:** Operator-spawned agent deployment pods fail to start or are stuck in `Pending`. Logs show permission errors or the agent bootstrap job hangs.

**Cause:** `langsmith-ksa` is created by the LangSmith operator (not Helm) and does not survive namespace teardowns or fresh cluster rebuilds. `deploy.sh` re-annotates it post-deploy, but if a previous deploy was interrupted the annotation may be missing.

**Diagnosis:**
```bash
kubectl get serviceaccount langsmith-ksa -n langsmith \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
```

**Fix:**
```bash
# Re-run deploy.sh — it idempotently creates and annotates langsmith-ksa
make deploy

# Or annotate manually:
WI=$(terraform -chdir=infra output -raw workload_identity_annotation)
kubectl create serviceaccount langsmith-ksa -n langsmith --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl annotate serviceaccount langsmith-ksa -n langsmith \
  iam.gke.io/gcp-service-account="$WI" --overwrite
```

---

### Issue #12 — Helm release stuck in `pending-upgrade`

**Symptom:**
```
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

**Cause:** A previous `helm upgrade` was interrupted (e.g. Ctrl+C during `--wait`). Helm left the release in a locked state.

**Fix:** `deploy.sh` detects and auto-recovers this state. If running manually:
```bash
helm rollback langsmith -n langsmith --wait --timeout 5m
# Then re-run the deploy
make deploy
```

---

### Issue #13 — Secret Manager access denied

**Symptom:**
```
ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission 'secretmanager.versions.access'
  denied on resource 'projects/.../secrets/...'
```

**Cause:** Either `secretmanager.googleapis.com` is not yet enabled (pre-apply), or the operator account lacks `roles/secretmanager.admin`.

**Diagnosis:**
```bash
# Check if the API is enabled
gcloud services list --enabled --project <project-id> | grep secretmanager

# Check your active account's roles
gcloud auth list
gcloud projects get-iam-policy <project-id> \
  --flatten="bindings[].members" \
  --filter="bindings.members:$(gcloud config get account)"
```

**Fix:**
```bash
# Enable the API if not yet done (Terraform does this on apply)
gcloud services enable secretmanager.googleapis.com --project <project-id>

# If your account is missing the role
gcloud projects add-iam-policy-binding <project-id> \
  --member="user:$(gcloud config get account)" \
  --role="roles/secretmanager.admin"
```

---

### Issue #14 — `langsmith-postgres` or `langsmith-redis` secret missing

**Symptom:** Pods crash with database connection errors immediately after deploy, or `kubectl get secrets -n langsmith` does not show `langsmith-postgres` / `langsmith-redis`.

**Cause:** The `k8s-bootstrap` Terraform module creates these secrets. They are absent if:
- `terraform apply` was not run, or failed partway through
- The namespace was deleted and not re-provisioned by Terraform

**Fix:**
```bash
# Re-apply the k8s-bootstrap module
terraform -chdir=infra apply -target=module.k8s_bootstrap

# Verify
kubectl get secret langsmith-postgres -n langsmith
kubectl get secret langsmith-redis -n langsmith
```

---

## Diagnostic Commands

### Cluster access

```bash
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>
kubectl config current-context
kubectl get nodes -o wide
```

### Pods

```bash
kubectl get pods -n langsmith
kubectl get pods -n langsmith -w
kubectl describe pod <pod-name> -n langsmith
kubectl logs <pod-name> -n langsmith --tail=50
kubectl logs <pod-name> -n langsmith --previous --tail=50
kubectl logs -n langsmith deploy/langsmith-backend --tail=100 -f
```

### TLS and certificates

```bash
kubectl get certificate -n langsmith
kubectl describe certificate <cert-name> -n langsmith
kubectl get challenges -n langsmith
kubectl get clusterissuer
```

### Gateway and load balancer

```bash
kubectl get gateway -n langsmith
kubectl get httproute -n langsmith
kubectl get svc -n envoy-gateway-system -o wide
kubectl get pods -n envoy-gateway-system
```

### Helm

```bash
helm status langsmith -n langsmith
helm history langsmith -n langsmith
helm get values langsmith -n langsmith
```

### LangSmith Deployments (Pass 3)

```bash
kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
kubectl get lgp -n langsmith
kubectl get crd | grep langchain
```

### Workload Identity and IAM

```bash
# Check WI annotation on a service account
kubectl get serviceaccount langsmith-backend -n langsmith \
  -o jsonpath='{.metadata.annotations}' | python3 -m json.tool

# Check langsmith-ksa annotation (operator pods)
kubectl get serviceaccount langsmith-ksa -n langsmith \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'

# Verify GCP SA IAM bindings on the bucket
BUCKET=$(terraform -chdir=infra output -raw storage_bucket_name 2>/dev/null)
gsutil iam get gs://$BUCKET

# List Workload Identity-enabled service accounts
gcloud iam service-accounts list --project <project-id> --filter="displayName:langsmith"
```

### Secrets and bootstrap

```bash
# List all LangSmith K8s secrets
kubectl get secrets -n langsmith

# Check that bootstrap secrets exist
kubectl get secret langsmith-postgres -n langsmith
kubectl get secret langsmith-redis -n langsmith

# Inspect a secret (base64-decode value)
kubectl get secret langsmith-postgres -n langsmith \
  -o jsonpath='{.data.connection_url}' | base64 --decode

# List Secret Manager secrets
gcloud secrets list --project <project-id> --filter="name:langsmith"

# Check a specific Secret Manager secret
gcloud secrets versions access latest \
  --secret=langsmith-<prefix>-<env>-postgres-password \
  --project <project-id>

# Validate all required secrets are present
make secrets   # → manage-secrets.sh validate
```

### Quick health check

```bash
echo "=== Context ===" && kubectl config current-context
echo "=== Nodes ===" && kubectl get nodes
echo "=== Pods ===" && kubectl get pods -n langsmith
echo "=== Certificate ===" && kubectl get certificate -n langsmith
echo "=== Gateway ===" && kubectl get gateway -n langsmith
echo "=== Secrets ===" && kubectl get secrets -n langsmith | grep -E "langsmith-postgres|langsmith-redis"
echo "=== Helm ===" && helm status langsmith -n langsmith 2>/dev/null | grep -E "STATUS|LAST DEPLOYED"
```

> For an interactive deployment health check that diagnoses all of the above automatically:
> ```bash
> make status
> ```
