# LangSmith Azure — Security, Performance & Experience Review

> Scope: Full infrastructure-to-application stack review of the Azure self-hosted LangSmith deployment.
> Covers Terraform modules, Helm scripts, secret management, network posture, and customer experience.

---

## Executive Summary

The deployment demonstrates a **strong foundational security posture** — private databases, Workload Identity (zero static credentials), Key Vault RBAC, network isolation, and automated TLS. The ingress controller layer is now thoroughly tested and automated across all five controllers (nginx, istio, istio-addon, agic, envoy-gateway).

**What's working well:** Private-only database endpoints, federated Workload Identity, Key Vault RBAC, automated cert management, NSG subnet isolation, two-tier blob TTL, multi-controller `make deploy` automation.

**What needs attention before going to a production customer:** NSG rules, WAF, diagnostics, ClickHouse external, postgres HA, provider version pinning, secret rotation docs, and a few UX improvements in the deploy flow.

---

## 1. Security

### 1.1 Network Exposure

#### ✅ What's good
- PostgreSQL and Redis are **private-only** (`public_network_access_enabled = false`)
- Redis uses VNet injection on a dedicated Premium subnet, TLS on port 6380 (non-TLS disabled)
- Blob Storage accessed exclusively via Workload Identity — no SAS tokens or storage keys
- Key Vault has no public endpoint; RBAC mode only (no legacy access policies)
- AKS cluster uses Azure CNI — pods get real VNet IPs, direct private DB access without NAT

#### ⚠️ Gaps

**NSGs not explicitly defined**
Subnets exist with correct CIDR isolation, but no Network Security Groups enforce the expected traffic rules. Azure defaults to "allow all within VNet" between subnets.

```
Recommendation: Create networking/nsg.tf with:
- AKS subnet: allow 443 inbound from internet (ingress LB), deny all else
- PostgreSQL subnet: allow 5432 from AKS subnet only
- Redis subnet: allow 6380 from AKS subnet only
- Bastion subnet: allow 22 from corporate VPN CIDR only
```

**Bastion SSH CIDR defaults to 0.0.0.0/0**
`infra/variables.tf` — `bastion_allowed_ssh_cidrs` defaults to `["0.0.0.0/0"]`. Any internet IP can attempt SSH to the jump VM.

```hcl
# infra/terraform.tfvars — set before enabling bastion
bastion_allowed_ssh_cidrs = ["<your-vpn-cidr>/32"]
```

**Network egress policy is unrestricted**
`k8s-bootstrap/main.tf` has a default-deny ingress NetworkPolicy but no egress rules. Compromised pods can reach any external endpoint.

```yaml
# Recommendation: add egress policy
- Allow: UDP/TCP 53 (CoreDNS)
- Allow: TCP 5432 to postgres private IP
- Allow: TCP 6380 to redis private IP
- Allow: TCP 443 to Azure Blob Storage endpoint
- Deny: everything else
```

---

### 1.2 Identity & Access Control

#### ✅ What's good
- **Zero static credentials** — all pod-to-Azure authentication via Workload Identity (OIDC federation)
- Eight service accounts federated: backend, platform-backend, queue, ingest-queue, host-backend, listener, agent-builder-tool-server, agent-builder-trigger-server
- Separate managed identities per concern (app, cert-manager, AGIC add-on)
- Key Vault roles scoped to Key Vault resource, not subscription
- AGIC add-on identity now gets exactly three roles: Reader (RG), Contributor (AGW), Network Contributor (VNet) — no more, no less

#### ⚠️ Gaps

**No explicit Kubernetes RBAC for LangSmith pods**
Pods run with namespace-level permissions inherited from the default service account. There is no ClusterRole restricting what the LangSmith SA can read in other namespaces.

