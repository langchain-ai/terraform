# LangSmith Azure — Troubleshooting

Issues, gotchas, and fixes. Updated as deployments are validated.

---

## Pass 1 — Infrastructure

### vCPU quota exceeded — autoscaler backoff or node pool rotation fails

**Symptom — autoscaler backoff (pods pending):**
```
Warning  FailedScheduling  pod/langsmith-backend-xxx  0/1 nodes are available: 1 Too many pods.
Normal   NotTriggerScaleUp pod/langsmith-backend-xxx  pod didn't trigger scale-up: 2 in backoff after failed scale-up
```

**Symptom — node pool rotation fails (e.g. changing max_pods):**
```
Error: creating temporary Agent Pool ... Agent Pool Name: "defaulttmp"
"code": "ErrCode_InsufficientVCPUQuota",
"message": "Insufficient vcpu quota requested 8, remaining 2 for family standardDSv3Family for region eastus."
```

**Cause:** Azure subscriptions have per-region vCPU quotas per VM family. The default for `standardDSv3Family` in eastus is often 10 cores. One `Standard_D8s_v3` node uses 8 cores — only 2 remain. Autoscaler needs 8 more for a second node; node pool rotation creates a temporary surge node of the same size.

**Why `max_pods = 30` triggers this:** AKS default is 30 pods per node. Pass 2 alone deploys ~37 pods (17 LangSmith + 20 system). The autoscaler tries to add a second node, hits quota, and enters backoff. The fix is `default_node_pool_max_pods = 60` in `terraform.tfvars` — all pods fit on one node and no scale-out is needed.

**Recommended quota for multi-dataplane (3 dataplanes):**
- Pass 2 + 3 dataplanes: ~46 pods — fits on 1× D8s_v3 with `max_pods = 60`
- Set quota to **32 cores** to allow autoscaler headroom for rolling upgrades and burst

**Fix — request quota increase:**
```bash
# Option 1 — Azure portal (usually auto-approves within minutes)
# Portal → Subscriptions → <sub-id> → Usage + Quotas → search "DSv3" → eastus → Request increase → 32

# Option 2 — CLI
az quota update \
  --resource-name "standardDSv3Family" \
  --scope /subscriptions/<sub-id>/providers/Microsoft.Compute/locations/eastus \
  --limit-object value=32 limit-type=Independent \
  --resource-type dedicated

# Verify current usage
az vm list-usage --location eastus --query "[?contains(name.value,'DSv3')]" -o table
```

**Fix — ensure max_pods is set correctly in terraform.tfvars:**
```hcl
default_node_pool_max_pods = 60   # must be set before first apply — immutable field
```

> **Note:** `max_pods` is immutable on an existing node pool. Changing it after initial apply requires a node pool rotation (temporary node = more quota). Always set it before the first `terraform apply`.

---

### Istio addon revision not supported

**Symptom:**
```
Error: creating Kubernetes Cluster ...: unexpected status 400 (400 Bad Request)
"message": "Requested change in revisions is not allowed. Reason: Revision asm-1-XX is not supported by the service mesh add-on."
```

**Cause:** Azure retires old ASM revisions regularly. `asm-1-22` and `asm-1-24` are retired as of early 2026. The supported set changes every few months and does not match what you might find in older docs or blog posts.

**ASM = Azure Service Mesh.** The version format `asm-1-27` maps to Istio 1.27.x — Azure manages the control plane.

**Fix:** Check what revisions are currently available in your region, then update `istio_addon_revision` in `terraform.tfvars`:
```bash
# List currently supported revisions and their K8s compatibility
az aks mesh get-revisions --location eastus -o table

# Current output example (March 2026):
# Revision    Upgrades          CompatibleWith      CompatibleVersions
# asm-1-26    asm-1-27,asm-1-28 KubernetesOfficial  1.29, 1.30, 1.31, 1.32, 1.33, 1.34
# asm-1-27    asm-1-28          KubernetesOfficial  1.29, 1.30, 1.31, 1.32, 1.33, 1.34, 1.35
# asm-1-28    None available    KubernetesOfficial  1.30, 1.31, 1.32, 1.33, 1.34, 1.35
```

