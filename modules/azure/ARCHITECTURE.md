# LangSmith Azure — Architecture

*Updated as deployment is validated.*

## Live Diagrams

### Production Deploy (External Postgres + Redis)

**[LangSmith Azure — Production Architecture (v0.13.27)](https://app.eraser.io/workspace/oto9FgBOY2s7877578R2)**

![LangSmith Azure Production Architecture](diagrams/production-deploy-architecture.png)

Full topology: all passes (2–4), AKS namespaces, pod names, external managed services, Workload Identity flow, Key Vault, TLS, KEDA, NGINX.

### Pass 5 — Insights (verified)

No new diagram — Pass 5 adds `config.insights.enabled: true` only. Clio deploys lazily as a dynamic LangGraph deployment via the operator on first UI invocation. Pod topology at deploy time is identical to Pass 4.

### Pass 4 — Agent Builder Containers (verified)

**[LangSmith Azure — Pass 4 Platform Containers (v0.13.27)](https://app.eraser.io/workspace/BdnsvoccuOm7wh2dLyKi)**

Adds to Pass 3 — 3 static + 4 dynamic pods:
- `langsmith-agent-builder-tool-server` — MCP tool execution (WI)
- `langsmith-agent-builder-trigger-server` — webhooks + scheduled triggers (WI)
- `langsmith-agent-bootstrap` — one-time Job (Completed), registers bundled Agent Builder agent
- `agent-builder-<hash>` + `queue` + `redis` + `lg-<hash>-0` — operator-managed Agent Builder agent deployment (dynamic)

### Pass 3 — LangGraph Platform Containers (verified)

**[LangSmith Azure — Pass 3 Platform Containers (v0.13.27)](https://app.eraser.io/workspace/6renzZO9DtNdvLuqO0Aa)**

Adds 3 pods to the Pass 2 topology:
- `langsmith-host-backend` — LangGraph control plane API (WI)
- `langsmith-listener` — watches host-backend, creates LangGraphPlatform CRDs (WI)
- `langsmith-operator` — reconciles CRDs, manages per-deployment K8s Deployments
- Dynamic agent Deployments created by operator in the same namespace, using `langsmith-ksa` + WI label

### Pass 2 — Platform Containers (External Postgres + Redis, verified)

**[LangSmith Azure — Pass 2 Platform Containers (v0.13.27)](https://app.eraser.io/workspace/CTA7dtpxBysehdXeYOHu)**

Exact pod topology from `kubectl get pods -n langsmith` after successful Pass 2 deploy:
- 7 Deployments: frontend, backend (×3), platform-backend, playground, ace-backend, queue (×3), ingest-queue (×3)
- 1 StatefulSet: clickhouse (large node pool, 500Gi PVC)
- 3 completed Jobs: backend-migrations, backend-ch-migrations, backend-auth-bootstrap
- External: Azure DB for PostgreSQL (subnet-postgres), Azure Cache for Redis Premium (subnet-redis)
- WI pods (4): backend, platform-backend, queue, ingest-queue

### Light Deploy (All In-Cluster)

**[LangSmith Azure — Light Deploy Architecture (v0.13.27)](https://app.eraser.io/workspace/sQxjXna8084czm2eRPFj)**

![LangSmith Azure Light Deploy Architecture](diagrams/light-deploy-architecture.png)

---

## Deployment Topology

### Phase 1 — Light (all in-cluster)

```
AKS Cluster
├── langsmith namespace
│   ├── frontend
│   ├── backend
│   ├── platform-backend
│   ├── playground
│   ├── queue
│   ├── ace-backend
│   ├── clickhouse (in-cluster pod)
│   ├── postgres   (in-cluster pod)
│   └── redis      (in-cluster pod)
├── ingress-nginx (Azure Load Balancer → NGINX)
└── cert-manager  (Let's Encrypt TLS)

Azure
├── Azure Blob Storage  (trace payloads — always external)
└── Azure Key Vault     (secrets)
```

### Phase 2 — Production (external managed services)

```
AKS Cluster
├── langsmith namespace
│   ├── frontend / backend / platform-backend / playground / queue / ace-backend
│   └── clickhouse (in-cluster)
└── ingress-nginx + cert-manager

Azure Managed Services
├── Azure DB for PostgreSQL Flexible Server (private VNet)
├── Azure Cache for Redis Premium (private VNet)
├── Azure Blob Storage (Workload Identity — no static keys)
└── Azure Key Vault
```

---

## Networking

### Light deploy (`postgres_source = "in-cluster"`, `redis_source = "in-cluster"`)

```
langsmith-vnet<identifier>
└── subnet-0    (AKS nodes only)
    ↳ No Postgres/Redis subnets created — chart-managed pods handle both
```

### Production (`postgres_source = "external"`, `redis_source = "external"`)

```
langsmith-vnet<identifier>
├── subnet-0              (AKS nodes)
├── subnet-postgres       (Azure DB for PostgreSQL Flexible Server)
└── subnet-redis          (Azure Cache for Redis Premium)
```

All subnets are private. Postgres and Redis are accessible only from within the VNet via private DNS resolution. No public endpoints.

---

## Secret Flow

```
Pass 1 — Infrastructure

  ./setup-env.sh   (read-only against Key Vault — never writes to KV directly)
    First run:  prompts for postgres password, license key, admin password
                generates api_key_salt, jwt_secret, Fernet keys
                Key Vault does not exist yet → writes to local dot-files + secrets.auto.tfvars
    Subsequent: Key Vault exists → reads all secrets from KV → writes to secrets.auto.tfvars
                no prompts, no generation, no KV writes
    Output:     secrets.auto.tfvars  (gitignored, chmod 600)
                Terraform picks this up automatically — no shell session coupling

  terraform apply
    Reads:  terraform.tfvars (non-sensitive config)
            secrets.auto.tfvars (sensitive values — sole input for KV secret creation)
    Creates: Azure Key Vault + all secrets stored as KV secrets (Terraform is the sole KV writer)

Pass 2 — Application

  ./setup-env.sh   (re-run on any machine to refresh secrets.auto.tfvars from Key Vault)

  kubectl create secret generic langsmith-config-secret
    Reads:  Key Vault secrets + terraform outputs (postgres/redis URLs, blob account)
    Writes: K8s secrets — langsmith-config-secret, langsmith-postgres-secret,
                          langsmith-redis-secret

  helm upgrade --install langsmith ...
    chart reads config.existingSecretName = "langsmith-config-secret"
    no secrets inline in any YAML file
```

**Key rule:** `secrets.auto.tfvars` is never committed. It is regenerated from Key Vault on any machine by running `./setup-env.sh`. Terraform is the sole writer to Key Vault — `setup-env.sh` only reads from it after the first apply.

---

## Resource Sizing — Medium (External Postgres + Redis)

Based on `helm/charts/langsmith/examples/medium_size.yaml`. Use with `values-overrides-external-dbs.yaml`.

### Application Pods

| Pod | CPU Request | CPU Limit | Memory Request | Memory Limit | HPA Min | HPA Max |
|-----|-------------|-----------|----------------|--------------|---------|---------|
| `langsmith-backend` | 1000m | 2000m | 2000Mi | 4Gi | 3 | 10 |
| `langsmith-platform-backend` | 500m | 1000m | 1Gi | 2Gi | 1 | 10 |
| `langsmith-frontend` | 500m | 1000m | 1Gi | 2Gi | 1 | 10 |
| `langsmith-playground` | 500m | 1000m | 1Gi | 2Gi | 1 | 10 |
| `langsmith-queue` | 1000m | 2000m | 2Gi | 4Gi | 3 | 10 |
| `langsmith-ingest-queue` | 1000m | 2000m | 2Gi | 4Gi | — | — |
| `langsmith-ace-backend` | 500m | 1000m | 1Gi | 2Gi | — | — |

### Data Services

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit | Storage |
|---------|-------------|-----------|----------------|--------------|---------|
| `langsmith-clickhouse` (in-cluster) | 3500m | 8000m | 15Gi | 32Gi | 500Gi PVC |
| Azure DB for PostgreSQL | — | — | — | — | managed |
| Azure Cache for Redis Premium | — | — | — | — | managed |

### Minimum AKS Node Pool Sizing for Medium Config

| Pool | VM Size | vCPU | RAM | Min | Max |
|------|---------|------|-----|-----|-----|
| default | Standard_DS4_v2 | 8 | 28Gi | 3 | 6 |
| large | Standard_DS5_v2 | 16 | 56Gi | 1 | 3 |

> ClickHouse alone requests 15Gi RAM — the `large` node pool (DS5_v2, 16 vCPU / 56Gi) is required to schedule it. The default pool handles all application pods.

---

## Optional Modules

Four optional modules can be enabled by setting variables in `terraform.tfvars`. Each is a count-controlled module — 0 = disabled, 1 = enabled.

| Module | Variable to enable | Use case |
|--------|-------------------|---------|
| `waf` | `enable_waf = true` | Azure Application Gateway + WAF v2. Enterprise perimeter security, Web ACLs, bot protection. |
| `diagnostics` | `enable_diagnostics = true` | Log Analytics workspace + diagnostic settings for AKS, Key Vault, and Blob. Required for production observability and audit logging. |
| `bastion` | `enable_bastion = true` | Azure Bastion (Standard tier). Secure browser-based SSH to node VMs without a public IP or jump box. |
| `dns` | `enable_dns = true` | Azure DNS zone + A record. Use when you own a custom domain and want Azure to manage DNS. |

These modules are independent — enable any combination. The core deployment (Passes 1–5) functions without any of them.

---

## Workload Identity (Blob Storage)

LangSmith pods access Azure Blob Storage without static keys. Azure AD token exchange happens via the AKS OIDC issuer:

```
AKS OIDC issuer
  → Federated credential on Azure Managed Identity (one per K8s ServiceAccount)
  → K8s ServiceAccount annotated with azure.workload.identity/client-id
  → Pod labeled with azure.workload.identity/use: "true"
  → Azure AD issues a short-lived token — no storage keys in any secret or env var
```

**Workload Identity is now centralized in `modules/k8s-cluster/`** (moved from `modules/storage/`). Federated credentials are registered alongside the managed identity and OIDC issuer in the same module, which avoids circular dependencies and makes it easier to add new service accounts.

### Which pods need Workload Identity

Every pod that reads blob storage env vars (`langsmith.commonEnv` in the Helm chart) must have:
1. A federated credential registered in Terraform (`modules/k8s-cluster/main.tf`)
2. The `azure.workload.identity/use: "true"` label on the deployment
3. The `azure.workload.identity/client-id` annotation on the service account

| Pod | Pass | Needs WI |
|-----|------|----------|
| `langsmith-backend` | 2 | yes |
| `langsmith-platform-backend` | 2 | yes |
| `langsmith-queue` | 2 | yes |
| `langsmith-ingest-queue` | 2 | yes |
| `langsmith-host-backend` | 3 | yes |
| `langsmith-listener` | 3 | yes |
| `langsmith-agent-builder-tool-server` | 4 | yes |
| `langsmith-agent-builder-trigger-server` | 4 | yes |
| `langsmith-frontend` | 2 | no |
| `langsmith-playground` | 2 | no |
| `langsmith-ace-backend` | 2 | no |
| `langsmith-clickhouse` | 2 | no |
| `langsmith-operator` | 3 | no |

All federated credentials are registered in `modules/k8s-cluster/main.tf` under `service_accounts_for_workload_identity`. Adding a new pod that accesses blob storage requires adding its service account name to that list and running `terraform apply -target=module.aks`.

### What breaks without it

```
panic: blob-storage health-check failed: get container properties failed:
DefaultAzureCredential: failed to acquire a token.
WorkloadIdentityCredential authentication failed.
  AADSTS700213: No matching federated identity record found for presented assertion subject
```

Pod will panic on startup — the service account has no registered federated credential so Azure AD rejects the token exchange.

---

*Architecture sections filled in as each pass is deployed and verified.*