```yaml
# Recommendation: add to k8s-bootstrap
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: langsmith-role
  namespace: langsmith
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

**No Pod Security Standards enforced**
No PSS (Pod Security Standards) labels on the `langsmith` namespace. Pods could mount host paths or run as root without rejection.

```hcl
# Add namespace label in k8s-bootstrap
resource "kubernetes_manifest" "pss_label" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.langsmith_namespace
      labels = {
        "pod-security.kubernetes.io/enforce" = "baseline"
        "pod-security.kubernetes.io/warn"    = "restricted"
      }
    }
  }
}
```

---

### 1.3 Secret Management

#### ✅ What's good
- All secrets stored in Key Vault with soft-delete (90 days) and purge protection
- RBAC mode: access fully auditable, revocable per identity
- Critical secrets (`api_key_salt`, `jwt_secret`) have `lifecycle.ignore_changes = true` — accidental Terraform runs cannot rotate and break existing sessions
- `setup-env.sh` reads from Key Vault on repeat runs — no re-entry of secrets

#### ⚠️ Gaps

**Secrets transit through shell during `create-k8s-secrets.sh`**
The current flow is: Key Vault → shell variable → `kubectl create secret`. Secrets briefly exist in shell memory and may appear in process lists or shell history.

```
Recommendation: Migrate to CSI Secrets Store driver
- infra/modules/k8s-cluster already sets secret_rotation_interval = "2m" in cluster config
- Add SecretProviderClass resource in k8s-bootstrap
- Secrets mount directly into pods — never touch shell
```

**No secret rotation procedure documented**
There's no runbook for rotating the JWT secret, API key salt, or encryption keys. Incidents require knowing which keys can be rotated without data loss.

```
Recommendation: Add to Makefile:
  make rotate-secret SECRET=langsmith-jwt-secret   # updates KV + recreates K8s secret
  make rotate-secret SECRET=langsmith-admin-password

Critical warning: api_key_salt and *_encryption_key values must NEVER be rotated
after first enable — rotating them permanently breaks existing encrypted data.
```

**Encryption at rest — Microsoft-managed keys only**
PostgreSQL, Redis, and Blob Storage all use Microsoft-managed encryption keys. For regulatory compliance (HIPAA, SOC2 Type II, FedRAMP) customer-managed keys (CMK) via Key Vault may be required.

```hcl
# infra/modules/postgres/main.tf — add when compliance requires:
customer_managed_key {
  key_vault_key_id                  = azurerm_key_vault_key.postgres_cmk.id
  primary_user_assigned_identity_id = azurerm_user_assigned_identity.postgres_cmk.id
}
```

---

### 1.4 TLS & Certificate Management

#### ✅ What's good
- cert-manager fully automated across all 5 ingress controllers
- Let's Encrypt production ACME with HTTP-01 or gatewayHTTPRoute solver
- ClusterIssuer solver class automatically matched to active ingress controller by `deploy.sh`
- TLS secret namespace sync automated for istio-addon (to `aks-istio-ingress`) and self-managed istio (to `istio-system`)
- TLS enforced end-to-end: HTTPS ingress → Kubernetes → private DB (TLS on postgres/redis connections)

#### ⚠️ Gaps

**No mTLS between LangSmith microservices**
Internal service-to-service traffic (backend → platform-backend → queue, etc.) is unencrypted within the cluster. With istio or istio-addon, mTLS can be enforced transparently.

```yaml
# For istio/istio-addon: add PeerAuthentication
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: langsmith-mtls
  namespace: langsmith
spec:
  mtls:
    mode: STRICT
```

**Let's Encrypt rate limits**
Let's Encrypt enforces 5 duplicate certificates per week per domain. Repeated `make deploy` cycles against the same domain can hit this limit.

```
Recommendation:
- Cache cert between cluster recreations: backup langsmith-tls secret to Key Vault
- Use letsencrypt-staging for dev/test cycles (already prepared in examples/letsencrypt-issuer-dns01.yaml)
- Add letsencrypt_staging = true variable to deploy.sh
```

---

### 1.5 Ingress Security

#### WAF not enabled by default

The WAF module (`infra/modules/waf/main.tf`) implements OWASP CRS 3.2 + Microsoft Bot Manager but is disabled by default.

```hcl
# infra/terraform.tfvars — enable for production
create_waf = true

