# LangSmith Azure — Service Reference

What each pod does, what it needs, and when it appears.
All passes verified during production deploy (external Postgres + Redis).

---

## Pass 2 — Core Services (always running)

### `langsmith-frontend`
- **What**: React SPA — the LangSmith web UI
- **Exposes**: Port 3000, served via NGINX ingress
- **Depends on**: `backend`, `platform-backend`
- **HPA**: 1–10 replicas (CPU ≥ 50%, Mem ≥ 80%)

### `langsmith-backend`
- **What**: Main API server — traces, runs, projects, API keys, feedback
- **Exposes**: Port 1984
- **Depends on**: Postgres, Redis, ClickHouse, Blob Storage
- **HPA**: 3–10 replicas · **WI** (Blob Storage access)

### `langsmith-platform-backend`
- **What**: Org/user management, auth, billing, settings
- **Exposes**: Port 1986
- **Depends on**: Postgres, Redis, Blob Storage
- **HPA**: 1–10 replicas · **WI** (Blob Storage access)
- **Notes**: Handles identity plane, not data plane. Separate from `backend`.

### `langsmith-playground`
- **What**: LLM Playground — interactive prompt testing UI
- **Exposes**: Port 3001
- **Depends on**: `backend`
- **HPA**: 1–10 replicas

### `langsmith-queue`
- **What**: Trace ingestion worker — dequeues from Redis, writes to ClickHouse + Blob Storage
- **Depends on**: Redis, ClickHouse, Blob Storage
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **WI**

### `langsmith-ingest-queue`
- **What**: Dedicated high-throughput ingestion worker — parallel to `queue`, handles burst traffic
- **Depends on**: Redis, Blob Storage
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **WI**
- **Enabled**: Pass 2+ with external Redis. Disabled in demo/light mode.

### `langsmith-ace-backend`
- **What**: Async compute engine — dataset runs, evaluations, background jobs
- **Depends on**: Postgres, Redis
- **HPA**: 1–5 replicas

### `langsmith-clickhouse`
- **What**: Columnar database — trace spans, run metadata, eval results
- **Type**: StatefulSet · 500Gi PVC · large node pool (requires 15Gi RAM)
- **Notes**: Always in-cluster. External option requires LangChain-managed ClickHouse.

### One-time Jobs (Pass 2)
| Job | Purpose |
|-----|---------|
| `langsmith-backend-migrations` | PostgreSQL schema migrations |
| `langsmith-backend-ch-migrations` | ClickHouse schema migrations |
| `langsmith-backend-auth-bootstrap` | Initial org/admin account creation — reads `initial_org_admin_password` from `langsmith-config-secret` |

---

## Azure Managed Services (Pass 2, external mode)

### Azure DB for PostgreSQL Flexible Server
- **What**: Relational DB — orgs, users, projects, API keys, settings
- **Access**: Private VNet only (subnet-postgres) · SSL port 5432
- **Secret**: `langsmith-postgres-secret` — created by Terraform k8s-bootstrap module

### Azure Cache for Redis Premium
- **What**: Queue + cache — trace ingestion queue, pub/sub, short-lived cache
- **Access**: Private VNet only (subnet-redis) · TLS port 6380
- **Secret**: `langsmith-redis-secret` — created by Terraform k8s-bootstrap module

### Azure Blob Storage
- **What**: Object store for trace payloads — large inputs/outputs, attachments
- **Access**: Workload Identity (no static keys) via `k8s-app-identity` Managed Identity
- **Always required**: Yes — disabling blob causes cluster issues with large payloads
- **Prefixes**: `ttl_s/` (14-day TTL) · `ttl_l/` (400-day TTL)

### Azure Key Vault
- **What**: Centralized secret store — holds all LangSmith secrets
- **Secret flow**: Pass 2c — `az keyvault secret show` → `kubectl create secret generic langsmith-config-secret`

---

## Pass 3 — LangGraph Platform (Deployments)

