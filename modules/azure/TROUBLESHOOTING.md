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

**Alternative — switch VM family if DSv3 quota is fully exhausted:**

If `az vm list-usage` shows `standardDSv3Family` at 100% (`Current == Limit`) and a quota increase is not possible, switch to an equivalent family in `terraform.tfvars`:

```hcl
# DSv2 family — equivalent vCPU count, slightly less RAM, different quota pool
default_node_pool_vm_size = "Standard_DS4_v2"   # 8 vCPU, 28 GiB (vs D8s_v3: 8 vCPU, 32 GiB)

additional_node_pools = {
  large = {
    vm_size   = "Standard_DS5_v2"   # 16 vCPU, 56 GiB (vs D16s_v3: 16 vCPU, 64 GiB)
    min_count = 0
    max_count = 2
  }
}
```

Check available families and remaining quota before choosing:
```bash
az vm list-usage --location eastus \
  --query "[?contains(name.value,'standardDS')].{Family:name.localizedValue,Used:currentValue,Limit:limit}" \
  -o table
```

| Recommended | Alternative | vCPU | RAM difference |
|---|---|---|---|
| `Standard_D8s_v3` | `Standard_DS4_v2` | 8 | −4 GiB (28 vs 32) |
| `Standard_D16s_v3` | `Standard_DS5_v2` | 16 | −8 GiB (56 vs 64) |

Validated: full pass 2–5 deploy (production sizing, all addons) ran successfully on DS4_v2 / DS5_v2 on 2026-03-30.

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

### `dns_label` subdomain not resolving — TLS cert stuck pending

**Symptom:** After `make deploy`, `nslookup langsmith-demo.eastus.cloudapp.azure.com` returns NXDOMAIN. The cert-manager ACME challenge can't complete and the TLS certificate stays `READY: False`.

**Cause:** The `service.beta.kubernetes.io/azure-dns-label-name` annotation must be present on the NGINX LoadBalancer service for Azure to assign the DNS label to the public IP. If the annotation is missing, the IP is provisioned but has no DNS name.

`make deploy` sets this annotation automatically via `deploy.sh`. If you deployed without `make deploy` (e.g. ran `helm upgrade` directly), the annotation was never set.

**Fix — set the annotation manually:**
```bash
kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
  service.beta.kubernetes.io/azure-dns-label-name=<dns_label> \
  --overwrite
# e.g. --overwrite with value: langsmith-demo

# Wait 1-2 minutes, then verify DNS resolves:
nslookup langsmith-demo.eastus.cloudapp.azure.com
# Expected: returns the public IP

# Once DNS resolves, delete the stuck cert to trigger a re-issue:
kubectl delete certificate langsmith-tls -n langsmith
# cert-manager re-creates it and the ACME challenge completes within 2-3 minutes
```

**Verify the annotation was set:**
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name}'
# Expected: langsmith-demo (or your dns_label value)
```

---

### `istio-addon` — port 80/443 timeout, TLS handshake reset, site unreachable

**Symptom:** After `make deploy` with `ingress_controller = "istio-addon"`, the site is unreachable. Port 80 times out, port 443 resets the TLS handshake. Cert-manager ACME challenge stays `pending`.

```bash
curl https://langsmith-dz.eastus.cloudapp.azure.com/
# curl: (35) Recv failure: Connection reset by peer

kubectl get challenge -n langsmith
# NAME                    STATE     DOMAIN                              AGE
# langsmith-tls-1-xxx     pending   langsmith-dz.eastus.cloudapp.azure.com   10m
```

**Root cause — three compounding issues:**

1. **Wrong gateway label.** Kubernetes Ingress with `ingressClassName: istio` targets pods with label `istio: ingressgateway`. The AKS managed external gateway uses label `istio: aks-istio-ingressgateway-external`. Istio never creates Envoy listeners → gateway pod has no routes → all traffic is dropped.

2. **ClusterIssuer created with `class: nginx`.** The ACME HTTP-01 solver ingress gets class `nginx`, not `istio` → cert-manager solver is never routed through the istio gateway.

3. **TLS secret in wrong namespace.** Istio SDS reads the `credentialName` secret from the **gateway pod namespace** (`aks-istio-ingress`), not the app namespace (`langsmith`). TLS handshake fails even after the cert is issued.

**Fix — `make deploy` handles all three automatically** (current version):
- Creates a `Gateway` resource targeting `istio: aks-istio-ingressgateway-external` on ports 80 and 443
- Applies `ClusterIssuer` with `ingressClassName: istio`
- Waits for cert-manager to issue the cert, then syncs `langsmith-tls` to `aks-istio-ingress`
- Creates a `VirtualService` routing traffic to the LangSmith frontend

**If you deployed manually before this fix, apply the resources directly:**

```bash
# 1. Create the Istio Gateway
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: langsmith-gateway
  namespace: langsmith
