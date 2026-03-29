# LangSmith on Azure — SA Deployment Writeup

> **Audience:** SA team internal. Use this as prep for customer conversations, architecture reviews, or handoff docs. This is the e2e story of how we build a LangSmith cluster on Azure — module by module, dependency by dependency, decision by decision.

---

## The Two-Pass Model

Everything we do fits into two passes:

| Pass | What Happens | Tool | Time |
|------|-------------|------|------|
| **Pass 1** | Cloud infrastructure — VNet, AKS, Postgres, Redis, Blob, Key Vault, ingress controller, cert-manager, KEDA | Terraform | 15–20 min |
| **Pass 2** | Application deployment — LangSmith Helm chart, secrets wiring, feature overlays | Helm + scripts OR Terraform Helm (`make apply-app`) | 10 min |

The split matters because Terraform owns all the durable infrastructure and Helm owns the application lifecycle. Customers can run `terraform destroy` to wipe infrastructure or `helm uninstall` to wipe the app, independently. It also means customer security teams can review Terraform separately from app config.

**Azure has two valid Pass 2 paths:**

| Path | Command | When to use |
|------|---------|-------------|
| **Shell path** | `make init-values && make deploy` | Default. Fast, no extra Terraform state to manage. |
| **Terraform Helm path** | `make init-app && make apply-app` | When customer wants full Terraform lifecycle. Helm release, K8s secret, and service account all in state. |

---

## Pass 1: Terraform Infrastructure

### What Gets Built

```
VNet
  └── AKS Cluster
        ├── System Node Pool (Standard_D4s_v3 default)
        ├── User Node Pool (langsmith workloads)
        ├── KEDA (event-driven autoscaling)
        ├── cert-manager (TLS automation)
        ├── Ingress Controller (nginx / istio / istio-addon / agic / envoy-gateway)
        └── K8s Bootstrap (namespace, secrets, KEDA, cert-manager)

Azure Database for PostgreSQL   ──┐
Azure Cache for Redis           ──┤── all in private subnets, behind NSGs
Azure Blob Storage              ──┤
Azure Key Vault                 ──┘

Workload Identity (WI)
  └── Managed Identity → federated credentials per service account
```

### Naming Convention

Everything follows `langsmith-{resource}-{identifier}`. For example with `identifier = "-prod"`:
- `langsmith-aks--prod` — AKS cluster
- `langsmith-pg--prod` — PostgreSQL server
- `langsmith-redis--prod` — Redis cache
- `langsmith-storage--prod` — Storage account (Blob)
- `langsmith-kv--prod` — Key Vault

All resources are in a single resource group: `langsmith-rg-{identifier}`.

---

## Module-by-Module Breakdown

### 1. `networking` — VNet Foundation

**What it does:**
Creates the VNet that everything else lives in. Default CIDR is `10.0.0.0/8`. Provisions subnets: one for AKS nodes, one for PostgreSQL flexible server, one for Redis (private endpoint).

**Why it's designed this way:**
- All workloads in private subnets — no direct public IPs on pods or data stores.
- AKS subnet gets its own range for pod CIDR assignment.
- PostgreSQL flexible server requires its own delegated subnet (`Microsoft.DBforPostgreSQL/flexibleServers`).
- Redis is accessed via private endpoint — no public exposure.

**Key outputs:** `vnet_id`, `aks_subnet_id`, `postgres_subnet_id`, `redis_subnet_id`, `subnet_agic_id`

**AGIC subnet:** When `ingress_controller = "agic"`, a dedicated `/24` subnet (`10.0.96.0/24`) is created automatically. Application Gateway v2 requires an exclusive subnet — no other resources allowed.

**Skip this module if:** Customer has an existing VNet. Provide subnet IDs directly in `terraform.tfvars`.

---

### 2. `k8s-cluster` — AKS Cluster

**What it does:**
Provisions the AKS control plane, system + user node pools, and the ingress controller.

**Default node pool:**
- Instance: `Standard_D4s_v3` (4 vCPU, 16 GB RAM)
- Min: 2 nodes, Max: 10 nodes
- OS: Azure Linux (CBLMariner) — minimal attack surface, faster startup

