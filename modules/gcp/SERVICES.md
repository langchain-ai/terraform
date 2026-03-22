# LangSmith on GCP — Service Reference

What each pod does, what it needs, and when it appears.
GCP-specific: Workload Identity for GCS access, GCS HMAC keys for S3-compatible API,
Secret Manager for optional secret storage (no SSM/ESO required for core secrets).

---

## Pass 2 — Core Services (always running)

### `langsmith-frontend`
- **What**: React SPA — the LangSmith web UI
- **Exposes**: Port 3000, served behind Envoy Gateway
- **Depends on**: `backend`, `platform-backend`
- **HPA**: 1–10 replicas (CPU ≥ 50%, Mem ≥ 80%)

### `langsmith-backend`
- **What**: Main API server — traces, runs, projects, API keys, feedback
- **Exposes**: Port 1984
- **Depends on**: Postgres, Redis, ClickHouse, GCS
- **HPA**: 3–10 replicas · **Workload Identity** (GCS access via `iam.gke.io/gcp-service-account` annotation)

### `langsmith-platform-backend`
- **What**: Org/user management, auth, billing, settings
- **Exposes**: Port 1986
- **Depends on**: Postgres, Redis, GCS
- **HPA**: 1–10 replicas · **Workload Identity** (GCS access)
- **Notes**: Handles identity plane, not data plane. Separate from `backend`.

### `langsmith-playground`
- **What**: LLM Playground — interactive prompt testing UI
- **Exposes**: Port 3001
- **Depends on**: `backend`
- **HPA**: 1–10 replicas

### `langsmith-queue`
- **What**: Trace ingestion worker — dequeues from Redis, writes to ClickHouse + GCS
- **Depends on**: Redis, ClickHouse, GCS
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **Workload Identity**

### `langsmith-ingest-queue`
- **What**: Dedicated high-throughput ingestion worker — parallel to `queue`, handles burst traffic
- **Depends on**: Redis, GCS
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **Workload Identity**

### `langsmith-ace-backend`
- **What**: Async compute engine — dataset runs, evaluations, background jobs
- **Depends on**: Postgres, Redis
- **HPA**: 1–5 replicas

### `langsmith-clickhouse`
- **What**: Columnar database — trace spans, run metadata, eval results
- **Type**: StatefulSet · 500Gi PVC (premium-rwo) · requires memory-optimized node
- **Notes**: In-cluster is for dev/POC only (single pod, no replication, no backups). For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

### One-time Jobs (Pass 2)
| Job | Purpose |
|-----|---------|
| `langsmith-backend-migrations` | PostgreSQL schema migrations |
| `langsmith-backend-ch-migrations` | ClickHouse schema migrations |
| `langsmith-backend-auth-bootstrap` | Initial org/admin account creation |

---

## GCP Managed Services (Pass 1, external mode)

### Cloud SQL PostgreSQL
- **What**: Relational DB — orgs, users, projects, API keys, settings
- **Default size**: `db-custom-2-8192` (2 vCPU, 8 GB) · private IP only · port 5432
- **HA**: REGIONAL availability (automatic failover to standby replica)
- **Secret flow**: Terraform writes connection URL directly to `langsmith-postgres` K8s Secret in k8s-bootstrap module

### Memorystore Redis
- **What**: Queue + cache — trace ingestion queue, pub/sub, short-lived cache
- **Default size**: 5 GB · STANDARD_HA tier · private IP only · port 6379
- **Secret flow**: Terraform writes connection URL directly to `langsmith-redis` K8s Secret in k8s-bootstrap module
- **Note**: No auth token required — access is controlled by VPC private IP only

### Cloud Storage Bucket
- **What**: Object store for trace payloads — large inputs/outputs, attachments
- **Access**: Via S3-compatible API (`apiURL: https://storage.googleapis.com`, `engine: S3`)
- **Auth options**:
  - **HMAC keys** (required for S3-compatible API): create in GCP Console → Cloud Storage → Settings → Interoperability
  - **Workload Identity** grants `storage.objectAdmin` on the bucket, but the S3-compatible API requires HMAC keys regardless