spec:
  selector:
    istio: aks-istio-ingressgateway-external
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "langsmith-dz.eastus.cloudapp.azure.com"   # replace with your dns_label.region.cloudapp.azure.com
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: langsmith-tls
    hosts:
    - "langsmith-dz.eastus.cloudapp.azure.com"
EOF

# 2. Fix the ClusterIssuer (patch solver class from nginx → istio)
kubectl patch clusterissuer letsencrypt-prod --type=json \
  -p='[{"op":"replace","path":"/spec/acme/solvers/0/http01/ingress/ingressClassName","value":"istio"}]'
# Then delete the stuck challenge to force retry:
kubectl delete challenge -n langsmith --all

# 3. Once the cert is issued, sync the secret to the gateway namespace
kubectl get secret langsmith-tls -n langsmith -o json | \
  python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'aks-istio-ingress'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f -

# 4. Create the VirtualService
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: langsmith
  namespace: langsmith
spec:
  hosts:
  - "langsmith-dz.eastus.cloudapp.azure.com"
  gateways:
  - langsmith-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: langsmith-frontend.langsmith.svc.cluster.local
        port:
          number: 80
EOF
```

**Verify gateway has listeners:**
```bash
# Gateway pod should show READY 1/1 and have Envoy listeners configured
kubectl get pods -n aks-istio-ingress
# aks-istio-ingressgateway-external-asm-1-27-xxx   1/1   Running

# Confirm port 80 responds (should return 404 or redirect before VS is created)
curl -o /dev/null -w "%{http_code}" http://langsmith-dz.eastus.cloudapp.azure.com/
# 404 = gateway is working, routing not yet configured
# 000 = gateway still has no listeners — check Gateway resource was applied

# Confirm TLS secret exists in gateway namespace
kubectl get secret langsmith-tls -n aks-istio-ingress
```

**Check gateway selector label:**
```bash
kubectl get svc aks-istio-ingressgateway-external -n aks-istio-ingress \
  -o jsonpath='{.spec.selector}'
# {"app":"aks-istio-ingressgateway-external","istio":"aks-istio-ingressgateway-external"}
# The Gateway resource must use selector: istio: aks-istio-ingressgateway-external
```

---

### `letsencrypt-prod` ClusterIssuer missing — cert-manager cannot issue TLS cert

**Symptom:**
```
kubectl get certificate langsmith-tls -n langsmith
# NAME            READY   SECRET   AGE
# langsmith-tls   False            3m

kubectl describe certificate langsmith-tls -n langsmith
# Events: ... clusterissuers.cert-manager.io "letsencrypt-prod" not found
```

**Cause:** When `tls_certificate_source = "letsencrypt"` is set, the `k8s-bootstrap` module creates a `letsencrypt-prod` ClusterIssuer via `kubernetes_manifest`. If you deployed from an older version of the module (before `cluster_issuer_http01` was added), the ClusterIssuer was never created.

**Fix — apply it manually:**
```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx   # replace with "istio" when ingress_controller = "istio-addon" or "istio"
EOF

# Verify it becomes Ready (takes ~20 seconds)
kubectl get clusterissuer letsencrypt-prod
# NAME               READY   AGE
# letsencrypt-prod   True    30s

