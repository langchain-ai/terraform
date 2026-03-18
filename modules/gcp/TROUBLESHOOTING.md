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

### Quick health check

```bash
echo "=== Context ===" && kubectl config current-context
echo "=== Nodes ===" && kubectl get nodes
echo "=== Pods ===" && kubectl get pods -n langsmith
echo "=== Certificate ===" && kubectl get certificate -n langsmith
echo "=== Gateway ===" && kubectl get gateway -n langsmith
echo "=== Helm ===" && helm status langsmith -n langsmith 2>/dev/null | grep -E "STATUS|LAST DEPLOYED"
```
