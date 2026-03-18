# LangSmith on AWS — Service Reference

What each pod does, what it needs, and when it appears.
AWS-specific: IRSA for cloud access, SSM Parameter Store → ESO → `langsmith-config` K8s Secret.

---

## Pass 2 — Core Services (always running)

### `langsmith-frontend`
- **What**: React SPA — the LangSmith web UI
- **Exposes**: Port 3000, served behind ALB
- **Depends on**: `backend`, `platform-backend`
- **HPA**: 1–10 replicas (CPU ≥ 50%, Mem ≥ 80%)

### `langsmith-backend`
- **What**: Main API server — traces, runs, projects, API keys, feedback
- **Exposes**: Port 1984
- **Depends on**: Postgres, Redis, ClickHouse, S3
- **HPA**: 3–10 replicas · **IRSA** (S3 access)

### `langsmith-platform-backend`
- **What**: Org/user management, auth, billing, settings
- **Exposes**: Port 1986
- **Depends on**: Postgres, Redis, S3
- **HPA**: 1–10 replicas · **IRSA** (S3 access)
- **Notes**: Handles identity plane, not data plane. Separate from `backend`.

### `langsmith-playground`
- **What**: LLM Playground — interactive prompt testing UI
- **Exposes**: Port 3001
- **Depends on**: `backend`
- **HPA**: 1–10 replicas

### `langsmith-queue`
- **What**: Trace ingestion worker — dequeues from Redis, writes to ClickHouse + S3
- **Depends on**: Redis, ClickHouse, S3
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **IRSA**

### `langsmith-ingest-queue`
- **What**: Dedicated high-throughput ingestion worker — parallel to `queue`, handles burst traffic
- **Depends on**: Redis, S3
- **HPA**: 3–10 replicas + KEDA (Redis queue depth) · **IRSA**

### `langsmith-ace-backend`
- **What**: Async compute engine — dataset runs, evaluations, background jobs
- **Depends on**: Postgres, Redis
- **HPA**: 1–5 replicas

### `langsmith-clickhouse`
- **What**: Columnar database — trace spans, run metadata, eval results
- **Type**: StatefulSet · 500Gi PVC (EBS GP3) · requires memory-optimized node
- **Notes**: In-cluster is for dev/POC only (single pod, no replication, no backups). For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

### One-time Jobs (Pass 2)
| Job | Purpose |
|-----|---------|
| `langsmith-backend-migrations` | PostgreSQL schema migrations |
| `langsmith-backend-ch-migrations` | ClickHouse schema migrations |
| `langsmith-backend-auth-bootstrap` | Initial org/admin account creation — reads `initial_org_admin_password` from `langsmith-config` |

---

## AWS Managed Services (Pass 1, external mode)

### RDS PostgreSQL
- **What**: Relational DB — orgs, users, projects, API keys, settings
- **Default size**: `db.t3.large` · private subnets only · port 5432
- **Secret flow**: SSM `/langsmith/{base_name}/postgres-password` → ESO → `langsmith-config`

### ElastiCache Redis
- **What**: Queue + cache — trace ingestion queue, pub/sub, short-lived cache
- **Default size**: `cache.m5.large` · private subnets only · TLS port 6379
- **Secret flow**: SSM `/langsmith/{base_name}/redis-auth-token` → ESO → `langsmith-config`

### S3 Bucket
- **What**: Object store for trace payloads — large inputs/outputs, attachments
- **Access**: IRSA (no static keys) via `langsmith_irsa_role` · VPC Gateway Endpoint (no public internet)
- **Always required**: Yes — disabling blob causes cluster issues with large payloads
- **Prefixes**: `ttl_s/` (short TTL) · `ttl_l/` (long TTL)

### SSM Parameter Store
- **What**: Centralized secret store — holds all LangSmith secrets
- **Secret flow**: `source setup-env.sh` writes → SSM → ESO ClusterSecretStore reads → `langsmith-config` K8s Secret → Helm `config.existingSecretName`
- **Prefix**: `/langsmith/{name_prefix}-{environment}/`

---

## Pass 3 — LangGraph Platform (Deployments)

### `langsmith-host-backend`
- **What**: LangGraph control plane API — manages deployment lifecycle, serves deployment metadata
- **Depends on**: Postgres, S3
- **IRSA**: Yes (S3 access)

### `langsmith-listener`
- **What**: Watches host-backend for deployment state changes, creates/updates `LangGraphPlatform` CRDs
- **Depends on**: `host-backend`, Redis, S3
- **IRSA**: Yes (S3 access)

### `langsmith-operator`
- **What**: Kubernetes operator — reconciles `LangGraphPlatform` CRDs, creates/deletes K8s Deployments for each LangGraph agent
- **Depends on**: Kubernetes API (RBAC to manage Deployments/Services)

### Dynamic agent Deployments (operator-managed)
- Each LangGraph deployment the user creates in the UI results in a K8s Deployment in the `langsmith` namespace
- Pod template comes from `operator.templates.deployment` in Helm values

---

## Cluster Infrastructure (Pass 1 — Terraform-provisioned)

### `aws-load-balancer-controller`
- **What**: Provisions and manages the AWS ALB based on Kubernetes `Ingress` objects
- **Namespace**: `kube-system`
- **IRSA**: Yes — must have ALB/ELB permissions
- **Note**: Deleting the `Ingress` object deprovisions the ALB; a new hostname is assigned on recreate — breaks DNS records and OIDC redirect URIs

### `cluster-autoscaler`
- **What**: Scales EC2 node groups up/down based on pod scheduling pressure
- **Namespace**: `kube-system`
- **IRSA**: Yes — EC2 Auto Scaling permissions

### `ebs-csi-driver`
- **What**: Provisions EBS volumes for PersistentVolumeClaims (used by ClickHouse)
- **Namespace**: `kube-system`
- **IRSA**: Yes — EC2 EBS permissions

### KEDA
- **What**: Kubernetes Event-driven Autoscaling — scales `queue` and `ingest-queue` based on Redis queue depth
- **Deployed by**: Terraform `k8s-bootstrap` module
- **Required for**: Pass 3+ (LangGraph Platform prerequisite)

### cert-manager
- **What**: Automates TLS certificate issuance and renewal
- **Deployed by**: Terraform `k8s-bootstrap` module
- **ClusterIssuers**: `letsencrypt-staging`, `letsencrypt-prod` (only active when `tls_certificate_source = "letsencrypt"`)
- **Note**: When using ACM (`tls_certificate_source = "acm"`), cert-manager is installed but not used for the ALB cert

### External Secrets Operator (ESO)
- **What**: Syncs SSM Parameter Store secrets into Kubernetes secrets
- **Deployed by**: Terraform `k8s-bootstrap` module
- **IRSA**: Yes — SSM read permissions (separate `eso` role, not the LangSmith IRSA role)
- **Objects**: `ClusterSecretStore` + `ExternalSecret` applied in `deploy.sh` (after ESO CRDs exist)

---

## IRSA Role Summary

| Role | Defined in | Used by | Permissions |
|------|-----------|---------|-------------|
| `langsmith_irsa_role` | `modules/eks` | `backend`, `platform-backend`, `queue`, `ingest-queue` | S3 get/put/delete on LangSmith bucket |
| `aws_iam_role.eso` | `aws/infra/main.tf` | ESO controller pod | SSM `GetParameter`, `GetParameters` on `/langsmith/*` |