# Delete the stuck cert to trigger re-issue
kubectl delete certificate langsmith-tls -n langsmith
```

**Note:** `kubernetes_manifest` cannot be used for this in Terraform — it requires a live k8s API connection during `terraform plan`, which fails on fresh deploy. The ClusterIssuer is therefore applied by `make deploy` (`deploy.sh`) via `kubectl apply`, with the correct `ingressClassName` for the active ingress controller. This is already the case in the current version of the scripts.

---

### Scripts missing after fresh clone or clean environment

**Symptom:** Running `make kubeconfig`, `make deploy`, `make status`, or `make uninstall` fails with:
```
helm/scripts/get-kubeconfig.sh: No such file or directory
helm/scripts/preflight-check.sh: No such file or directory
infra/scripts/_common.sh: No such file or directory
```

**Cause:** These scripts are tracked in git but were untracked (`??`) files — meaning they existed locally but had never been committed. After a fresh clone or `git clean -f`, they are absent.

**Fix:** These scripts are now committed to the repo. After pulling the latest branch, they will be present. If you are on an older branch without them, they can be recreated from the source in `BUILDING_LIGHT_LANGSMITH.md` or by cherry-picking the commit that adds them.

**Scripts that were added (now committed):**
| Script | Purpose |
|---|---|
| `infra/scripts/_common.sh` | Shared bash helpers (`_parse_tfvar`, `pass/fail/warn/info/header`) |
| `helm/scripts/get-kubeconfig.sh` | Reads cluster name from `terraform output`, runs `az aks get-credentials` |
| `helm/scripts/preflight-check.sh` | Checks required tools, cluster connectivity, helm repo |
| `helm/scripts/preflight-check.sh` | TLS check, NGINX DNS label annotation |
| `helm/scripts/uninstall.sh` | Uninstalls Helm release, prompts for namespace deletion |
| `infra/scripts/status.sh` | 9-section health check for the full deployment |
| `infra/scripts/tf-run.sh` | Wrapper for `terraform init/plan/apply/destroy` |

---

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

## Pass 2 — init-values

### `enable_deployments = true` (unquoted boolean) not picked up by init-values.sh

**Symptom:** After setting `enable_deployments = true` in `terraform.tfvars` and running `make init-values`, the `langsmith-values-agent-deploys.yaml` file is not generated:
```
✗ langsmith-values-agent-deploys.yaml (not enabled)
```
Even though `enable_deployments = true` is clearly set in tfvars.

**Cause:** `_parse_tfvar` in `_common.sh` used a sed command without `-n`/`p` flags. For unquoted values (`true`, `false`, numbers), sed returned the full line unchanged, which is non-empty, so the function returned `enable_deployments=true` (the full key=value) instead of just `true`. The `== "true"` check then failed.

**Fix:** Already corrected in `_common.sh` — sed now uses `-n 's/pattern/\1/p'` so it only outputs the captured group when the pattern matches. Unquoted values fall through to a second pass that strips the key prefix.

---

### Pass 3 — `config.deployment` pods stay in DEPLOYING / never reach HEALTHY

**Symptom:** After Pass 3 deploy, `listener` and `operator` are Running, but agent deployments stay in `DEPLOYING` state in the UI and never transition to `HEALTHY`.

**Cause:** `config.deployment.url` was empty or `config.deployment.tlsEnabled` was `false` when TLS is enabled. The operator builds agent endpoint URLs using these values — an empty URL or wrong protocol causes the health check to fail.

**Fix:** `init-values.sh` now automatically injects `url` and `tlsEnabled` into `langsmith-values-agent-deploys.yaml` after copying from examples. If deploying manually, set both explicitly:
```yaml
config:
  deployment:
    enabled: true
    url: "https://langsmith-azonf.eastus.cloudapp.azure.com"   # must include https://
    tlsEnabled: true   # must be true when tls_certificate_source = letsencrypt or dns01
```

---

### Pass 5 — `backend-ch-migrations` stuck in `CreateContainerConfigError` after enabling Insights

**Symptom:**
```
langsmith-backend-ch-migrations-xxxxx   CreateContainerConfigError
Warning  Failed  kubelet  Error: secret "langsmith-clickhouse" not found
```
Multiple pods fail with `CreateContainerConfigError` immediately after enabling `enable_insights = true`.

**Cause:** `langsmith-values-insights.yaml` (copied from the AWS-oriented example) sets `clickhouse.external.enabled: true` with `existingSecretName: langsmith-clickhouse`. This overrides the in-cluster ClickHouse configuration and expects an external secret that doesn't exist.

**Fix:** `init-values.sh` now generates a minimal insights file when `clickhouse_source = "in-cluster"`:
```yaml
config:
  insights:
    enabled: true
# No clickhouse.external block — chart uses in-cluster ClickHouse
```

If you have this issue on an existing deployment, overwrite the file and redeploy:
```bash
cat > helm/values/langsmith-values-insights.yaml << 'EOF'
config:
  insights:
    enabled: true