# When using AGIC, WAF is built into the Application Gateway:
agw_sku_tier = "WAF_v2"   # No separate WAF module needed — same price tier, built-in WAF
```

**OWASP CRS 3.2 covers:** SQL injection, XSS, Log4Shell, Spring4Shell, path traversal, protocol violations.

**Recommendation:** Enable in Prevention mode (not Detection) for production:
```hcl
waf_mode   = "Prevention"
create_waf = true
```

#### DDoS Protection
No Azure DDoS Standard protection plan configured. Basic DDoS protection is included free but has no SLA or adaptive tuning.

```
Recommendation for enterprise customers:
- Azure DDoS Standard: ~$2,944/month for a protection plan
- Covers all public IPs in the VNet
- Add to infra/modules/networking as optional: create_ddos_protection = true
```

---

### 1.6 Audit Logging

#### Diagnostics disabled by default

`create_diagnostics = false` means no centralized log collection. Key Vault access, AKS control plane, and PostgreSQL query logs are not retained.

```hcl
# infra/terraform.tfvars — enable for production
create_diagnostics  = true
log_retention_days  = 365   # 1 year for compliance
```

**What gets logged when enabled:**
- ✅ AKS control plane (apiserver, scheduler, controller-manager)
- ✅ Key Vault access (who read/wrote/deleted which secret, with caller identity)
- ✅ PostgreSQL slow queries and connection events
- ❌ Azure Load Balancer access logs — not in diagnostics module (add it)
- ❌ Blob Storage access logs — not in diagnostics module (add it)

**Recommendation:** Add ALB and Blob diagnostic settings to `infra/modules/diagnostics/main.tf`.

---

### 1.7 Supply Chain

#### ✅ What's good
- All Terraform providers from official HashiCorp registry
- All Helm repos from official sources (kubernetes.github.io, istio-release.storage.googleapis.com, charts.jetstack.io, langchain-ai.github.io)
- Envoy Gateway via official OCI registry (`docker.io/envoyproxy`)

#### ⚠️ Terraform provider versions too loose

```hcl
# Current (infra/versions.tf)
azurerm = "~> 4.0"   # Allows 4.0 to <5.0

# Recommendation for production
azurerm    = "~> 4.5"   # Pin to minor version
kubernetes = "~> 2.31"
helm       = "~> 2.15"
```

#### LangSmith Helm chart unpinned by default

`langsmith_helm_chart_version = ""` defaults to latest. Upgrades can silently run DB migrations.

```hcl
# infra/terraform.tfvars
langsmith_helm_chart_version = "0.13.35"   # Pin before customer handoff
```

---

## 2. Performance

### 2.1 Node Pool Sizing

| Profile | VM | vCPU | RAM | Recommended For |
|---|---|---|---|---|
| dev/POC | Standard_DS3_v2 | 4 | 14 GB | Demo, quick tests |
| standard | Standard_D8s_v3 | 8 | 32 GB | Pass 2 default |
| production | Standard_D8s_v3 × 3–5 | 24–40 | 96–160 GB | Pass 2+3 |
| production-large | Standard_D8s_v3 × 6–8 | 48–64 | 192–256 GB | Pass 4+5, agent builder |

**Pass 2 baseline scheduled resource estimate:**
```
backend (×1 dev, ×3 prod): 1–3 vCPU / 2–6 GiB
platform-backend:           1 vCPU / 2 GiB
queue (×1 dev, ×3 prod):   1–3 vCPU / 2–6 GiB
ingest-queue:               1 vCPU / 2 GiB
frontend:                   100m / 256 MiB
ace-backend:                500m / 1 GiB
playground:                 500m / 512 MiB
clickhouse (in-cluster):    3.5 vCPU / 15 GiB (large pool)
cert-manager + KEDA + nginx: ~1 vCPU / 2 GiB

Total Pass 2: ~9 vCPU / 25 GiB (dev) | ~17 vCPU / 39 GiB (production)
```

**Autoscaler tuning:**
```hcl
# Current default (variables.tf)
default_node_pool_min_count = 2   # Bump from 1 for production HA
default_node_pool_max_count = 10

