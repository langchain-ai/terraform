# LangSmith Azure — Troubleshooting

Issues, gotchas, and fixes. Updated as deployments are validated.

---

## Pass 1 — Infrastructure

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

**Fix:** Add the missing service account to `modules/storage/main.tf` and re-apply:
```hcl
# azure/infra/modules/storage/main.tf
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
terraform apply -target=module.blob
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
