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



### Key Vault purge protection cannot be disabled after enabling

**Symptom:**
```
Error: updating Key Vault "langsmith-kv-dz": once Purge Protection has been Enabled it's not possible to disable it
```

**Cause:** Azure Key Vault soft-delete is enabled by default. When a Key Vault is deleted (via `terraform destroy` or manually), Azure retains it in a soft-deleted recoverable state for 90 days. On the next `terraform apply` with the same name, **Azure silently recovers the old Key Vault** — including its original `purge_protection_enabled = true` setting. Since purge protection is a one-way door (enabled → cannot be disabled), any subsequent apply with `keyvault_purge_protection = false` fails.

**Fix — if you can live with purge protection enabled** (test environments):
```hcl
# terraform.tfvars
keyvault_purge_protection = true
```
Re-run `make apply` — no more diff.

**Fix — if you need purge_protection = false** (clean re-deployable test env):
```bash
# 1. Remove KV from Terraform state (does not delete it from Azure)
terraform -chdir=infra state rm module.keyvault.azurerm_key_vault.langsmith

# 2. Permanently purge the soft-deleted KV (irreversible!)
az keyvault purge --name langsmith-kv<identifier> --location eastus

# 3. Re-apply — Terraform creates a fresh KV with purge_protection = false
make apply
```

**Note on teardown**: If `keyvault_purge_protection = true` is set, `terraform destroy` will delete the KV but it will remain in soft-deleted state for 90 days. You cannot reuse the same Key Vault name until either the 90 days expire or you manually purge it. Use a different `identifier` suffix for a fresh clean deploy.

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

**Fix:** Delete and recreate `langsmith-config-secret` with the correct key name, then re-deploy:
```bash
kubectl delete secret langsmith-config-secret -n langsmith
make k8s-secrets   # recreates from Key Vault with correct key names
make deploy
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

**Fix:** Roll forward to the version you were on (or newer). Set `langsmith_helm_chart_version` in `terraform.tfvars` and re-deploy:
```hcl
# terraform.tfvars
langsmith_helm_chart_version = "0.13.30"   # pin to working version
```
```bash
make init-values && make deploy
```

**Prevention:** Always test a new chart version in a separate environment before upgrading production. Never downgrade an existing deployment.

---

### Helm install times out — `langsmith-backend-auth-bootstrap` takes too long

**Symptom:**
```
Error: UPGRADE FAILED: timed out waiting for the condition
```

**Cause:** The `langsmith-backend-auth-bootstrap` Job runs DB migrations and auth bootstrap on every `helm upgrade`. On first install this can take up to 5 minutes. Without `--timeout 15m`, helm may report failure even though the install eventually succeeds.

**Fix:** `make deploy` already includes `--timeout 20m`. If you are running helm manually, always include `--timeout 20m`:
```bash
make deploy   # recommended — handles timeout, values chain, and release guard automatically
```

---

## Pass 3+ — Feature Passes

### Polly shows "Unable to connect to LangGraph server" / connects to `localhost:8123`

**Symptom:** The Polly chat widget in the UI shows:
```
ConnectionError: Unable to connect to LangGraph server.
Please ensure the server is running and accessible.
```
Browser console shows `POST http://localhost:8123/threads net::ERR_FAILED` and a CORS error for `localhost:8123`.

**Cause:** Two separate issues can produce this:

**A — Frontend pod started before `langsmith-polly-config` was created.**
The bootstrap job creates a ConfigMap `langsmith-polly-config` with `VITE_POLLY_DEPLOYMENT_URL` after Polly is registered. The frontend mounts this via `envFrom` — but env vars from ConfigMap are loaded at pod start, not watched dynamically. If the frontend pod was running before the bootstrap job completed, it has `VITE_SELF_HOSTED_POLLY_ENABLED=true` but no URL, so Polly defaults to `localhost:8123`.

**Fix:** Roll the frontend after any `agentBootstrap` run that registers Polly for the first time:
```bash
kubectl rollout restart deployment langsmith-frontend -n langsmith
```
Verify the new pod has the URL:
```bash
kubectl exec -n langsmith deploy/langsmith-frontend -- env | grep POLLY
# expect: VITE_POLLY_DEPLOYMENT_URL=https://<hostname>/lgp/smith-polly-<hash>
```

**B — `LANGCHAIN_ENDPOINT` set in `polly.agent.extraEnv`.**
`LANGCHAIN_ENDPOINT` is a reserved variable. Setting it in `polly.agent.extraEnv` causes the bootstrap job to fail registering Polly with `400 Bad Request: 'LANGCHAIN_ENDPOINT' is reserved`. Polly is never created, so no URL ends up in the ConfigMap.

**Fix:** Remove the `polly.agent.extraEnv` block entirely. The operator injects `LANGCHAIN_ENDPOINT` automatically pointing to `langsmith-frontend:80/api/v1`, which correctly routes to the legacy backend. Do not attempt to override it.

---

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

### `agent-builder-tool-server` or `polly` in CrashLoopBackOff — child processes die silently

**Symptom:**
```
INFO:     Started parent process [1]
INFO:     Waiting for child process [18]
INFO:     Child process [18] died
INFO:     Waiting for child process [19]
INFO:     Child process [19] died
...
Startup probe failed: Get "http://10.0.0.x:1989/health": dial tcp ...: connect: connection refused
```
Pod restarts indefinitely. No traceback is printed to the container log.

