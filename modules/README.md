# Terraform

Terraform layouts for LangSmith self-hosted deployments across AWS, Azure, GCP, and OpenShift.

## Structure

AWS, Azure, and GCP share the same broad workflow, but their child modules and scripts are provider-specific. From the repository root, the common shape is:

```
modules/<provider>/
├── Makefile                         # AWS, Azure, and GCP
├── infra/
│   ├── main.tf
│   ├── locals.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   ├── backend.tf.example
│   ├── modules/                     # provider-specific child modules
│   └── scripts/                     # setup, quickstart, and secret helpers
├── helm/
│   ├── scripts/                     # provider-specific Helm and cluster helpers
│   └── values/
│       └── examples/                # sizing and add-on examples where supported
├── README.md
├── ARCHITECTURE.md
├── QUICK_REFERENCE.md
├── TROUBLESHOOTING.md
└── TEARDOWN.md
```

Not every provider has every file in that sketch. In particular:

- AWS gets cluster credentials from `infra/scripts/set-kubeconfig.sh`; Azure and GCP use `helm/scripts/get-kubeconfig.sh`.
- There is no shared `generate-secrets.sh` for AWS, Azure, and GCP. AWS uses `helm/scripts/apply-eso.sh`, Azure uses `infra/scripts/seed-keyvault-secrets.sh` and `infra/scripts/create-k8s-secrets.sh`, and GCP uses `infra/scripts/setup-env.sh` plus `helm/scripts/init-values.sh`. `generate-secrets.sh` exists only in the OpenShift preview.
- Among AWS, Azure, and GCP, only GCP checks in `helm/values/values-overrides.yaml.example`. AWS and Azure generate their local Helm values through `init-values.sh`. OpenShift also carries an example file for its preview flow.
- OpenShift currently contains stub infrastructure modules and Helm helpers, but no provider `Makefile` or quickstart wizard.

## Providers

| Directory | Provider |
|---|---|
| `aws/` | Amazon Web Services |
| `azure/` | Microsoft Azure |
| `gcp/` | Google Cloud Platform |
| `ocp/` | OpenShift Container Platform |

## Capabilities

The rows below describe equivalent capabilities; the child-module directory names are not uniform across providers.

| Capability | AWS | GCP | Azure | OCP |
|---|---|---|---|---|
| Networking | VPC (`vpc/`) | VPC (`networking/`) | VNet (`networking/`) | stub |
| Kubernetes cluster | EKS (`eks/`) | GKE (`k8s-cluster/`) | AKS (`k8s-cluster/`) | stub |
| `k8s-bootstrap` | namespaces / RBAC | namespaces / RBAC | namespaces / RBAC | namespaces / RBAC |
| `postgres` | RDS | Cloud SQL | Azure Database for PostgreSQL | stub |
| `redis` | ElastiCache | Memorystore | Azure Managed Redis (`Microsoft.Cache/redisEnterprise` via AzAPI) | stub |
| `storage` | S3 | GCS | Azure Blob Storage | stub |
| `dns` | Route 53 + ACM | Cloud DNS + managed cert | Azure DNS | OCP Route |
| Application secret store | SSM Parameter Store, managed by scripts (no `secrets/` child module) | Secret Manager; `secrets/` is an optional Terraform bootstrap module | Key Vault (`keyvault/`) | Kubernetes Secret (`secrets/`) |
| Workload access | IRSA resources | Workload Identity (`iam/`) | Managed Identity | SCC + RBAC (`scc/`) |

## Secret flow and state

The cloud-native store is not the Kubernetes delivery mechanism, and marking a Terraform input as sensitive does not keep it out of state.

| Provider | Persistent store | Application delivery to Kubernetes / Helm | Terraform state boundary |
|---|---|---|---|
| AWS | `infra/scripts/setup-env.sh` writes application secrets to SSM Parameter Store. | `helm/scripts/apply-eso.sh` applies an ESO `ClusterSecretStore` and `ExternalSecret`, which sync `langsmith-config`. | SSM-backed application secrets are not managed by Terraform. Terraform-managed database, cache, and feature connection Kubernetes Secrets are stored in state. |
| Azure | `infra/scripts/seed-keyvault-secrets.sh` writes generated application secrets directly to Key Vault. By default, Terraform also writes the Postgres password and license key to the vault because it already consumes those values. | `infra/scripts/create-k8s-secrets.sh` reads Key Vault and applies `langsmith-config-secret`; Terraform separately creates Postgres, Redis, Fleet, and license Kubernetes Secrets. | Generated application secrets bypass Terraform. Postgres, Redis, Fleet, and license values used by Terraform remain in state. |
| GCP | `infra/scripts/setup-env.sh` stores setup values in Secret Manager and exports them for the deployment tools. | `helm/scripts/init-values.sh` writes application values to the gitignored `values-overrides.yaml`; Terraform separately creates database, cache, license, ClickHouse, and optional TLS Kubernetes Secrets. | Application values consumed only by Helm are not stored in Terraform state. Values used by Terraform-managed Secret resources remain in state. |

Treat every Terraform backend that contains one of these deployments as sensitive data. Gitignored `tfvars`, state files, and generated Helm values still need access controls and secure storage.

## Usage

AWS, Azure, and GCP all expose the same interactive entry point:

```bash
cd modules/aws                # or modules/azure, modules/gcp
make quickstart
make help
```

Each provider then has its own secret and cluster-access steps, so follow its README instead of assuming script names are interchangeable:

- AWS: [`aws/README.md`](aws/README.md)
- Azure: [`azure/README.md`](azure/README.md)
- GCP: [`gcp/README.md`](gcp/README.md)
- OpenShift preview: [`ocp/README.md`](ocp/README.md)

## Deployment tiers

| Tier | Description |
|---|---|
| **1 — All internal** | Everything runs in-cluster (dev/POC only) |
| **2 — External services** | External Redis + Postgres + Blob, internal ClickHouse (dev/POC only) |
| **3 — All external** | Production recommended — uses [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) |

> Blob storage is always required — payloads in ClickHouse cause cluster issues.
>
> **In-cluster ClickHouse is for dev/POC only.** For production deployments, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

## Per-provider guides

- [`aws/README.md`](aws/README.md) — AWS EKS deployment guide
- [`azure/README.md`](azure/README.md) — Azure AKS deployment guide (5-pass pattern)
- [`gcp/README.md`](gcp/README.md) — GCP GKE deployment guide
- [`ocp/README.md`](ocp/README.md) — OpenShift deployment guide