- **Always required**: Yes — disabling blob causes cluster issues with large payloads
- **Lifecycle**: `ttl_s/` prefix (14 days default) · `ttl_l/` prefix (400 days default)

### Secret Manager (optional module)
- **What**: Stores Postgres password and generated secrets (langsmith secret key, JWT secret)
- **Enabled by**: `enable_secret_manager_module = true` in terraform.tfvars (default: false)
- **Note**: Core secrets (postgres/redis) are always stored in K8s Secrets by k8s-bootstrap regardless of this module. Secret Manager provides an additional durable store for secrets that must survive cluster recreation.

---

## Pass 3 — LangGraph Platform (Deployments)

### `langsmith-host-backend`
- **What**: LangGraph control plane API — manages deployment lifecycle, serves deployment metadata
- **Depends on**: Postgres, GCS
- **Workload Identity**: Yes (GCS access)

### `langsmith-listener`
- **What**: Watches host-backend for deployment state changes, creates/updates `LangGraphPlatform` CRDs
- **Depends on**: `host-backend`, Redis, GCS
- **Workload Identity**: Yes (GCS access)

### `langsmith-operator`
- **What**: Kubernetes operator — reconciles `LangGraphPlatform` CRDs, creates/deletes K8s Deployments for each LangGraph agent
- **Depends on**: Kubernetes API (RBAC to manage Deployments/Services)

### Dynamic agent Deployments (operator-managed)
- Each LangGraph deployment the user creates in the UI results in a K8s Deployment in the `langsmith` namespace
- Pod template comes from `operator.templates.deployment` in Helm values
- Pods run as `langsmith-ksa` — that ServiceAccount must carry the `iam.gke.io/gcp-service-account` annotation

---

## Cluster Infrastructure (Pass 1 — Terraform-provisioned)

### Envoy Gateway
- **What**: Gateway API implementation — routes HTTP/HTTPS traffic to LangSmith services
- **Namespace**: `envoy-gateway-system`
- **Installed by**: Terraform `ingress` module (`install_ingress = true`, default)
- **Note**: The `Gateway` resource is managed by Terraform; the `HTTPRoute` is managed by Helm. Do not delete the Gateway resource manually — it takes the external IP with it.

### KEDA
- **What**: Kubernetes Event-driven Autoscaling — scales `queue` and `ingest-queue` based on Redis queue depth
- **Deployed by**: Terraform `k8s-bootstrap` module when `enable_langsmith_deployment = true`
- **Required for**: Pass 3+ (LangGraph Platform prerequisite)

### cert-manager
- **What**: Automates TLS certificate issuance and renewal
- **Deployed by**: Terraform `k8s-bootstrap` module when `tls_certificate_source = "letsencrypt"` or `install_cert_manager = true`
- **ClusterIssuers**: `letsencrypt-staging`, `letsencrypt-prod` (only active when `tls_certificate_source = "letsencrypt"`)

### External Secrets Operator (ESO)
- **What**: Can sync Secret Manager secrets into Kubernetes secrets
- **Deployed by**: Terraform `k8s-bootstrap` module
- **Note**: Unlike AWS, core LangSmith secrets (postgres/redis) are written directly to K8s Secrets by Terraform — ESO is available for custom secret workflows but not required for a base deployment.

---

## Workload Identity Summary

| Component | Annotation | Permissions |
|-----------|-----------|-------------|
| `langsmith-backend` | `iam.gke.io/gcp-service-account: <gsa>` | GCS `storage.objectAdmin` on LangSmith bucket |
| `langsmith-platform-backend` | Same | GCS `storage.objectAdmin` |
| `langsmith-queue` | Same | GCS `storage.objectAdmin` |
| `langsmith-ingest-queue` | Same | GCS `storage.objectAdmin` |
| `langsmith-host-backend` | Same | GCS `storage.objectAdmin` |
| `langsmith-listener` | Same | GCS `storage.objectAdmin` |
| `langsmith-ksa` (operator pods) | Same | GCS `storage.objectAdmin` |

GSA is defined by the `iam` module and output as `workload_identity_annotation`.
`init-values.sh` writes these annotations into `values-overrides.yaml` automatically.