EOF
make deploy
```

For **external ClickHouse** (production with LangChain managed ClickHouse), the full configuration is in `helm/values/examples/langsmith-values-insights.yaml`.

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

## Teardown / Clean

### `make clean` before `make destroy` — tfstate deleted, infrastructure orphaned

**Symptom:** `make clean` was run before `make destroy`. Terraform's `terraform.tfstate` is deleted. Running `make destroy` now fails immediately:
```
No state file was found!
```
All Azure resources (AKS, VNet, Key Vault, Storage, etc.) are still running but Terraform has lost all tracking.

**Cause:** `make clean` removes local secrets and generated files including `terraform.tfvars` and `secrets.auto.tfvars`. Without `terraform.tfvars`, Terraform cannot initialize the backend or identify any resources.

**Correct teardown order:**
```
1. make uninstall   ← Helm + namespace
2. make destroy     ← Azure infra (needs tfstate + tfvars)
3. make clean       ← local secrets and generated files (LAST)
```

**Recovery when tfstate is gone:**
```bash
# Delete the entire resource group directly — removes everything in one shot
az group delete --name langsmith-rg<identifier> --yes --no-wait

# Watch until deletion completes
az group show --name langsmith-rg<identifier> 2>&1 | grep -E "provisioningState|ResourceGroupNotFound"
# Once you see "ResourceGroupNotFound", all resources are deleted
```

> **Key Vault soft-delete after forced deletion:** If you reuse the same `identifier`, Azure will recover the soft-deleted Key Vault on the next `terraform apply`. If `keyvault_purge_protection = false`, purge it first:
> ```bash
> az keyvault purge --name langsmith-kv<identifier> --location <region>
> ```

---

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

---

## AGIC (Application Gateway Ingress Controller)

### AGIC pod CrashLoopBackOff — 403 on AGW GET

**Symptom:** `ingress-appgw-deployment` in `kube-system` is CrashLoopBackOff. Logs show:

```
ErrorApplicationGatewayForbidden: does not have authorization to perform action
Microsoft.Network/applicationGateways/read
```

**Cause:** AKS creates its own managed identity for the `ingress_application_gateway` add-on (named `ingressapplicationgateway-<cluster>` in the MC_ resource group). The identity is created during cluster provisioning but requires ~5 minutes to register in Azure AD before role assignments take effect. If Terraform creates assignments too quickly, the AGIC controller gets persistent 403s even though the assignments appear valid in ARM.

**Fix (Terraform — current):**
The `k8s-cluster` module creates all three role assignments automatically and waits 300s after cluster creation (`time_sleep.agic_identity_propagation`) to allow Azure AD registration before creating them. On fresh deploys this is handled automatically.

**Fix (existing cluster — if AGIC is still 403 after `make apply`):**
```bash
# Trigger AKS reconciliation — this re-registers the AGIC identity
az aks update --name <CLUSTER> --resource-group <RG> --yes

# Wait 2-3 min, then restart the AGIC pod
kubectl delete pod -n kube-system -l app=ingress-azure
```

**Fix (manual role assignments — for debugging or pre-existing clusters):**
```bash
AGIC_OID=$(az aks show -g <RG> -n <CLUSTER> \
  --query "addonProfiles.ingressApplicationGateway.identity.objectId" -o tsv)

RG_ID="/subscriptions/<sub>/resourceGroups/<RG>"
AGW_ID=$(az network application-gateway show -g <RG> -n <AGW> --query id -o tsv)
VNET_ID=$(az network vnet show -g <RG> -n <VNET> --query id -o tsv)

az role assignment create --role Reader --scope "$RG_ID" --assignee-object-id "$AGIC_OID" --assignee-principal-type ServicePrincipal
az role assignment create --role Contributor --scope "$AGW_ID" --assignee-object-id "$AGIC_OID" --assignee-principal-type ServicePrincipal
az role assignment create --role "Network Contributor" --scope "$VNET_ID" --assignee-object-id "$AGIC_OID" --assignee-principal-type ServicePrincipal

# Wait 5 min for propagation, then restart AGIC pod
kubectl delete pod -n kube-system -l app=ingress-azure
```

---

### AGIC — `ApplicationGatewayInsufficientPermissionOnSubnet`

**Symptom:** AGIC pod running but logs show:

```
Code="ApplicationGatewayInsufficientPermissionOnSubnet"
Message="Client ... does not have permission on the Virtual Network resource
.../subnets/...-subnet-agic to perform action
Microsoft.Network/virtualNetworks/subnets/join/action"
```

**Cause:** The AGIC add-on identity is missing **Network Contributor on the VNet**. This is separate from the Contributor role on the AGW. Azure RBAC propagation can also take 5–10 minutes.

**Fix:**
```bash
AGIC_OID=$(az aks show -g <RG> -n <CLUSTER> \
  --query "addonProfiles.ingressApplicationGateway.identity.objectId" -o tsv)