# Recommendation for production
default_node_pool_min_count = 3   # Maintain quorum across AZs
```

---

### 2.2 Database Performance

#### PostgreSQL
```hcl
# Current default
sku_name     = "GP_Standard_D2ds_v4"   # 2 vCPU, 8 GB RAM
storage_mb   = 32768                    # 32 GB
max_connections = 256
```

**Issue:** LangSmith runs 5+ services with connection pools. Each service default pool size is ~10 connections. At 3 replicas: 5 services × 3 replicas × 10 = 150 connections. Leaves 106 for migrations, admin.

```hcl
# Recommendation for production
sku_name        = "GP_Standard_D4ds_v4"  # 4 vCPU, 16 GB
max_connections = 500
# Consider PgBouncer for connection pooling (reduces connection overhead)
```

**Missing: storage auto-grow.** If blob payloads accidentally land in Postgres (wrong config), 32 GB fills fast.

```hcl
# Add to postgres module
storage_auto_grow_enabled = true
```

#### Redis
```hcl
# Current default
capacity = 2   # P2 = 13 GB
```

**Guidance:**
- P2 (13 GB): Up to ~50 concurrent users, moderate trace volume
- P3 (26 GB): 50–200 users, high-throughput ingestion
- P4 (53 GB): High-volume production

**KEDA queue scaling** amplifies Redis load — more workers consume more queue reads. Monitor `used_memory` and `connected_clients` at scale.

---

### 2.3 ClickHouse

**Critical for production:** In-cluster ClickHouse is a single StatefulSet pod with no replication, no backups, and no HA. A node failure causes data loss and analytics outage.

```
For production: always use external ClickHouse
clickhouse_source = "external"
# → LangChain Managed ClickHouse (https://docs.langchain.com/langsmith/langsmith-managed-clickhouse)
# → Or self-hosted ClickHouse cluster with replication factor ≥ 2

For dev/POC: in-cluster is acceptable (set expectations with customer)
clickhouse_source = "in-cluster"
```

---

### 2.4 KEDA Autoscaling

KEDA scales `queue` and `ingest-queue` pods based on Redis queue depth (LLEN). This is the primary horizontal scaling mechanism for trace ingestion throughput.

**Recommendation:** Set explicit bounds to prevent runaway scaling:

```yaml
# helm/values/values-overrides.yaml
queue:
  autoscaling:
    maxReplicas: 10      # Prevent unconstrained scale-out
    targetQueueLength: 20  # Scale 1 pod per 20 queued items

ingestQueue:
  autoscaling:
    maxReplicas: 10
    targetQueueLength: 20
```

**Monitoring KEDA scaling:**
```bash
kubectl get scaledobjects -n langsmith
kubectl describe scaledobject langsmith-queue-scaledobject -n langsmith
```

---

### 2.5 Ingress Controller Comparison

| Controller | Throughput | Latency overhead | Operational complexity | Recommended for |
|---|---|---|---|---|
| **nginx** | High | Minimal | Low | Default — all customers |
| **istio-addon** | High | ~10ms (sidecar) | Medium | Mesh features, mTLS |
| **istio (self-managed)** | High | ~10ms (sidecar) | High | Full mesh control |
| **agic** | High | Minimal (L7 hardware) | Medium | Enterprise, WAF built-in |
| **envoy-gateway** | High | Minimal | Medium | Gateway API native, future-proof |

**Recommendation by customer type:**
- **Quick POC / SA demo:** nginx (5-minute setup, zero surprises)
- **Enterprise with compliance:** agic with `agw_sku_tier = "WAF_v2"` (built-in WAF, no extra module)
- **Service mesh requirements:** istio-addon (Azure managed, lower ops burden than self-managed)
- **Modern infra / Gateway API:** envoy-gateway

---

### 2.6 Blob Storage

```hcl
# Current
account_replication_type = "LRS"  # 3 copies, single AZ
```

**LRS** is sufficient for dev and most POC. For production:

```hcl
account_replication_type = "GRS"    # Geo-redundant — 6 copies across 2 regions
# or
account_replication_type = "ZRS"    # Zone-redundant — 3 copies across 3 AZs (same region, lower latency)
```

**TTL policy** (current defaults):
- `ttl_s/` prefix: deleted after 14 days (short-lived traces)
- `ttl_l/` prefix: deleted after 400 days (long-lived assets)

**Recommendation:** Review TTL values with customer against data retention policy. HIPAA requires 6 years; GDPR requires honoring deletion requests.

---

## 3. Customer Experience Improvements

### 3.1 Preflight Checks — Add More Coverage

`helm/scripts/preflight-check.sh` currently checks: az CLI, kubectl, helm, terraform login, cluster connectivity.

**Missing checks:**
```bash
# Add to preflight-check.sh:
- Key Vault RBAC: az keyvault secret list --vault-name $KV (confirm access before deploy)
- Storage account: verify blob container exists (fails silently if missing)
- PostgreSQL: pg_isready via kubectl port-forward (validate DB connectivity before Helm)
- Redis: redis-cli PING via kubectl port-forward (validate before Helm)
- Required namespace quotas: warn if quota would block pod scheduling
- Available node capacity: warn if cluster is within 80% of capacity
```

---

### 3.2 `make status` — Richer Health Dashboard

Current `make status` shows pod states. Extend to show:

```bash
# Suggested additions to status output:
- Certificate expiry date (days until renewal)
- Current Helm chart version vs latest available
- PostgreSQL connection pool usage (active vs max_connections)
- Redis used_memory vs maxmemory
- Blob storage used capacity
- KEDA queue depth (current backlog)
- Recent error rate from logs (kubectl logs --since=1h | grep ERROR | wc -l)
```

---

### 3.3 Single-File Config for Customer Handoff

Today a customer needs to set values in `terraform.tfvars` and potentially `app/terraform.tfvars`. Consider a single `langsmith.config` file that drives both:

```bash
# langsmith.config (sourced by Makefile)
LANGSMITH_DOMAIN="langsmith.customer.com"
LANGSMITH_ADMIN_EMAIL="admin@customer.com"
INGRESS_CONTROLLER="agic"
SIZING_PROFILE="production"
POSTGRES_SOURCE="external"
REDIS_SOURCE="external"
CLICKHOUSE_SOURCE="external"
```

Then `make setup` generates `terraform.tfvars` from this file. Reduces configuration surface for SAs.

---

### 3.4 Upgrade Path Documentation

Currently there is no documented upgrade procedure for:
- LangSmith Helm chart version bump
- AKS Kubernetes version upgrade
- cert-manager version upgrade
- Istio version upgrade (self-managed)

**Recommendation:** Add `UPGRADES.md`:

```markdown
# Upgrading LangSmith