Update `terraform.tfvars`:
```hcl
istio_addon_revision = "asm-1-27"   # use output from az aks mesh get-revisions
```

Then re-run `terraform apply`. The default in this module is kept current but may lag Azure's retirement schedule — always verify before deploying.

**After cluster exists**, check available upgrades:
```bash
az aks mesh get-upgrades -g <resource-group> -n <cluster-name>
```

---



### Key Vault secrets already exist but are not in Terraform state

**Symptom:**
```
Error: a resource with the ID "https://langsmith-kv-<id>.vault.azure.net/secrets/langsmith-deployments-encryption-key/..."
already exists - to be managed via Terraform this resource needs to be imported into the State.
```

**Cause:** Older versions of `setup-env.sh` wrote Fernet keys directly to Key Vault when KV already existed, which conflicted with Terraform trying to create the same secrets. Current `setup-env.sh` is read-only against Key Vault — Terraform is the sole writer.

This error only occurs if you are using an older copy of `setup-env.sh` or manually wrote secrets to Key Vault outside of Terraform.

**Fix:** Import the three secrets into Terraform state, then re-run apply:
```bash
terraform import \
  'module.keyvault.azurerm_key_vault_secret.deployments_encryption_key[0]' \
  "$(az keyvault secret show --vault-name langsmith-kv<identifier> --name langsmith-deployments-encryption-key --query id -o tsv)"

terraform import \
  'module.keyvault.azurerm_key_vault_secret.agent_builder_encryption_key[0]' \
  "$(az keyvault secret show --vault-name langsmith-kv<identifier> --name langsmith-agent-builder-encryption-key --query id -o tsv)"

terraform import \
  'module.keyvault.azurerm_key_vault_secret.insights_encryption_key[0]' \
  "$(az keyvault secret show --vault-name langsmith-kv<identifier> --name langsmith-insights-encryption-key --query id -o tsv)"

terraform apply
```

**Prevention:** On a brand-new environment this won't occur. Current `setup-env.sh` never writes to Key Vault — it only reads. On first run (no KV), secrets go to local dot-files and `secrets.auto.tfvars`; Terraform creates Key Vault and stores all secrets on `terraform apply`. On subsequent runs, `setup-env.sh` reads from KV to regenerate `secrets.auto.tfvars`.

---

## Pass 2 — Application

### Front Door returns 404 — UI not loading (Istio + Front Door)

**Symptom:**
```
curl https://<fd-endpoint>.z02.azurefd.net/   →  HTTP 404 (Azure FD error page)
curl -H "Host: <fd-endpoint>.z02.azurefd.net" http://<istio-lb-ip>/  →  HTTP 200 ✓
```

The LangSmith frontend loads when hitting the Istio LB directly with the correct Host header, but Front Door returns its own 404 error page.

**Cause:** Front Door's `originHostHeader` defaults to the origin hostname (the Istio LB IP address). FD forwards requests to the cluster with `Host: <IP>` instead of `Host: <fd-endpoint>.z02.azurefd.net`. The Istio VirtualService only matches the FD endpoint hostname — an IP-based Host header matches nothing, so Istio returns 404.

The Terraform `frontdoor` module fixes this automatically: `origin_host_header` is set to the FD endpoint hostname when no custom domain is configured. If you see this issue with an older version of the module, check the origin config:

```bash
az afd origin show \
  --profile-name <fd-profile> \
  --resource-group <rg> \
  --origin-group-name <origin-group> \
  --origin-name <origin> \
  --query originHostHeader -o tsv
# Should be: <fd-endpoint>.z02.azurefd.net (not the IP)
```