VNET_ID=$(az network vnet show -g <RG> -n <VNET> --query id -o tsv)

az role assignment create --role "Network Contributor" --scope "$VNET_ID" \
  --assignee-object-id "$AGIC_OID" --assignee-principal-type ServicePrincipal

# Wait ~5 min for propagation, then restart AGIC
kubectl rollout restart deployment/ingress-appgw-deployment -n kube-system
```

---

### AGIC — `SecretNotFound` for TLS secret, site returns connection timeout

**Symptom:** `kubectl describe ingress langsmith-ingress -n langsmith` shows:

```
Warning  SecretNotFound  azure/application-gateway  Unable to find the secret
associated to secretId: [langsmith/langsmith-tls]
```

Site returns connection timeout (no HTTP response).

**Cause:** AGIC saw the Ingress resource before cert-manager had issued the TLS certificate. AGIC programmed the AGW backend but without the TLS cert.

**Fix:** Touch the ingress annotation to trigger re-sync after the cert is ready:
```bash
# Verify cert is ready first
kubectl get certificate langsmith-tls -n langsmith

# Force AGIC re-sync
kubectl annotate ingress langsmith-ingress -n langsmith touch="$(date +%s)" --overwrite
```

---

### AGIC — `ingressClassName: azure/application-gateway` rejected by Kubernetes

**Symptom:** `helm upgrade` fails with:

```
Ingress.networking.k8s.io "langsmith-ingress" is invalid:
spec.ingressClassName: Invalid value: "azure/application-gateway":
a lowercase RFC 1123 subdomain must consist of lower case alphanumeric characters, '-' or '.'
```

**Cause:** The legacy annotation `kubernetes.io/ingress.class: azure/application-gateway` (with slash) is not a valid `ingressClassName`. The AKS add-on creates an `IngressClass` resource named `azure-application-gateway` (with hyphen).

**Fix:** Use `ingressClassName: azure-application-gateway` (hyphen, not slash). `make init-values` sets this automatically.

---

## Istio (self-managed Helm)

### Istio site returns connection refused / no routes (LDS resources:0)

**Symptom:** Site returns connection refused or timeout. `pilot-agent request GET config_dump` shows `LDS: PUSH resources:0`. HTTP also fails.

**Root causes (all three must be fixed):**

1. `meshConfig.ingressControllerMode` not set — istiod defaults to `DEFAULT` which ignores `ingressClassName`. Must be `STRICT`.
2. `istio` IngressClass resource missing — istiod won't generate listeners without it.
3. `meshConfig.ingressClass` not set to `istio` — istiod won't match the Ingress resource.

**Fix:** All three are automated — `meshConfig` is set in the istiod Helm release (Terraform), `deploy.sh` creates the IngressClass.

**Manual fix:**
```bash
# Create IngressClass
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
YAML

# Restart istiod to pick up mesh config
kubectl rollout restart deployment/istiod -n istio-system
```

---

### Istio HTTPS returns "no peer certificate available"

**Symptom:** HTTP works (200), HTTPS fails. `openssl s_client` shows `no peer certificate available`.

**Cause:** istiod reads the TLS secret via SDS (`kubernetes://langsmith-tls`). The secret must exist in `istio-system` (the gateway pod namespace). cert-manager issues it to the `langsmith` namespace — it is not copied automatically.

**Fix:** `deploy.sh` syncs the secret post-deploy. Manual fix:
```bash
kubectl get secret langsmith-tls -n langsmith -o json | python3 -c "
import sys, json
s = json.load(sys.stdin)
s['metadata']['namespace'] = 'istio-system'
for k in ['resourceVersion','uid','creationTimestamp']:
    s['metadata'].pop(k, None)
s['metadata']['annotations'] = {}
print(json.dumps(s))
" | kubectl apply -f -
```

---

### Istio — leftover CRDs from istio-addon block self-managed Helm install

**Symptom:** `terraform apply` fails with:
```
CustomResourceDefinition "wasmplugins.extensions.istio.io" exists and cannot be imported
into the current release: invalid ownership metadata
```

**Cause:** Switching from `istio-addon` to `istio` leaves AKS-managed Istio CRDs without Helm ownership annotations.

**Fix:**
```bash
kubectl get crd | grep "istio.io" | awk '{print $1}' | xargs kubectl delete crd
terraform apply
```