## Helm chart upgrade
1. Update langsmith_helm_chart_version in terraform.tfvars
2. make init-values   # Re-generate values
3. make deploy        # Runs helm upgrade --install

## AKS version upgrade
1. az aks upgrade -g <RG> -n <CLUSTER> --kubernetes-version 1.30.x
2. terraform apply   # Reconciles state

## cert-manager upgrade
1. Update cert_manager_version in variables.tf
2. terraform apply -target module.k8s_bootstrap.helm_release.cert_manager
```

---

### 3.5 Multi-Region / Disaster Recovery Guidance

No DR documentation exists. Customers will ask.

**Recommended DR architecture:**

```
Primary Region (eastus)          Secondary Region (westus2)
├── AKS cluster + LangSmith      ├── Standby AKS (can be cold)
├── PostgreSQL (primary)  ──────▶ PostgreSQL (geo-replica, read-only)
├── Redis P2              ──────▶ Redis P2 (geo-replica, Premium)
├── Blob Storage (LRS)    ──────▶ Blob Storage (GRS = auto-replicated)
└── Key Vault             ──────▶ Key Vault (replication via policy)

Failover: promote Postgres replica → switch DNS → deploy LangSmith in secondary
RTO: ~30 min | RPO: <1 min (continuous Postgres streaming replication)
```

**Add to ARCHITECTURE.md** with diagram.

---

### 3.6 Cost Estimation by Tier

SAs need to answer "how much does this cost?" Add a cost table to `README.md`:

| Tier | Components | Estimated Monthly Cost (East US) |
|---|---|---|
| **POC / Demo** | 2× DS3_v2 nodes + all in-cluster | ~$400–600 |
| **Standard** | 3× D8s_v3 + external PG D2 + Redis P2 + Blob | ~$1,200–1,800 |
| **Production** | 5× D8s_v3 + PG D4 HA + Redis P3 + Blob GRS + WAF + Diagnostics | ~$3,000–4,500 |
| **Production-Large** | 8× D8s_v3 + PG D8 HA + Redis P4 + Blob GRS + WAF + AGIC WAF_v2 | ~$6,000–8,000 |

*Excludes LangSmith license. Estimates only — run Azure Pricing Calculator for exact figures.*

---

### 3.7 Observability Stack

No Prometheus/Grafana setup is included. LangSmith emits metrics that are useful for capacity planning.

**Recommended addition (optional, `create_monitoring = true`):**

```
- kube-prometheus-stack (Prometheus + Grafana + AlertManager)
- Pre-built dashboards for:
  - LangSmith queue depth (KEDA backlog)
  - Postgres connection pool saturation
  - Redis memory usage
  - Ingress request rate / error rate / p99 latency
  - Pod CPU/memory vs limits (headroom alert)