**Fix — update via Terraform:**
The `modules/frontdoor/main.tf` origin block should have:
```hcl
origin_host_header = var.custom_domain != "" ? var.custom_domain : azurerm_cdn_frontdoor_endpoint.endpoint.host_name
```
Then run `terraform apply` — FD propagates the change within ~2 minutes.

**Why this matters for Istio specifically:** NGINX Ingress uses `ingressClassName` and routes based on path — it ignores the Host header mismatch. Istio VirtualService routing is Host-header-exact — if the Host doesn't match, the request falls through to a 404. This issue only manifests with `ingress_controller = "istio-addon"`.

---

### `database "langsmith" does not exist` — backend pods crashlooping

**Symptom:**
```
FATAL: database "langsmith" does not exist (SQLSTATE 3D000)
panic: failed to connect to ... server error: FATAL: database "langsmith" does not exist
```
Backend pods start, connect to Postgres, and immediately crash.

**Cause:** Azure DB for PostgreSQL Flexible Server does not auto-create application databases. Only the `postgres` system database exists by default. The `langsmith` database must be created explicitly.

The Terraform `postgres` module now creates the database automatically via `azurerm_postgresql_flexible_server_database`. If you see this error it means you are on an older version of the module that was missing this resource.

**Fix:**
```bash
terraform apply   # adds azurerm_postgresql_flexible_server_database.langsmith
kubectl rollout restart deployment -n langsmith   # kick pods immediately
```

---

### `langsmith-backend-auth-bootstrap` stuck in `CreateContainerConfigError`

**Symptom:**
```
langsmith-backend-auth-bootstrap-xxxxx   0/1   CreateContainerConfigError   0   2m
```
Helm eventually times out at 15 minutes with no clear error message.

**Cause:** The Job reads the admin password using the key `initial_org_admin_password`. If the secret was created with a different key name (e.g. `admin_password`), the container can't start.

**Fix:** Delete and recreate `langsmith-config-secret` with the correct key name, then re-run helm:
```bash
kubectl delete secret langsmith-config-secret -n langsmith
# Re-run the kubectl create secret command from QUICK_REFERENCE.md Pass 2c
# Ensure --from-literal=initial_org_admin_password="$ADMIN_PASSWORD"
```

---

### Cannot roll back to an older chart version after DB migration

**Symptom:**
```
FAILED: Can't locate revision identified by 'a1c5f8b9d2e3'
Job Failed. failed: 4/1
Error: UPGRADE FAILED: post-upgrade hooks failed: resource Job/langsmith/langsmith-backend-migrations not ready
```

**Cause:** LangSmith DB migrations are one-way (Alembic forward-only). A newer chart version applies schema migrations that older chart versions don't know about. Downgrading the chart leaves the DB at a revision the older app image can't locate.

**Fix:** Roll forward to the version you were on (or newer):
```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version <PREVIOUS_VERSION> \
  --namespace langsmith \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

**Prevention:** Always test a new chart version in a separate environment before upgrading production. Never downgrade an existing deployment.

---

### Helm install times out — `langsmith-backend-auth-bootstrap` takes too long

**Symptom:**
```
Error: UPGRADE FAILED: timed out waiting for the condition
```

**Cause:** The `langsmith-backend-auth-bootstrap` Job runs DB migrations and auth bootstrap on every `helm upgrade`. On first install this can take up to 5 minutes. Without `--timeout 15m`, helm may report failure even though the install eventually succeeds.

**Fix:** Always include `--timeout 15m` in the helm command:
```bash
helm upgrade --install langsmith langsmith/langsmith \
  --version <VERSION> --namespace langsmith \
  -f ../helm/values/values-overrides.yaml \
  --wait --timeout 15m
```

---

## Pass 3+ — Feature Passes

### `listener` and `operator` pods never appear after Pass 3 helm upgrade

**Symptom:** `helm upgrade` succeeds. `langsmith-host-backend` is Running but `langsmith-listener` and `langsmith-operator` are absent from `kubectl get pods`.

**Cause:** `config.deployment.url` was set but `config.deployment.enabled: true` was omitted. The chart silently skips creating `listener` and `operator` when `enabled` is false (the default).

**Fix:** Add `enabled: true` inside the `deployment` block in `values-overrides.yaml`:
```yaml
config:
  deployment:
    enabled: true          # required — url alone is not enough
    url: "https://<your-hostname>"
