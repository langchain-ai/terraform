# Terraform

Production-ready Terraform modules for LangSmith self-hosted deployments across AWS, Azure, GCP, and OpenShift.

## Structure

Each provider directory mirrors this layout:

```
terraform/<provider>/
├── infra/
│   ├── main.tf
│   ├── locals.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   ├── backend.tf.example
│   └── modules/
│       ├── networking/
│       ├── k8s-cluster/
│       ├── k8s-bootstrap/
│       ├── postgres/
│       ├── redis/
│       ├── storage/
│       ├── dns/           # hosted zone + TLS certificate
│       ├── secrets/       # cloud-native secrets store
│       └── iam/           # workload identity / pod IAM (aws, gcp)
│           identity/      # managed identity (azure)
│           scc/           # SecurityContextConstraints (ocp)
├── helm/
│   ├── scripts/
│   │   ├── preflight-check.sh   # verify tools and cluster connectivity
│   │   ├── get-kubeconfig.sh    # fetch cluster credentials
│   │   ├── generate-secrets.sh  # bridge Terraform outputs → k8s Secrets
│   │   └── deploy.sh            # helm upgrade --install
│   └── values/
│       ├── values.yaml                   # cloud-specific defaults (checked in)
│       └── values-overrides.yaml.example # customer config template
├── README.md
├── ARCHITECTURE.md
├── QUICK_REFERENCE.md
├── TROUBLESHOOTING.md
└── TEARDOWN.md
```

## Providers

| Directory | Provider | Owner |
|---|---|---|
| `aws/` | Amazon Web Services | Michael |
| `azure/` | Microsoft Azure | Dzmitry |
| `gcp/` | Google Cloud Platform | David |
| `ocp/` | OpenShift Container Platform | — |

## Modules

| Module | AWS | GCP | Azure | OCP |
|---|---|---|---|---|
| `networking` | VPC | VPC | VNet | stub |
| `k8s-cluster` | EKS | GKE | AKS | stub |
| `k8s-bootstrap` | namespaces / RBAC | namespaces / RBAC | namespaces / RBAC | namespaces / RBAC |
| `postgres` | RDS | Cloud SQL | Azure Database for PostgreSQL | stub |
| `redis` | ElastiCache | Memorystore | Azure Cache for Redis | stub |
| `storage` | S3 | GCS | Azure Blob Storage | stub |
| `dns` | Route 53 + ACM | Cloud DNS + managed cert | Azure DNS | OCP Route |
| `secrets` | Secrets Manager | Secret Manager | Key Vault | k8s Secret |
| `iam` / `identity` / `scc` | IRSA role | Workload Identity | Managed Identity | SCC + RBAC |

## Usage

### 1. Provision infrastructure

```bash
cd terraform/aws/infra        # or azure/ gcp/ ocp/
cp terraform.tfvars.example terraform.tfvars
cp backend.tf.example backend.tf
# edit both files
terraform init
terraform plan
terraform apply
```

### 2. Configure Helm values

```bash
cd terraform/aws/helm/values  # or azure/ gcp/ ocp/
cp values-overrides.yaml.example values-overrides.yaml
# fill in license key, hostname, and Terraform outputs
```

### 3. Deploy LangSmith

```bash
cd terraform/aws/helm/scripts  # or azure/ gcp/ ocp/
./preflight-check.sh
./get-kubeconfig.sh <cluster-name>
./generate-secrets.sh
./deploy.sh
```

## Deployment tiers

| Tier | Description |
|---|---|
| **1 — All internal** | Everything runs in-cluster |
| **2 — External services** | External Redis + Postgres + Blob, internal ClickHouse (recommended) |
| **3 — All external** | Fully managed external services |

> Blob storage is always required — payloads in ClickHouse cause cluster issues.

## Per-provider guides

- [`aws/README.md`](aws/README.md) — AWS EKS deployment guide
- [`azure/README.md`](azure/README.md) — Azure AKS deployment guide (5-pass pattern)
- [`gcp/README.md`](gcp/README.md) — GCP GKE deployment guide
- [`ocp/README.md`](ocp/README.md) — OpenShift deployment guide