**Add-ons managed by this module:**

| Add-on | What it does |
|--------|-------------|
| KEDA | Event-driven autoscaling for listener/operator pods (Deployments feature) |
| cert-manager | Automates TLS certificate issuance via ACME (Let's Encrypt) |
| NGINX Ingress | Default ingress controller — LoadBalancer service with public Azure IP |
| Istio (optional) | Self-managed via Helm — `istio/base`, `istiod`, `istio/gateway` |
| AKS Istio add-on (optional) | Azure-managed Istio control plane — `azureServiceMesh` |
| AGIC (optional) | Application Gateway v2 + AGIC Helm chart — separate managed identity with Contributor on AGW, Reader on RG, federated credential for Workload Identity ARM auth |
| Envoy Gateway (optional) | CNCF Envoy Gateway via `oci://docker.io/envoyproxy/gateway-helm` — Gateway API native |

**Workload Identity (WI) setup:**
AKS OIDC issuer + Azure managed identity + federated credentials = pods access Azure Blob without static credentials. This module creates the managed identity and registers federated credentials for each service account that needs Blob access. Equivalent to AWS IRSA.

For AGIC: a separate `<cluster>-agic-identity` managed identity is created with its own federated credential binding to `system:serviceaccount:ingress-basic:ingress-azure`.

**Key outputs:** `cluster_name`, `oidc_issuer_url`, `workload_identity_client_id`, `agw_public_ip_fqdn`, `agw_name`

**Customer question to anticipate:** *"Can we use Virtual Nodes (ACI)?"* — Not with this module. AKS managed node pools give better control over instance types and add-on compatibility. ACI also has constraints with stateful workloads.

---

### 3. `postgres` — Azure Database for PostgreSQL Flexible Server

**What it does:**
Provisions a PostgreSQL 16 Flexible Server in a dedicated private subnet. LangSmith uses this as its primary relational store.

**Default config:**
- Instance: `GP_Standard_D2s_v3` (2 vCPU, 8 GB RAM)
- Storage: 32 GB with autoscaling enabled
- Engine: PostgreSQL 16
- HA: disabled by default (enable for production)
- Backup retention: 7 days

**Security:**
- No public access — delegated subnet with private DNS zone
- Private DNS zone: `langsmith-{identifier}.private.postgres.database.azure.com`
- Storage encrypted (ADE)

**Key output:** `connection_url` (includes password)

**Gotcha:** PostgreSQL Flexible Server requires a dedicated delegated subnet. If the customer brings their own VNet, that subnet must have `Microsoft.DBforPostgreSQL/flexibleServers` delegation. This is a hard Azure requirement — unlike RDS which just needs security group rules.

**Gotcha:** Flexible Server can't be restored to the same name within the deletion window. If destroy + recreate fails, change the `identifier` or wait.

---

### 4. `redis` — Azure Cache for Redis

**What it does:**
Provisions an Azure Cache for Redis in a private endpoint configuration. LangSmith uses Redis for caching, session state, and queue coordination.

**Default config:**
- Instance: `C1` Standard (1 GB)
- TLS in-transit: required (port 6380 only)
- Private endpoint: enabled

**Security:**
- Private endpoint in the AKS subnet — Redis not reachable from public internet
- TLS required — `rediss://` connection string
- At-rest encryption enabled by default

**Connection URL format:** `rediss://:auth_token@endpoint:6380` (note double `s` and port 6380 for TLS)

**Important caveat:** Single Redis node by default. For production HA, use Redis Enterprise (use case in this repo: `helm/values/use-cases/redis-enterprise/`).

---

### 5. `storage` — Azure Blob Storage

**What it does:**
Provisions the Azure Storage Account + container where LangSmith stores trace payloads. This is always required — payloads must not go into ClickHouse or you'll crash the cluster.

**Key features:**

**TTL lifecycle rules (built-in):**
- Objects under `ttl_s/*` deleted after 14 days (short-lived traces)
- Objects under `ttl_l/*` deleted after 400 days (long-retention traces)
- LangSmith routes traces to these prefixes based on retention policy set at project level

**Workload Identity access:**
No static storage access keys. LangSmith pods use their Kubernetes service account (annotated with WI client-id) to get a token. Azure validates the token against the OIDC issuer, returns an Azure credential. The storage account has RBAC assignments granting the managed identity `Storage Blob Data Contributor`.

**Key outputs:** `storage_account_name`, `storage_container_name`

---

### 6. `keyvault` — Azure Key Vault

**What it does:**
Provisions the Key Vault where all LangSmith secrets are stored. Terraform is the **sole writer** to Key Vault — `setup-env.sh` is read-only against KV.

**What it stores:**
- `langsmith-license-key`
- `langsmith-api-key-salt` *(stable — do not rotate without planning)*
- `langsmith-jwt-secret` *(stable — do not rotate without planning)*
- `langsmith-admin-password`
- `postgres-password`
- `langsmith-deployments-encryption-key` *(Pass 3)*
- `langsmith-agent-builder-encryption-key` *(Pass 4)*
- `langsmith-insights-encryption-key` *(Pass 5)*
- `langsmith-polly-encryption-key` *(Pass 5)*

**Purge protection:**
- `keyvault_purge_protection = false` (dev/test default) — KV is freed immediately on destroy via `az keyvault purge`. Lets you reuse the same `identifier`.
- `keyvault_purge_protection = true` (production) — KV name is reserved for 90 days after destroy. If set to true, you cannot reuse the same `identifier` for 90 days.

**Key outputs:** `keyvault_id`, `keyvault_uri`, `keyvault_name`

---

### 7. `k8s-bootstrap` — Kubernetes Setup

**What it does:**
After AKS is provisioned, this module sets up the Kubernetes-layer infrastructure that LangSmith depends on.

**What it creates:**
- `langsmith` namespace with labels
- Kubernetes secrets: `langsmith-postgres-secret` and `langsmith-redis-secret` (connection URLs, created by Terraform)
- Service account `langsmith-sa` with WI annotation (for blob access)
- Storage class `managed-csi` as cluster default (for ClickHouse PVCs)

**Note:** The `langsmith-config-secret` (API key salt, JWT secret, license key, passwords) is created by `make k8s-secrets` (`create-k8s-secrets.sh`), not by Terraform. This is a deliberate split — config secrets come from Key Vault, infrastructure secrets (DB/Redis connection URLs) come from Terraform outputs.

---

## Workload Identity (WI): How Azure Permissions Work (No Static Keys)

This is the Azure equivalent of AWS IRSA — a key talking point with security-conscious customers.

**Problem:** LangSmith pods need to read/write Azure Blob Storage. Traditionally you'd use a storage account key — a static credential that never expires.

**Our solution: Workload Identity**

```
LangSmith Pod
  ↓ presents Kubernetes service account JWT (issued by AKS OIDC provider)
Azure AD
  ↓ validates JWT against OIDC issuer URL, exchanges for Azure credential
Azure STS
  ↓ issues short-lived token for the managed identity (1-hour TTL)
Azure Blob Storage (RBAC: Storage Blob Data Contributor)
```

**What gets configured:**
1. AKS OIDC issuer enabled on the cluster
2. Azure managed identity created in the node resource group
3. Federated credential registered: "trust JWTs from AKS OIDC issuer for service account `langsmith/langsmith-sa`"
4. RBAC assignment: managed identity → `Storage Blob Data Contributor` on the storage account
5. Kubernetes service account annotated: `azure.workload.identity/client-id: <managed-identity-client-id>`
6. Pod labeled: `azure.workload.identity/use: "true"`

No storage account keys. No secrets to rotate. Short-lived tokens. Same zero-trust posture as IRSA.

---

## Secrets Flow: Key Vault → K8s Secret → LangSmith

```
setup-env.sh prompts (first run only)
      ↓
secrets.auto.tfvars  (gitignored — picked up automatically by Terraform)
      ↓
terraform apply  →  Azure Key Vault  (Terraform is the sole KV writer)
      ↓
make k8s-secrets  →  create-k8s-secrets.sh  →  langsmith-config-secret (K8s Secret)
      ↓
Helm chart reads via config.existingSecretName: "langsmith-config-secret"
```

**Why not ESO like AWS?**
AWS uses External Secrets Operator for hourly auto-sync. Azure currently uses a one-shot script. ESO does support Azure Key Vault as a provider — if the cluster already has ESO installed, you could add a `ClusterSecretStore` + `ExternalSecret`. This is a future upgrade path. The current script approach is simpler to debug and fully reliable.

**Secret stability warning:**
`langsmith-api-key-salt` and `langsmith-jwt-secret` are stable secrets — changing them invalidates all API keys and logged-in sessions. `setup-env.sh` will not overwrite them if they already exist in Key Vault. Do not rotate unless planning for all users to re-authenticate.

---

## Ingress Controllers: All Four Options

### NGINX (default, recommended for most deployments)

`ingress-nginx` Helm chart creates a LoadBalancer service → Azure assigns a public IP.

**DNS auto-hostname:** Set `dns_label = "myco-langsmith"` → Azure assigns `myco-langsmith.eastus.cloudapp.azure.com`. No DNS zone needed. `deploy.sh` annotates the NGINX service automatically.

**TLS:** `tls_certificate_source = "letsencrypt"` — cert-manager issues a Let's Encrypt cert via HTTP-01 challenge. Fully automated. Cert renews every 60 days.

**Best for:** Standard deployments, simplest setup.

---

### AKS Istio Add-on (`istio-addon`)

Azure-managed Istio control plane. AKS handles Istio upgrades and HA. Creates an external Istio IngressGateway LoadBalancer service.

**DNS:** Same `dns_label` variable works — `deploy.sh` detects `ingress_controller = "istio-addon"` and annotates `aks-istio-ingressgateway-external` in `aks-istio-ingress` namespace.

**`ingressClassName`:** `init-values.sh` sets `ingressClassName: "istio"` automatically.

**Best for:** Customers who want mTLS between services, or Azure SLA-backed Istio.

---

### Self-managed Istio (`istio`)

Installs `istio/base`, `istiod`, `istio/gateway` via Helm. Pinned version for reproducibility.

**DNS:** Same `dns_label` approach — `deploy.sh` annotates `istio-ingressgateway` in `istio-system`.

**Best for:** Customers who need a specific Istio version or want Helm lifecycle control.

---

### Envoy Gateway (`envoy-gateway`)

CNCF Envoy Gateway implementation via `envoyproxy/gateway-helm` (OCI). Gateway API native — uses `GatewayClass` and `HTTPRoute` instead of `Ingress`. `ingress.enabled: false` in LangSmith Helm values; apply Gateway + HTTPRoute resources separately after deploy.

**DNS:** Same `dns_label` approach — `deploy.sh` annotates `envoy-langsmith-langsmith-gateway` in `langsmith` namespace.

**Best for:** Gateway API-native deployments, avoiding Istio complexity.

**Reference values:** `helm/values/examples/langsmith-values-ingress-envoy-gateway.yaml`

---

### AGIC — Application Gateway Ingress Controller (`agic`)

Azure Application Gateway v2 + AGIC Helm chart. Terraform provisions the AGW, AGIC managed identity (separate from the LangSmith app identity), Contributor role on AGW, Reader role on resource group, and federated credential for Workload Identity ARM auth. AGIC watches Kubernetes Ingress resources and programs AGW routing rules dynamically.

**What Terraform creates:**
- AGW subnet (`10.0.96.0/24`) — dedicated, no other resources allowed
- Public IP (Standard SKU, static)
- Application Gateway v2 with placeholder backend/listener (AGIC overwrites on first reconcile)
- `<cluster>-agic-identity` managed identity + role assignments
- AGIC Helm chart in `ingress-basic` namespace

**DNS:** AGW public IP gets an auto-assigned FQDN (`<name>.eastus.cloudapp.azure.com`). `init-values.sh` reads it from `terraform output agw_public_ip_fqdn`. Prefer `langsmith_domain` with a DNS A record for cleaner hostnames.

**TLS:** cert-manager with DNS-01 (recommended — AGW has limited HTTP-01 compatibility) or AGW-native SSL termination with cert from Key Vault.

**WAF:** Set `agw_sku_tier = "WAF_v2"` — no separate WAF module needed. AGW v2 WAF is integrated.

**`ingressClassName`:** `init-values.sh` sets `ingressClassName: "azure/application-gateway"` automatically.

**Best for:** Enterprise Azure customers already using Application Gateway, want native WAF, or aligning with Azure-native ingress (closest to AWS ALB + LBC pattern).

**Reference values:** `helm/values/examples/langsmith-values-ingress-agic.yaml`

---

### Which Ingress for Which Customer?

| Customer Situation | Recommended Ingress |
|-------------------|---------------------|
| Standard deployment, no special requirements | `nginx` |
| Enterprise Azure, already using Application Gateway | `agic` |
| Enterprise Azure, wants native WAF + AGW routing | `agic` with `agw_sku_tier = "WAF_v2"` |
| Needs mTLS, Azure-managed control plane | `istio-addon` |
| Needs mTLS, specific Istio version | `istio` |
| Gateway API native, minimal footprint | `envoy-gateway` |

---

## Pass 2: Helm Deployment

### Shell Path (default)

```bash
make kubeconfig        # az aks get-credentials
make k8s-secrets       # KV → langsmith-config-secret
make init-values       # TF outputs → values-overrides.yaml + addon files
make deploy            # helm upgrade --install langsmith
```

### Terraform Helm Path (alternative)

```bash
make init-app          # pull-infra-outputs.sh → app/infra.auto.tfvars.json → terraform init
make apply-app         # terraform apply (app/) — manages K8s secret, SA, helm_release
```

The `app/` module reads `infra/` outputs via `pull-infra-outputs.sh`, then manages:
- `kubernetes_secret_v1` — `langsmith-config-secret`
- `kubernetes_service_account_v1` — `langsmith-sa` with WI annotation
- `helm_release` — the LangSmith chart with full values chain

### init-values.sh — Generating Values from Terraform

Before deploying Helm (shell path), run `init-values.sh`. It reads your `terraform.tfvars` and `terraform output` and generates:

1. `values-overrides.yaml` — auto-generated with your specific values:
   - `storage_account_name` and `storage_container_name` from Terraform output
   - `workload_identity_client_id` from Terraform output
   - Hostname (from `langsmith_domain` or `dns_label`)
   - TLS settings based on `tls_certificate_source`
   - `ingressClassName` based on `ingress_controller`
2. Feature overlay files (based on which features you enabled in `terraform.tfvars`)
3. Sizing values file (based on `sizing_profile`)

### deploy.sh — Helm Values Layering

Values are merged in order — last file wins:

```
Base values (helm/values/langsmith-values.yaml)
  + Overrides (values-overrides.yaml)
  + Sizing (langsmith-values-sizing-{profile}.yaml)
  + Feature: Deployments (langsmith-values-agent-deploys.yaml)     [if enable_deployments]
  + Feature: Agent Builder (langsmith-values-agent-builder.yaml)   [if enable_agent_builder]
  + Feature: Insights (langsmith-values-insights.yaml)             [if enable_insights]
  + Feature: Polly (langsmith-values-polly.yaml)                   [if enable_polly]
```

**Extra steps deploy.sh handles (non-obvious):**
- Annotates the ingress LoadBalancer service with `service.beta.kubernetes.io/azure-dns-label-name` — targets the correct service per `ingress_controller`. Without this, Azure never assigns the DNS label and cert-manager HTTP-01 challenge fails.
- Creates `letsencrypt-prod` ClusterIssuer if `tls_certificate_source = "letsencrypt"` — cannot be done in Terraform because `kubernetes_manifest` requires a live API server during plan.
- Auto-rolls back `pending-upgrade` Helm release state before proceeding.
- Annotates `langsmith-ksa` service account with WI client-id — this SA is used by operator-spawned agent deployment pods.

### Sizing Profiles

See `helm/values/examples/SIZING.md` for full CPU/memory/replica tables.

| Profile | Use Case | Node Type | Replicas | Resources |
|---------|----------|-----------|----------|-----------|
| `minimum` | Cost optimization, POC | Standard_D4s_v3 × 1 | 1× each | Bare minimum |
| `dev` | Dev/CI/demo | Standard_D4s_v3 × 2 | 1× each | Low requests/limits |
| `production` | ~20 users, 100 traces/sec | Standard_D4s_v3 × 3+ | Multi-replica + HPA | Medium |
| `production-large` | ~50 users, 1000 traces/sec | Standard_D8s_v3 × 5+ | Wide HPA range | High |

---

## Feature Passes (3–5)

Features are enabled by setting flags in `terraform.tfvars` and re-running `make init-values && make deploy` (no `terraform apply` needed):

| Pass | Flag | What it adds |
|------|------|-------------|
| Pass 3 | `enable_deployments = true` | LangSmith Deployments — listener + operator pods, KEDA queue-based autoscaling |
| Pass 4 | `enable_agent_builder = true` | Agent Builder UI — requires Deployments to also be enabled |
| Pass 5 | `enable_insights = true` | Insights dashboards — in-cluster ClickHouse (dev) or external |
| Pass 5 | `enable_polly = true` | Polly AI features |

**Critical dependency:** `enable_agent_builder = true` requires `enable_deployments = true`. Setting Agent Builder without Deployments causes `agent_builder requires deployments` error.

---

## Deployment Topology Options

### Option A: All Internal (Dev/POC Only)

```
AKS Cluster
  ├── LangSmith pods
  ├── PostgreSQL (in-cluster)
  ├── Redis (in-cluster)
  └── ClickHouse (in-cluster StatefulSet)
```

Set `postgres_source = "in-cluster"`, `redis_source = "in-cluster"`. No managed data stores. Fastest to spin up, lowest cost. **Not production-grade** — no HA, no backups, single points of failure.

### Option B: External Postgres + Redis + Blob, Internal ClickHouse

```
AKS Cluster                 Azure Managed
  ├── LangSmith ──→          Azure Database for PostgreSQL
  ├── ──────────→            Azure Cache for Redis
  ├── ──────────→            Azure Blob Storage
  └── ClickHouse (in-cluster, dev only)
```

The **quick-start production path**. Managed data stores for durability and HA. In-cluster ClickHouse is fine for small teams — single StatefulSet pod, no replication, no backups.

### Option C: All External (Production Recommended)

```
AKS Cluster              Azure / LangChain Managed
  └── LangSmith ──→       Azure Database for PostgreSQL
                    ──→   Azure Cache for Redis
                    ──→   Azure Blob Storage
                    ──→   LangChain Managed ClickHouse
```

External ClickHouse = no stateful workloads in the cluster. Full durability, proper HA. Recommend to any customer with production SLOs.

---

## Dependency Graph (Pass 1)

```
[networking] ──────────────────────────────────────────────────┐
    │                                                           │
    ├──→ [k8s-cluster] ──→ [k8s-bootstrap]                    │
    │         │                                                 │
    │         └──→ [storage] (uses cluster WI managed identity)│
    │                                                           │
    ├──→ [postgres]  (uses networking.postgres_subnet_id)       │
    ├──→ [redis]     (uses networking.redis_subnet_id)          │
    └──→ [keyvault]  (standalone, for all secrets)              │
                                                                │
root module: WI RBAC assignments (storage + cluster outputs)   │
root module: Key Vault access policies (cluster + identities)  │
```

**Critical path:** networking → k8s-cluster → (postgres in parallel, redis in parallel, keyvault in parallel, storage in parallel) → k8s-bootstrap.

AKS is the longest-running step (~12-15 min). Total Pass 1: ~15–20 min.

---

## Key Customer Talking Points

### "How is this secure?"

- No pods have public IPs. Only the ingress LoadBalancer is internet-facing.
- No static storage keys — Workload Identity gives pods short-lived tokens (1-hour TTL).
- PostgreSQL and Redis are on private endpoints — no public exposure, not reachable from outside the VNet.
- Secrets are in Key Vault, not in Helm values or environment variables.
- Optional cert-manager for automated TLS — no manual cert management.

### "What happens if a node dies?"

- AKS distributes pods across multiple nodes.
- Cluster Autoscaler replaces terminated nodes automatically.
- Azure Load Balancer health probes remove unhealthy pods from rotation.
- Single points of failure: PostgreSQL (no HA by default — enable for prod), Redis (single node by default — use Redis Enterprise for HA).

### "Who manages the Kubernetes control plane?"

Microsoft does. AKS is a fully managed control plane — patching, HA, and availability are Microsoft's responsibility. You're responsible for node pools, application workloads, and cluster add-ons.

### "How do we upgrade LangSmith?"

Pass 2 only — update the chart version in `app/terraform.tfvars` (Terraform path) or `deploy.sh` (Helm path), then re-deploy. No Terraform infra changes needed.

### "How do we upgrade Kubernetes?"

Update `kubernetes_version` in `infra/terraform.tfvars`, run `terraform apply -target=module.aks`. AKS does a rolling upgrade of control plane first, then node pools. Nodes are cordoned, drained, and replaced one at a time.

### "Can we use our own VNet?"

Yes. Provide `vnet_id` and subnet IDs directly. The only requirements: AKS subnet must have sufficient CIDR space for pods, PostgreSQL subnet must have `Microsoft.DBforPostgreSQL/flexibleServers` delegation, Redis subnet must allow private endpoints.

### "Can we use our own domain and TLS cert?"

Two options:
1. Set `langsmith_domain = "langsmith.example.com"` + `tls_certificate_source = "letsencrypt"` — cert-manager issues and renews automatically. Customer manages DNS CNAME to the Azure IP.
2. Set `tls_certificate_source = "existing"` with a pre-created K8s TLS secret.

### "What's the cost estimate?"

Rough monthly baseline (East US, pay-as-you-go):

| Component | Cost/month |
|-----------|-----------|
| AKS control plane | Free (AKS control plane is free) |
| 3× Standard_D4s_v3 nodes | ~$450 |
| Azure Database for PostgreSQL (GP_D2s_v3) | ~$130 |
| Azure Cache for Redis (C1 Standard) | ~$55 |
| Azure Blob Storage (varies with data) | ~$5–30 |
| Azure Load Balancer (ingress) | ~$20 |
| Key Vault | ~$5 |
| **Total baseline** | **~$665–700/mo** |

Azure is significantly cheaper than AWS for equivalent workloads (~50% less). Savings levers: Reserved Instances (1-year, 30–40% off), spot node pools for non-stateful workloads, right-sizing with `minimum` or `dev` profile for non-production.

---

## Common Failure Modes

| Symptom | Root Cause | Fix |
|---------|-----------|-----|
| Cert stuck `Pending` | DNS label not set on LB service | `deploy.sh` should set this. If missing: `kubectl annotate svc <svc> -n <ns> service.beta.kubernetes.io/azure-dns-label-name=<label>` |
| `ClusterIssuer letsencrypt-prod not found` | `deploy.sh` didn't create issuer | Re-run `make deploy` or apply the inline ClusterIssuer manifest from `deploy.sh` |
| `CreateContainerConfigError` on Insights | `langsmith-clickhouse` secret missing | Running in-cluster ClickHouse but copied external example. Run `make init-values` to regenerate correct minimal file |
| `enable_agent_builder requires deployments` | `enable_deployments = false` | Set both flags to `true` in `terraform.tfvars`, then `make init-values && make deploy` |
| `make destroy` hangs | Active LoadBalancer with public IP | Run `make uninstall` first. If stuck: `az group delete --name langsmith-rg-<id> --yes --no-wait` |
| `Deployments stuck in DEPLOYING` | `config.deployment.url` empty or wrong TLS flag | Check: `grep -E 'url:\|tlsEnabled' helm/values/langsmith-values-agent-deploys.yaml`. Re-run `make init-values` |
| Blob access denied | WI annotation missing from service account | Verify `serviceAccountAnnotations` in `values-overrides.yaml` includes the WI client-id |
| PostgreSQL connection refused | Delegated subnet missing | Check subnet has `Microsoft.DBforPostgreSQL/flexibleServers` delegation. Cannot be added after subnet is in use |
| `helm release in pending-upgrade state` | Previous deploy was interrupted | `deploy.sh` auto-rolls this back. Or: `helm rollback langsmith -n langsmith` |

---

## File Reference

```
terraform/azure/
├── Makefile                            All commands — start here
│
├── infra/
│   ├── main.tf                         Root module: module wiring, WI RBAC, KV policies
│   ├── locals.tf                       Naming convention (resource names, tags)
│   ├── variables.tf                    All input variables with descriptions
│   ├── outputs.tf                      Outputs consumed by Helm scripts and app/
│   ├── terraform.tfvars.example        Starter values — copy to terraform.tfvars
│   ├── terraform.tfvars.production     Production-tuned example
│   ├── secrets.auto.tfvars             Generated by setup-env.sh — gitignored
│   └── modules/
│       ├── networking/                 VNet, subnets, private DNS zones
│       ├── k8s-cluster/                AKS, node pools, OIDC, ingress controllers, WI
│       ├── postgres/                   Azure Database for PostgreSQL Flexible Server
│       ├── redis/                      Azure Cache for Redis + private endpoint
│       ├── storage/                    Azure Blob Storage account + container + RBAC
│       ├── keyvault/                   Azure Key Vault + access policies
│       └── k8s-bootstrap/              Namespace, K8s secrets, service accounts
│
├── app/                                Pass 2 (Terraform Helm path)
│   ├── main.tf                         Manages K8s secret + SA + helm_release
│   ├── variables.tf                    Variables fed by infra.auto.tfvars.json
│   ├── locals.tf                       Hostname resolution, values chain
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   ├── backend.tf.example
│   └── scripts/
│       └── pull-infra-outputs.sh       Reads infra/ outputs → app/infra.auto.tfvars.json
│
├── helm/
│   ├── scripts/
│   │   ├── deploy.sh                   Main Helm deploy — values chain + DNS annotation + ClusterIssuer
│   │   ├── init-values.sh              TF outputs → values-overrides.yaml + addon files
│   │   ├── get-kubeconfig.sh           az aks get-credentials wrapper
│   │   ├── preflight-check.sh          Tools + cluster + helm repo check
│   │   └── uninstall.sh                Clean Helm uninstall + LGP CRD cleanup
│   └── values/
│       ├── langsmith-values.yaml       Azure base config (NGINX, Blob WI, no Istio)
│       ├── values-overrides.yaml       Live file — gitignored, generated by init-values.sh
│       └── examples/
│           ├── SIZING.md               Sizing profiles reference (minimum/dev/production/production-large)
│           ├── langsmith-values-sizing-minimum.yaml
│           ├── langsmith-values-sizing-dev.yaml
│           ├── langsmith-values-sizing-production.yaml
│           ├── langsmith-values-sizing-production-large.yaml
│           ├── langsmith-values-agent-deploys.yaml
│           ├── langsmith-values-agent-builder.yaml
│           ├── langsmith-values-insights.yaml
│           └── langsmith-values-polly.yaml
│
└── infra/scripts/
    ├── _common.sh                      Shared helpers: _parse_tfvar, _tfvar_is_true, colors
    ├── setup-env.sh                    Bootstrap secrets → secrets.auto.tfvars (read-only against KV)
    ├── preflight.sh                    Pre-flight checks (az, auth, providers, RBAC)
    ├── create-k8s-secrets.sh           Key Vault → langsmith-config-secret
    ├── status.sh                       9-section health check
    └── clean.sh                        Remove all generated/sensitive local files
```

---

*Last updated: 2026-03-28 — covers current `feat/dz-local` branch state*
