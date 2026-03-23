# LangSmith on GCP — Architecture

---

## Platform Layers

LangSmith is deployed in three passes. Each pass adds a capability layer on top of the previous one. All layers share the same GKE cluster and namespace.

| Pass | Layer | What's added |
|------|-------|-------------|
| 1 | GCP Infrastructure | VPC, GKE, Cloud SQL, Memorystore, GCS, K8s bootstrap, cert-manager, KEDA, Envoy Gateway |
| 2 | LangSmith Base | frontend, backend, platform-backend, queue, ace-backend, clickhouse, playground |
| 3 | LangSmith Deployments | host-backend, listener, operator + per-deployment pods |

---

## Module Descriptions

| Module | Path | Purpose |
|--------|------|---------|
| networking | `modules/networking/` | VPC, subnet with secondary ranges, Cloud Router, Cloud NAT, private service connection for Cloud SQL and Memorystore |
| k8s-cluster | `modules/k8s-cluster/` | GKE Standard or Autopilot cluster, node pool with autoscaling, Workload Identity enabled |
| postgres | `modules/postgres/` | Cloud SQL PostgreSQL instance, HA standby replica, private IP, deletion protection |
| redis | `modules/redis/` | Memorystore Redis Standard HA tier, private IP within VPC |
| storage | `modules/storage/` | GCS bucket with lifecycle rules for `ttl_s/` (14 days) and `ttl_l/` (400 days) prefixes |
| k8s-bootstrap | `modules/k8s-bootstrap/` | `langsmith` namespace, K8s secrets for Postgres and Redis URLs, cert-manager Helm release, KEDA Helm release |
| ingress | `modules/ingress/` | Envoy Gateway Helm release, GatewayClass, HTTPRoute, optional HTTPS Gateway listener |
| iam | `modules/iam/` | GCP service accounts and Workload Identity IAM bindings for GCS access (wired by default) |
| dns | `modules/dns/` | Cloud DNS managed zone and managed cert (optional via `enable_dns_module`) |
| secrets | `modules/secrets/` | Secret Manager secret bundle (optional via `enable_secret_manager_module`) |

---

## Deployment Tiers

### Light Deploy (All In-Cluster)

```
VPC
└── subnet (10.0.0.0/20 — GKE nodes)
    └── No Cloud SQL / Memorystore — chart pods handle both

GKE Cluster
├── langsmith namespace
│   ├── frontend / backend / platform-backend / queue / ace-backend
│   ├── clickhouse   (in-cluster)
│   ├── postgres     (in-cluster)
│   └── redis        (in-cluster)
├── cert-manager
├── keda
└── envoy-gateway-system

GCS Bucket  (trace payloads — always external)
```

Set in `terraform.tfvars`:
```hcl
postgres_source   = "in-cluster"
redis_source      = "in-cluster"
clickhouse_source = "in-cluster"
```

### Production (External Managed Services)

```
VPC
├── subnet (10.0.0.0/20 — GKE nodes, pods, services)
│   └── Secondary ranges: pods 10.4.0.0/14, services 10.8.0.0/20
└── Private service connection (VPC peering to Google managed network)
    ├── Cloud SQL PostgreSQL   (private IP, HA regional standby)
    └── Memorystore Redis      (private IP, Standard HA tier)

GKE Cluster
├── langsmith namespace
│   ├── frontend / backend / platform-backend / queue / ace-backend
│   └── clickhouse (in-cluster)
├── cert-manager
├── keda
└── envoy-gateway-system

GCS Bucket  (Workload Identity — no static HMAC keys for GCS SA auth)
```

---

## Network Topology

| Range | CIDR | Used by |
|-------|------|---------|
| Subnet | `10.0.0.0/20` | GKE nodes |
| Pods | `10.4.0.0/14` | GKE pod IPs (secondary range) |
| Services | `10.8.0.0/20` | GKE ClusterIP services (secondary range) |
| Private service connection | `/16` allocated by Google | Cloud SQL, Memorystore private IPs |