```

**Quick win — Grafana dashboards as a use-case under `helm/values/use-cases/monitoring/`.**

---

### 3.8 `make clean` Bug ✅ Fixed

`infra/scripts/clean.sh` had a syntax error where `grep -c` exits 1 on no matches (outputting "0"), and `|| echo 0` appended a second "0", making `_state_resources="0\n0"` which `[[ -gt 0 ]]` rejected. Fixed by using `; true` instead of `|| echo 0`.

---

### 3.9 LangSmith License Key UX

Currently `setup-env.sh` prompts for the license key on first run. SAs often get this wrong or paste incorrectly.

**Recommendation:** Add a `--license-file` flag:
```bash
make setup-env LANGSMITH_LICENSE_FILE=~/Downloads/langsmith.license
# Reads license from file, skips interactive prompt
```

---

## 4. Priority Matrix

| Priority | Item | Effort | Impact |
|---|---|---|---|
| 🔴 Critical | External ClickHouse for production | Low (1 tfvar) | High — prevents data loss |
| 🔴 Critical | Enable diagnostics + WAF for production | Low (2 tfvars) | High — audit + attack surface |
| 🔴 Critical | Bastion SSH CIDR restriction | Low (1 tfvar) | High — eliminates world-open SSH |
| 🟠 High | NSG rules per subnet | Medium (new nsg.tf) | High — defense in depth |
| 🟠 High | Pin Helm chart + provider versions | Low | Medium — reproducible deploys |
| 🟠 High | Secret rotation runbook in Makefile | Low | Medium — incident readiness |
| 🟠 High | Postgres HA standby + storage auto-grow | Low (2 tfvars) | High — production resilience |
| 🟡 Medium | CSI Secrets Store driver migration | High | Medium — removes shell secret transit |
| 🟡 Medium | Pod Security Standards (baseline) | Low | Medium — prevent privileged pods |
| 🟡 Medium | mTLS (PeerAuthentication for istio) | Low | Medium — east-west encryption |
| 🟡 Medium | Kubernetes RBAC for langsmith SA | Low | Medium — least privilege |
| 🟡 Medium | `make status` — extended health checks | Medium | High — SA and customer UX |
| 🟢 Nice | Observability stack (Prometheus/Grafana) | High | High — capacity planning |
| 🟢 Nice | DR / multi-region architecture | High | High — enterprise requirement |
| 🟢 Nice | Cost estimation table in README | Low | Medium — SA sales conversations |
| 🟢 Nice | Upgrade path documentation (UPGRADES.md) | Low | Medium — day-2 operations |
| 🟢 Nice | Single-file customer config | Medium | Medium — reduces SA setup errors |

---

## 5. Quick Wins (Ship This Week)

These are low-effort, high-impact and can be done before the next customer engagement:

```hcl
# infra/terraform.tfvars — for any production customer

# 1. Lock down bastion
bastion_allowed_ssh_cidrs = ["10.0.0.0/8"]   # or corporate VPN

# 2. Enable audit trail
create_diagnostics = true
log_retention_days = 365

# 3. Enable WAF (AGIC customers get this free with WAF_v2)
create_waf = true

# 4. Postgres HA
postgres_standby_availability_zone = "2"

# 5. Geo-redundant storage
# → Edit infra/modules/storage/main.tf: account_replication_type = "GRS" (conditional on env)

# 6. Pin chart version
langsmith_helm_chart_version = "0.13.35"

# 7. External ClickHouse
clickhouse_source = "external"
```

And fix the `make clean` bug.

---

*Review completed: 2026-03-29*
*Covers: terraform/azure/infra/**, helm/scripts/**, infra/modules/**/*, Makefile*
*Next review recommended after: Pass 3–5 components validation, multi-dataplane testing*