```
Then re-run helm upgrade.

---

### Duplicate top-level `config:` key silently drops values

**Symptom:** Pass 3 or later config (`deployment.url`, `agentBuilder.enabled`, etc.) appears to have no effect even though it is set in `values-overrides.yaml`.

**Cause:** YAML does not allow duplicate top-level keys. When a second `config:` block is added (e.g. by uncommenting a Pass 3 section that starts with `config:`), only one block is used — the other is silently dropped.

**Fix:** Always add new config blocks *inside* the existing `config:` key — never create a second `config:` at the top level. Use `helm get values langsmith -n langsmith` to verify what the chart actually received.

---

### Encryption keys must not change after first deploy

Changing `deployments_encryption_key`, `agent_builder_encryption_key`, or `insights_encryption_key` after their first use permanently corrupts the data they protect. There is no recovery path.

- Do not rotate these keys.
- Do not set `config.agentBuilder.encryptionKey` or `config.insights.encryptionKey` inline in `values-overrides.yaml` — the chart reads them from `langsmith-config-secret` via `existingSecretName`. Setting inline overrides the secret reference.

---

## Workload Identity

### Pod panics: `blob-storage health-check failed` / `AADSTS700213: No matching federated identity record found`

**Symptom:**
```
panic: blob-storage health-check failed: get container properties failed:
DefaultAzureCredential: failed to acquire a token.
WorkloadIdentityCredential authentication failed.
  AADSTS700213: No matching federated identity record found for presented assertion subject
  'system:serviceaccount:langsmith:langsmith-<service>'
```

**Cause:** The pod's Kubernetes ServiceAccount does not have a registered federated identity credential on the Azure Managed Identity. Every pod that accesses Blob Storage needs one.

**Fix:** Add the missing service account to `modules/k8s-cluster/main.tf` locals and re-apply:
```hcl
# azure/infra/modules/k8s-cluster/main.tf
service_accounts_for_workload_identity = [
  "${var.langsmith_release_name}-backend",
  "${var.langsmith_release_name}-platform-backend",
  "${var.langsmith_release_name}-queue",
  "${var.langsmith_release_name}-ingest-queue",
  "${var.langsmith_release_name}-host-backend",                 # Pass 3
  "${var.langsmith_release_name}-listener",                     # Pass 3
  "${var.langsmith_release_name}-agent-builder-tool-server",    # Pass 4
  "${var.langsmith_release_name}-agent-builder-trigger-server", # Pass 4
]
```
```bash
terraform apply -target=module.aks
kubectl rollout restart deployment/langsmith-<service> -n langsmith
```

See [ARCHITECTURE.md — Workload Identity](ARCHITECTURE.md#workload-identity-blob-storage) for the full table of which pods require WI.

---

## Teardown

### `terraform destroy` stalls on VNet/subnet deletion

**Symptom:** `terraform destroy` hangs waiting to delete the VNet or subnet with no progress.

**Cause:** The Azure Load Balancer provisioned by `ingress-nginx-controller` is not tracked by Terraform — it is created by AKS on behalf of the K8s Service. Azure blocks VNet deletion while the Load Balancer holds a reference to the subnet.

**Fix — correct teardown order:**
```bash
# 1. Uninstall LangSmith — removes pods, services, and the Azure Load Balancer
helm uninstall langsmith -n langsmith --wait

# 2. Delete the namespace (clears any lingering finalizers)
kubectl delete namespace langsmith --timeout=60s

# 3. Now safe to destroy
#    cert-manager and KEDA are managed by Terraform (k8s-bootstrap module) — destroy handles them
terraform destroy
```