Cloud SQL and Memorystore are accessed exclusively via private IP. No public endpoints are created for database or cache resources. A **private service connection** (VPC peering to Google's managed network) is established by the networking module whenever `postgres_source = "external"` or `redis_source = "external"`.

---

## Workload Identity

GKE pods access GCS using **Workload Identity** — the Kubernetes service account is bound to a GCP service account via an IAM binding. No static credentials are stored in K8s secrets or environment variables.

```
GKE pod
  └── Kubernetes ServiceAccount (annotated with iam.gke.io/gcp-service-account)
        └── IAM binding: roles/iam.workloadIdentityUser
              └── GCP Service Account
                    └── roles/storage.objectAdmin on the GCS bucket
```

For GCS access using HMAC keys (S3-compatible API), create a service account key in GCP Console under Storage > Settings > Interoperability and pass the access key and secret to the Helm command via `config.blobStorage.accessKey` and `config.blobStorage.accessKeySecret`.

---

## Secret Manager Integration

The `secrets` module (optional) stores Postgres and Redis credentials in GCP Secret Manager. These can be referenced in the `k8s-bootstrap` module to populate Kubernetes secrets without embedding plaintext values in Terraform state.

Standard flow without Secret Manager:
```
terraform.tfvars  →  terraform apply  →  kubernetes_secret (postgres, redis)
```

Flow with Secret Manager:
```
terraform.tfvars  →  terraform apply  →  Secret Manager secrets
                                           → ESO (External Secrets Operator)
                                             → kubernetes_secret (langsmith namespace)
```

---

## Terraform Module Graph

```
google_project_service (APIs enabled)
  └── module.networking
        ├── module.gke_cluster
        │     └── null_resource.wait_for_cluster
        │           ├── module.cloudsql      (count = postgres_source == "external")
        │           ├── module.redis         (count = redis_source    == "external")
        │           ├── module.storage
        │           ├── module.iam           (count = enable_gcp_iam_module)
        │           ├── module.secrets       (count = enable_secret_manager_module)
        │           ├── module.dns           (count = enable_dns_module)
        │           ├── module.k8s_bootstrap
        │           └── module.ingress       (count = install_ingress)
        └── (private_service_connection when external services)
```

LangSmith itself is **not** deployed by Terraform — it is deployed in Pass 2 via `helm upgrade --install`.

---

## Traffic Flow

```
Internet (HTTPS :443)
  ↓
Envoy Gateway  (envoy-gateway-system namespace, external LoadBalancer IP)
  │  TLS terminated — cert-manager + Let's Encrypt or existing certificate
  │
  ├── /                     → frontend:80
  ├── /api/*                → backend:1984
  └── /api/v1/deployments/* → host-backend:1985  (Pass 3)

Internal traffic (private IPs, never leaving VPC):
  backend       → Cloud SQL:5432        via private IP
  backend       → Memorystore:6379      via private IP
  backend       → GCS                   via Workload Identity + HMAC keys
  host-backend  → K8s API               reads deployment pod status
  listener      → K8s API               reconciles Deployment CRDs
  operator      → K8s API               creates/manages deployment pods
```

---

## Component → Storage Mapping

| Component | PostgreSQL | Redis | ClickHouse | GCS |
|-----------|-----------|-------|-----------|-----|
| `backend` | org config, run metadata | ingestion queue | — | trace objects |
| `platform-backend` | — | — | — | blob routing |
| `queue` | — | pops jobs | — | writes trace blobs |
| `clickhouse` | — | — | trace search index | — |
| `host-backend` | deployment lifecycle state | — | — | — |

---

## Verification Commands

```bash
# Cluster connectivity
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>
kubectl cluster-info
kubectl get nodes -o wide

# All LangSmith pods
kubectl get pods -n langsmith

# Envoy Gateway
kubectl get pods -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system

# cert-manager
kubectl get pods -n cert-manager
kubectl get certificate -n langsmith

# KEDA (Pass 3)
kubectl get pods -n keda

# Cloud SQL connectivity test
kubectl run psql-test --rm -it --image=postgres:15 -n langsmith -- \
  psql "postgresql://langsmith:<password>@<cloud-sql-private-ip>:5432/langsmith" -c "SELECT version();"

# Memorystore connectivity test
kubectl run redis-test --rm -it --image=redis:7 -n langsmith -- \
  redis-cli -h <redis-private-ip> ping

# GCS connectivity test
kubectl run gcs-test --rm -it --image=google/cloud-sdk -n langsmith -- \
  gsutil ls gs://<bucket-name>
```
