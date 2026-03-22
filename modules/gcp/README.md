# LangSmith on GCP — Deployment Guide

Self-hosted LangSmith on Google Kubernetes Engine (GKE), managed with Terraform.

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on GCP. Infrastructure is provisioned in three passes:

| Pass | What | Time |
|------|------|------|
| **Pass 1** | GKE cluster, VPC, Cloud SQL, Memorystore Redis, GCS bucket, K8s bootstrap | ~25–35 min |
| **Pass 2** | LangSmith Helm chart | ~10 min |
| **Pass 3** | LangSmith Deployments (KEDA-based, optional) | ~5 min |

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | Cloud SQL (private IP) | Memorystore (private IP) | [LangChain Managed](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to GCS — never to ClickHouse.
>
> **In-cluster ClickHouse is for dev/POC only.** It runs as a single pod with no replication or backups. For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

---

## Prerequisites

### Required tools

```bash
# Google Cloud SDK (>= 450)
brew install --cask google-cloud-sdk
gcloud version

# Terraform (>= 1.5)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version
```

### Required GCP APIs

Terraform enables these automatically on first apply. To enable manually:

```bash
gcloud services enable \
  container.googleapis.com \
  sqladmin.googleapis.com \
  redis.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  secretmanager.googleapis.com \
  certificatemanager.googleapis.com \
  servicenetworking.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project <your-project-id>
```

### Required IAM roles

| Role | Purpose |
|------|---------|
| `roles/container.admin` | Create and manage GKE clusters |
| `roles/compute.networkAdmin` | Create VPC, subnets, firewall rules |
| `roles/iam.serviceAccountAdmin` | Create service accounts for Workload Identity |
| `roles/cloudsql.admin` | Create and manage Cloud SQL instances |
| `roles/redis.admin` | Create and manage Memorystore Redis |
| `roles/storage.admin` | Create GCS buckets and lifecycle policies |
| `roles/resourcemanager.projectIamAdmin` | Grant IAM bindings during provisioning |
| `roles/servicenetworking.networksAdmin` | Create private service connections (required for Cloud SQL + Redis) |

### Authenticate

```bash
gcloud auth login
gcloud config set project <your-project-id>
gcloud auth application-default login
```

---

## Repository Layout

```
gcp/
├── Makefile             ← AWS-style workflow aliases (preflight/init/plan/apply/deploy)
├── infra/
│   ├── main.tf             ← Root module — enables APIs, wires sub-modules
│   ├── variables.tf        ← All input variables with defaults
│   ├── locals.tf           ← Naming: {prefix}-{env}-{resource}-{suffix}
│   ├── outputs.tf          ← Cluster, DB, Redis, Storage, Helm command outputs
│   └── modules/
│       ├── networking/     ← VPC, subnet, Cloud Router, Cloud NAT, private service connection
│       ├── k8s-cluster/    ← GKE Standard/Autopilot, node pool, Workload Identity
│       ├── postgres/       ← Cloud SQL PostgreSQL, HA, private IP
│       ├── redis/          ← Memorystore Redis, HA tier, private IP
│       ├── storage/        ← GCS bucket with TTL lifecycle rules (ttl_s/ ttl_l/)
│       ├── k8s-bootstrap/  ← Namespaces, K8s secrets, cert-manager, KEDA
│       ├── ingress/        ← Envoy Gateway (Gateway API), GatewayClass, HTTPRoute
│       ├── iam/            ← Workload Identity service accounts and bindings (wired by default)
│       ├── dns/            ← Cloud DNS managed zone + managed cert (optional via flags)
│       └── secrets/        ← Secret Manager secrets for credentials (optional via flags)
│   └── scripts/
│       └── preflight.sh    ← Pre-Terraform tooling/auth/API checks
└── helm/
    ├── scripts/
    │   ├── deploy.sh             ← Helm deploy automation
    │   ├── generate-secrets.sh   ← Generate API key salt, JWT secret, Fernet keys
    │   ├── get-kubeconfig.sh     ← gcloud get-credentials wrapper
    │   └── preflight-check.sh    ← Pre-deploy validation
    └── values/
        ├── values.yaml                    ← Base Helm values
        └── values-overrides.yaml.example  ← Overlay template
```

---

## Configuration

Copy and populate the variables file:

```bash
cd gcp/infra
cp terraform.tfvars.example terraform.tfvars
```

Minimum required variables:

```hcl
# Required
project_id            = "<your-gcp-project-id>"
name_prefix           = "ls"
environment           = "prod"
langsmith_license_key = "<your-license-key>"
langsmith_domain      = "langsmith.<your-domain>"

# Region / zone
region = "us-west2"
zone   = "us-west2-a"

# PostgreSQL (required when postgres_source = "external")
postgres_source   = "external"
postgres_password = "<strong-password>"   # or: export TF_VAR_postgres_password=...

# Redis
redis_source = "external"

# ClickHouse (in-cluster is default)
clickhouse_source = "in-cluster"

# TLS
tls_certificate_source = "letsencrypt"
letsencrypt_email      = "<ops@your-domain>"

# LangSmith Deployments (Pass 3)
enable_langsmith_deployment = true
```

### Terraform state backend (recommended for production)

Uncomment the backend block in `gcp/infra/main.tf`:

```hcl
backend "gcs" {
  bucket = "<your-terraform-state-bucket>"
  prefix = "langsmith/state"
}
```

---

## Pass 1 — Infrastructure

Provisions: VPC, GKE cluster, Cloud SQL PostgreSQL, Memorystore Redis, GCS bucket, K8s bootstrap (namespaces, K8s secrets, cert-manager, KEDA).

```bash
# Recommended AWS-style flow
cd gcp
make preflight
make init
make plan
make apply

# Equivalent direct Terraform flow
cd gcp/infra

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

> **Duration:** ~25–35 minutes. GKE creation: 10–15 min. Cloud SQL with HA: additional 10 min. Do not interrupt.

### After apply — get cluster credentials

```bash
cd ../helm/scripts
./get-kubeconfig.sh

kubectl get nodes
kubectl get ns
```

### Verify bootstrap components

```bash
kubectl get pods -n cert-manager
kubectl get pods -n keda
kubectl get secrets -n langsmith
```

---

## Pass 2 — LangSmith Helm Deploy

Use the scripted flow (includes preflight + kubeconfig refresh):

```bash
cd gcp/helm/scripts
./deploy.sh
```

Or run manually — generate secrets first:

```bash
export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export INSIGHTS_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export ADMIN_EMAIL="admin@example.com"
export ADMIN_PASSWORD="<strong-password>"

# GCS HMAC credentials (create in GCP Console: Storage > Settings > Interoperability)
export GCS_ACCESS_KEY="<your-hmac-access-key>"
export GCS_ACCESS_SECRET="<your-hmac-secret>"
```

```bash
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith \
  --create-namespace \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.langsmithLicenseKey="<your-license-key>" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="<your-langsmith-domain>" \
  --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
  --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
  --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
  --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
  --set config.blobStorage.bucketName="$(terraform output -raw storage_bucket_name)" \
  --set config.blobStorage.accessKey="$GCS_ACCESS_KEY" \
  --set config.blobStorage.accessKeySecret="$GCS_ACCESS_SECRET" \
  --set gateway.enabled=true \
  --set ingress.enabled=false \
  --wait --timeout 15m
```

### Verify and configure DNS

```bash
kubectl get pods -n langsmith

# Get Gateway external IP
EXTERNAL_IP=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Create A record: $EXTERNAL_IP -> <your-langsmith-domain>"

kubectl get certificate -n langsmith
```

---

## Pass 3 — LangSmith Deployments (Optional)

Enables deploying and managing LangGraph graphs from the LangSmith UI. Requires KEDA (auto-installed when `enable_langsmith_deployment = true`).

```hcl
# terraform.tfvars
enable_langsmith_deployment = true
```

```bash
cd gcp/infra
terraform apply -var-file=terraform.tfvars

kubectl get pods -n keda

helm upgrade langsmith langchain/langsmith \
  --namespace langsmith \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.deployment.enabled=true \
  --set config.deployment.url="https://<your-langsmith-domain>" \
  --wait --timeout 10m
```

---

## Variable Reference

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `project_id` | — | yes | GCP project ID |
| `region` | `us-west2` | no | GCP region |
| `zone` | `us-west2-a` | no | GCP zone for zonal resources |
| `environment` | `prod` | no | Environment: dev, staging, prod, test, uat |
| `name_prefix` | `ls` | no | Resource name prefix (1–11 chars) |
| `unique_suffix` | `true` | no | Append random suffix to resource names |
| `subnet_cidr` | `10.0.0.0/20` | no | CIDR for the GKE subnet |
| `pods_cidr` | `10.4.0.0/14` | no | CIDR for GKE pods |
| `services_cidr` | `10.8.0.0/20` | no | CIDR for GKE services |
| `gke_use_autopilot` | `false` | no | Use GKE Autopilot mode |
| `gke_node_count` | `2` | no | Initial node count per zone (Standard mode) |
| `gke_min_nodes` | `2` | no | Minimum nodes per zone for autoscaling |
| `gke_max_nodes` | `10` | no | Maximum nodes per zone for autoscaling |
| `gke_machine_type` | `e2-standard-4` | no | GKE node machine type |
| `gke_disk_size` | `100` | no | Node disk size in GB |
| `gke_release_channel` | `REGULAR` | no | GKE release channel: RAPID, REGULAR, STABLE |
| `gke_deletion_protection` | `true` | no | Enable deletion protection on GKE cluster |
| `gke_network_policy_provider` | `DATA_PLANE_V2` | no | Network policy: CALICO or DATA_PLANE_V2 |
| `postgres_source` | `external` | no | `external` (Cloud SQL) or `in-cluster` (Helm) |
| `postgres_version` | `POSTGRES_15` | no | PostgreSQL version for Cloud SQL |
| `postgres_tier` | `db-custom-2-8192` | no | Cloud SQL machine tier |
| `postgres_disk_size` | `50` | no | Cloud SQL disk size in GB |
| `postgres_high_availability` | `true` | no | Enable Cloud SQL HA (regional standby) |
| `postgres_deletion_protection` | `true` | no | Enable deletion protection on Cloud SQL |
| `postgres_password` | `""` | when external | PostgreSQL password — use `TF_VAR_postgres_password` |
| `redis_source` | `external` | no | `external` (Memorystore) or `in-cluster` (Helm) |
| `redis_version` | `REDIS_7_0` | no | Redis version for Memorystore |
| `redis_memory_size` | `5` | no | Memorystore Redis memory size in GB |
| `redis_high_availability` | `true` | no | Enable Memorystore HA tier (Standard HA) |
| `redis_prevent_destroy` | `false` | no | Prevent accidental Terraform destroy of Redis |
| `clickhouse_source` | `in-cluster` | no | `in-cluster`, `langsmith-managed`, or `external` |
| `clickhouse_host` | `""` | when external | ClickHouse host (external/managed only) |
| `clickhouse_port` | `9440` | no | ClickHouse native protocol port |
| `clickhouse_http_port` | `8443` | no | ClickHouse HTTP port |
| `clickhouse_user` | `default` | no | ClickHouse username |
| `clickhouse_tls` | `true` | no | Enable TLS for ClickHouse connections |
| `storage_ttl_short_days` | `14` | no | GCS TTL for `ttl_s/` prefix |
| `storage_ttl_long_days` | `400` | no | GCS TTL for `ttl_l/` prefix |
| `storage_force_destroy` | `false` | no | Allow bucket deletion with objects inside |
| `langsmith_namespace` | `langsmith` | no | Kubernetes namespace for LangSmith |
| `langsmith_domain` | `langsmith.example.com` | no | Fully qualified domain name |
| `langsmith_license_key` | `""` | no | License key — use `TF_VAR_langsmith_license_key` |
| `langsmith_helm_chart_version` | `""` | no | Pin Helm chart version (empty = latest) |
| `install_ingress` | `true` | no | Install Envoy Gateway via Terraform |
| `ingress_type` | `envoy` | no | Ingress type: `envoy`, `istio`, or `other` |
| `tls_certificate_source` | `none` | no | `none`, `letsencrypt`, or `existing` |
| `letsencrypt_email` | `""` | when letsencrypt | Email for Let's Encrypt notifications |
| `tls_secret_name` | `langsmith-tls` | no | Name for the TLS secret in Kubernetes |
| `enable_langsmith_deployment` | `true` | no | Enable LangSmith Deployments — installs KEDA |
| `owner` | `platform-team` | no | Owner label applied to all resources |
| `cost_center` | `""` | no | Cost center label for billing attribution |
| `labels` | `{}` | no | Additional labels applied to all resources |

### Optional parity module toggles

| Variable | Default | Description |
|---|---|---|
| `enable_gcp_iam_module` | `true` | Wires `modules/iam` for Workload Identity + bucket IAM binding |
| `enable_secret_manager_module` | `false` | Wires `modules/secrets` for Secret Manager bootstrap secret |
| `enable_dns_module` | `false` | Wires `modules/dns` for Cloud DNS + managed cert |
| `dns_create_zone` | `true` | Create a DNS zone when DNS module is enabled |
| `dns_existing_zone_name` | `""` | Existing zone to use when `dns_create_zone = false` |
| `dns_create_certificate` | `true` | Create a Google-managed cert when DNS module is enabled |

---

## Teardown

```bash
# 1. Remove LangSmith Deployments (if Pass 3 was enabled)
kubectl delete lgp --all -n langsmith 2>/dev/null || true

# 2. Uninstall LangSmith Helm release (removes Gateway load balancer)
helm uninstall langsmith -n langsmith --wait

# 3. Delete namespace
kubectl delete namespace langsmith --timeout=60s

# 4. Disable deletion protection in tfvars, then destroy
cd gcp/infra
terraform destroy
```

> Set `gke_deletion_protection = false` and `postgres_deletion_protection = false` in `terraform.tfvars` before running `terraform destroy` in production.