**Cause:** The `lc_config.settings.SharedSettings` class is instantiated at **module import time** inside the uvicorn worker process. A pydantic `ValidationError` raised there exits the worker with code 0 — uvicorn's parent prints "Child process died" but swallows the traceback. The most common triggers:

- `BASIC_AUTH_ENABLED = true` but `BASIC_AUTH_JWT_SECRET` is empty (key missing from `langsmith-config-secret`)
- A required feature-flag key is absent from the `langsmith-config` ConfigMap (populated by Helm)

**How to diagnose — run the server in a debug pod:**
```bash
# Get the image version
IMAGE=$(kubectl get deployment langsmith-agent-builder-tool-server -n langsmith \
  -o jsonpath='{.spec.template.spec.containers[0].image}')

# Create a debug pod (sleep so you can exec in)
kubectl run ts-debug --image="$IMAGE" --restart=Never -n langsmith \
  --overrides='{"spec":{"containers":[{"name":"ts-debug","image":"'"$IMAGE"'","command":["sleep","300"],"envFrom":[{"configMapRef":{"name":"langsmith-config"}}],"resources":{"requests":{"cpu":"100m","memory":"256Mi"},"limits":{"cpu":"500m","memory":"512Mi"}}}]}}'

kubectl wait --for=condition=Ready pod/ts-debug -n langsmith --timeout=60s

# Now run the server — the traceback will be visible
kubectl exec -n langsmith ts-debug -- \
  /bin/sh -c 'cd /code/agent-builder-tool-server && PYTHONUNBUFFERED=1 python server.py 2>&1 | head -40'

kubectl delete pod ts-debug -n langsmith
```

**Fix:** Add the missing key to `langsmith-config-secret`:
```bash
# Find which key is missing from the pydantic error, then add it to Key Vault:
az keyvault secret set --vault-name <kv-name> --name <missing-key> --value "<value>"

# Re-create the secret:
make k8s-secrets

# Restart the failing pod:
kubectl rollout restart deployment/langsmith-agent-builder-tool-server -n langsmith
```

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
make uninstall

# 2. Delete the namespace (clears any lingering finalizers)
kubectl delete namespace langsmith --timeout=60s

# 3. Now safe to destroy
#    cert-manager and KEDA are managed by Terraform (k8s-bootstrap module) — destroy handles them
make destroy
```

---

### `langsmith-agent-bootstrap` hook times out on first Pass 3–5 deploy

**Symptom:**
```
Error: UPGRADE FAILED: post-upgrade hooks failed: resource Job/langsmith/langsmith-agent-bootstrap
not ready. status: InProgress, message: Job in progress
context deadline exceeded
```
The job log shows agents progressing through `QUEUED → AWAITING_DEPLOY → DEPLOYING` but never reaching `HEALTHY` within the 20-minute helm timeout.

**Cause:** On a cold cluster (all agent images pulling for the first time), the three LGP agents (`agent-builder`, `clio`, `smith-polly`) can take longer than 20 minutes to reach HEALTHY status. The Helm post-upgrade hook waits synchronously.

**This is not a failure** — the resources ARE applied. The release is marked `failed` but the agents continue deploying. Re-run once agents are healthy:

```bash
# Wait for agents to finish (watch pod count stabilise)
kubectl get pods -n langsmith -w | grep -E "agent-builder|clio|smith-polly"

# Re-deploy — bootstrap hook completes immediately since agents are already HEALTHY
make deploy
```

---

### `listener` pods OOMKilled — CrashLoopBackOff with dev sizing

**Symptom:** `langsmith-listener` pods repeatedly crash. `kubectl describe pod` shows `Reason: OOMKilled` / `Exit Code: 137`. Cluster memory looks fine overall.

**Cause:** The `langsmith-values-sizing-dev.yaml` sets `listener.deployment.resources.limits.memory: 512Mi`. When Deployments (Pass 3) are enabled, the listener is heavier and exceeds this limit.

**Fix:** The `langsmith-values-agent-deploys.yaml` overlay (loaded after the sizing file) correctly sets `listener.deployment.resources.limits.memory: 4Gi`. Verify both files are in your values chain:

```
make deploy   # values chain: values.yaml → overrides → sizing-dev → agent-deploys
```

If you see only the sizing file without agent-deploys, re-run `make init-values` to regenerate the overlay files.

**Key gotcha — `resources` vs `deployment.resources`:** The LangSmith chart uses `listener.deployment.resources` (not `listener.resources`) for container resource limits. Setting `listener.resources` in an overlay file is silently ignored. Always use the `deployment.resources` path.

---

### Stale HPA scales `listener` or `host-backend` to max replicas unexpectedly

**Symptom:** After enabling Passes 3–5, `langsmith-listener` scales to 8–10 pods even though `sizing_profile = "dev"` sets `replicas: 1`. Memory usage stays high, pods keep OOMKilling.

**Cause:** A prior Helm revision created an HPA for `listener` (or `host-backend`) when `autoscaling.hpa.enabled: true` was set. When the release fails (hook timeout), Helm does not clean up the HPA. On re-deploy with `enabled: false`, the stale HPA remains and overrides the `replicas` spec.

**Fix:**
```bash
kubectl delete hpa langsmith-listener langsmith-host-backend -n langsmith 2>/dev/null || true
kubectl scale deployment langsmith-listener -n langsmith --replicas=1
kubectl scale deployment langsmith-host-backend -n langsmith --replicas=1
make deploy   # locks in correct replica count from values files
```