### `langsmith-host-backend`
- **What**: LangGraph control plane API — manages deployment lifecycle, serves deployment metadata
- **Depends on**: Postgres, Blob Storage
- **WI**: Yes (Blob Storage access)

### `langsmith-listener`
- **What**: Watches host-backend for deployment state changes, creates/updates `LangGraphPlatform` CRDs
- **Depends on**: `host-backend`, Redis, Blob Storage
- **WI**: Yes (Blob Storage access)

### `langsmith-operator`
- **What**: Kubernetes operator — reconciles `LangGraphPlatform` CRDs, creates/deletes K8s Deployments for each LangGraph agent
- **Azure-specific**: Deployment template injects `azure.workload.identity/use: "true"` + `langsmith-ksa` ServiceAccount so every agent pod accesses Blob Storage via Workload Identity
- **Depends on**: Kubernetes API (RBAC to manage Deployments/Services)

### Dynamic agent Deployments (operator-managed)
- Each LangGraph deployment the user creates in the UI results in a K8s Deployment in the `langsmith` namespace
- Pod template comes from `operator.templates.deployment` in values — customised for Azure WI

---

## Pass 4 — Agent Builder

### `langsmith-agent-bootstrap` (Job)
- **What**: One-time Job that registers the bundled Agent Builder agent via the operator on first enable
- **Runs**: Once on `helm upgrade` when `backend.agentBootstrap.enabled: true` — then Completed
- **Effect**: Triggers operator to create the `agent-builder-<hash>` dynamic deployment (4 pods)

### `langsmith-agent-builder-tool-server`
- **What**: MCP (Model Context Protocol) tool server — executes tools called by the Agent Builder agent
- **Depends on**: `backend`, Blob Storage
- **WI**: Yes

### `langsmith-agent-builder-trigger-server`
- **What**: Webhook + scheduled trigger server — invokes agents on external events or schedule
- **Depends on**: `backend`, Redis
- **WI**: Yes

### Dynamic Agent Builder pods (operator-managed, created by `agentBootstrap` Job)
| Pod | What |
|-----|------|
| `agent-builder-<hash>` | Main Agent Builder agent — handles agent generation and assistants |
| `agent-builder-<hash>-queue` | Queue worker for the agent deployment |
| `agent-builder-<hash>-redis` | Redis sidecar for the agent deployment |
| `lg-<hash>-0` | StatefulSet for the agent deployment |

> `<hash>` = agent deployment ID assigned by the operator (e.g. `4b07f64a340b58ce989b88f2f367a76f`)

---

## Pass 5 — Insights

### Insights / Clio (dynamic)
- **What**: AI-powered analytics — auto-summarizes traces, detects patterns, surfaces anomalies
- **Deployment**: No static pods — Clio deploys lazily as a dynamic LangGraph deployment via the operator on first UI invocation
- **Depends on**: ClickHouse (read-heavy), `backend`, Postgres
- **Encryption key**: Read from `langsmith-config-secret` (`insights_encryption_key`)
- **Warning**: Never change `insights_encryption_key` after first enable — permanently breaks existing insights data

---

## Cluster Infrastructure (Terraform-provisioned)

### cert-manager
- **What**: Automates TLS certificate issuance and renewal via Let's Encrypt ACME HTTP-01
- **Deployed by**: Terraform k8s-bootstrap module
- **ClusterIssuers**: `letsencrypt-staging`, `letsencrypt-prod`

### KEDA
- **What**: Kubernetes Event-driven Autoscaling — scales `queue` and `ingest-queue` based on Redis queue depth
- **Deployed by**: Terraform k8s-bootstrap module
- **Required for**: Pass 3+ (LangGraph Platform prerequisite)

### ingress-nginx
- **What**: NGINX Ingress Controller — routes external HTTPS traffic to frontend and backend
- **Type**: LoadBalancer (Azure Load Balancer assigned public IP)
- **Deployed by**: Terraform k8s-bootstrap module

---

*Updated after full production deploy: Passes 2–5 verified on chart v0.13.23.*
