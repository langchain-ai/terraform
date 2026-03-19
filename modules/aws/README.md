# LangSmith on AWS — Deployment Guide

Self-hosted LangSmith on Amazon EKS, managed with Terraform.

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on AWS. Deployment is split into two passes:

| Pass | What | How | Time |
|------|------|-----|------|
| **Pass 1** | VPC, EKS cluster, RDS, ElastiCache, S3, ALB, IRSA, ESO | `make apply` | ~20–25 min |
| **Pass 2** | LangSmith Helm chart + ESO wiring | `make init-values` → `make deploy` (scripts) or `make apply-app` (Terraform) | ~10 min |

A [Makefile](Makefile) wraps all commands — run `make help` to see available targets.

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | RDS PostgreSQL (private) | ElastiCache Redis (private) | [LangChain Managed](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse) | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to S3 — never to ClickHouse.
>
> **In-cluster ClickHouse is for dev/POC only.** It runs as a single pod with no replication or backups. For production, use [LangChain Managed ClickHouse](https://docs.langchain.com/langsmith/langsmith-managed-clickhouse).

---

## Prerequisites

### Required tools

```bash
# AWS CLI v2
brew install awscli
aws --version

# Terraform (>= 1.5)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform
terraform version

# kubectl
brew install kubectl
kubectl version --client

# Helm (>= 3.12)
brew install helm
helm version

# eksctl (useful for debugging and kubeconfig management)
brew install eksctl
```

### Required AWS IAM permissions

The IAM user or role running Terraform needs the following managed policies (or equivalent inline policies):

| Policy | Purpose |
|--------|---------|
| `AmazonEKSClusterPolicy` | Create and manage EKS clusters |
| `AmazonVPCFullAccess` | Create VPC, subnets, route tables, NAT |
| `AmazonRDSFullAccess` | Create and manage RDS instances |
| `AmazonElastiCacheFullAccess` | Create ElastiCache clusters |
| `AmazonS3FullAccess` | Create S3 buckets and VPC endpoints |
| `IAMFullAccess` | Create IRSA roles and policies |
| `ElasticLoadBalancingFullAccess` | Create ALB via Terraform |

### Authenticate

```bash
aws configure
# or:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-west-2

aws sts get-caller-identity
```

---

## Repository Layout

```
aws/
├── Makefile                ← Task runner — run `make help` for all targets
├── infra/                  ← Pass 1: Terraform infrastructure
│   ├── main.tf             ← Root module — wires all sub-modules, IRSA + ESO setup
│   ├── variables.tf        ← All input variables with defaults
│   ├── locals.tf           ← Naming: {name_prefix}-{environment}-{resource}
│   ├── outputs.tf          ← Cluster, DB, Redis, S3, ALB, IAM outputs
│   ├── backend.tf          ← Remote state backend (configure before init)
│   ├── versions.tf         ← Required provider versions
│   ├── scripts/
│   │   ├── _common.sh          ← Shared helpers (tfvar parsing, colors)
│   │   ├── manage-ssm.sh       ← Interactive SSM parameter manager
│   │   ├── migrate-ssm.sh      ← Migrate SSM params from legacy paths
│   │   ├── preflight.sh        ← Pre-Terraform AWS permission checks
│   │   ├── quickstart.sh       ← Interactive setup wizard
│   │   ├── set-kubeconfig.sh   ← Update KUBECONFIG for EKS
│   │   ├── setup-env.sh        ← Create/manage secrets in SSM Parameter Store
│   │   └── status.sh           ← Deployment state checker
│   └── modules/
│       ├── vpc/            ← VPC, subnets, NAT gateway
│       ├── eks/            ← EKS cluster, managed node groups, IRSA role, GP3 storage class
│       ├── postgres/       ← RDS PostgreSQL, subnet group, security group, IAM auth
│       ├── redis/          ← ElastiCache Redis, subnet group, security group, auth token
│       ├── storage/        ← S3 bucket, VPC Gateway Endpoint, bucket policy, TTL lifecycle
│       ├── alb/            ← Application Load Balancer, security group, ACM integration
│       ├── k8s-bootstrap/  ← Namespace, KEDA, cert-manager, ESO Helm release
│       ├── bastion/        ← EC2 bastion host for private cluster access (optional)
│       ├── cloudtrail/     ← CloudTrail trail to S3 (optional)
│       └── waf/            ← WAFv2 Web ACL attached to ALB (optional)
├── helm/                   ← Pass 2 option A: script-driven Helm deploy
│   ├── scripts/
│   │   ├── deploy.sh               ← Helm deploy orchestrator (ESO wiring, values layering)
│   │   ├── apply-eso.sh            ← Apply ESO ClusterSecretStore + ExternalSecret (standalone)
│   │   ├── init-values.sh          ← Generate values-overrides.yaml from Terraform outputs
│   │   ├── preflight-check.sh      ← Pre-deploy validation
│   │   └── uninstall.sh            ← Helm uninstall + cleanup
│   └── values/
│       ├── examples/                                    ← Reference templates (init-values.sh copies from here)
│       │   ├── langsmith-values.yaml                    ← Base AWS values
│       │   ├── langsmith-values-sizing-ha.yaml          ← HA sizing (production)
│       │   ├── langsmith-values-sizing-light.yaml       ← Light sizing (POC/test)
│       │   ├── langsmith-values-agent-deploys.yaml      ← Deployments feature
│       │   ├── langsmith-values-agent-builder.yaml      ← Agent Builder
│       │   └── langsmith-values-insights.yaml           ← ClickHouse Insights
│       ├── langsmith-values.yaml                        ← Active base (created by init-values.sh)
│       ├── langsmith-values-overrides.yaml              ← Active overrides (auto-generated)
│       └── langsmith-values-*.yaml                      ← Active sizing/addon files (based on choices)
└── app/                    ← Pass 2 option B: Terraform-managed Helm deploy
    ├── main.tf             ← Providers, ESO resources, helm_release
    ├── variables.tf        ← Infra inputs (auto-populated) + app config
    ├── locals.tf           ← Variable resolution + validation
    ├── outputs.tf          ← LangSmith URL, release status
    ├── versions.tf
    ├── terraform.tfvars.example
    └── scripts/
        └── pull-infra-outputs.sh  ← Reads infra outputs → infra.auto.tfvars.json
```

---

## Configuration

Copy and populate the variables file:

```bash
cd terraform/aws/infra
cp terraform.tfvars.example terraform.tfvars  # if it exists
```

Minimum required variables:

```hcl
# Resource naming
name_prefix = "acme"       # your company/team prefix (max 11 chars)
environment = "prod"

# AWS region
region = "us-west-2"

# EKS
eks_cluster_version = "1.31"
eks_managed_node_groups = {
  default = {
    name           = "node-group-default"
    instance_types = ["m5.4xlarge"]
    min_size       = 3
    max_size       = 10
  }
}

# RDS PostgreSQL (required when postgres_source = "external")
postgres_source   = "external"
postgres_password = "<strong-password>"   # or: export TF_VAR_postgres_password=...

# ElastiCache Redis (required when redis_source = "external")
redis_source     = "external"
redis_auth_token = "<min-16-char-token>"  # or: export TF_VAR_redis_auth_token=...

# TLS — "acm" (default), "letsencrypt", or "none"
tls_certificate_source = "acm"
acm_certificate_arn    = "arn:aws:acm:us-west-2:<account-id>:certificate/<cert-id>"

# LangSmith domain (leave empty to use ALB DNS name)
langsmith_domain = "langsmith.<your-domain>"
```

### Terraform state backend (recommended for production)

Configure `terraform/aws/infra/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket = "<your-terraform-state-bucket>"
    key    = "langsmith/aws/terraform.tfstate"
    region = "us-west-2"
  }
}
```

---

## Pass 1 — Infrastructure

Provisions: VPC, EKS cluster, RDS PostgreSQL, ElastiCache Redis, S3 bucket + VPC endpoint, ALB, IRSA role, ESO IRSA role, SSM secrets.

```bash
cd terraform/aws

# First time? Generate terraform.tfvars interactively:
make quickstart

# Create and populate secrets in SSM Parameter Store
# (must be sourced — Make can't do this; run `make setup-env` for the exact command)
source infra/scripts/setup-env.sh

# Deploy infrastructure
make init
make plan
make apply
```

> **Duration:** ~20–25 minutes. EKS cluster creation takes 12–15 minutes. RDS takes additional 5–8 minutes. Do not interrupt.

### After apply — get cluster credentials

```bash
make kubeconfig

kubectl get nodes
kubectl get ns
kubectl get pods -n kube-system
```

---

## Pass 2 — LangSmith Application

Two paths — pick one:

### Option A: Script-driven Helm deploy (recommended)

Best for: most deployments. Interactive prompts guide you through sizing and product choices.

```bash
cd terraform/aws

make init-values       # prompts: admin email, sizing (ha/light/none), product tier
make deploy            # deploy LangSmith via Helm (includes ESO wiring)
```

`init-values.sh` prompts for your sizing profile and which products to enable, then copies the right values files from `helm/values/examples/`. On re-runs it preserves your choices and refreshes Terraform outputs.

### Option B: Terraform-managed Helm deploy

Best for: teams that want the full deployment in Terraform state, or "bring your own infra" scenarios.

```bash
cd terraform/aws

# Generate Helm values files from templates (required — the app module reads these)
make init-values

# Pull infra outputs into app/infra.auto.tfvars.json
make init-app

# Configure app-specific settings
cp app/terraform.tfvars.example app/terraform.tfvars
# Edit app/terraform.tfvars — set admin_email, sizing, feature toggles

# Deploy
make plan-app
make apply-app
```

> **Important:** `make init-values` is required before `make plan-app`. The app module reads YAML values files from `helm/values/` — `init-values` copies them from `helm/values/examples/` based on your sizing and product choices.

The `app/` module manages the ESO ClusterSecretStore, ExternalSecret, and `helm_release` in Terraform. Feature toggles are variables:

```hcl
admin_email          = "admin@example.com"
sizing               = "ha"           # ha | light | none
enable_agent_deploys = true
enable_agent_builder = true
enable_insights      = true
clickhouse_host      = "clickhouse.example.com"
```

For "bring your own infra" — skip `make init-app` and set all variables manually in `app/terraform.tfvars`.

---

## Private Cluster with Bastion Host

For customers who require a fully private EKS cluster (`enable_public_eks_cluster = false`), the EKS API endpoint is only reachable from within the VPC. A bastion host provides the access point.

### How it works

1. **First run from your workstation** — Deploy infrastructure with `create_bastion = true` and `enable_public_eks_cluster = true` (temporarily). This creates the bastion alongside everything else.
2. **Switch to private** — Set `enable_public_eks_cluster = false` and re-apply. The EKS API endpoint becomes private-only.
3. **All future work happens on the bastion** — SSM into the bastion, clone the repo, copy your `terraform.tfvars` and secrets, and run Pass 1/2 from there.

### Setup

```hcl
# terraform.tfvars
enable_public_eks_cluster = false   # private API endpoint
create_bastion            = true    # bastion for access

# Optional SSH (SSM is the default — no key needed):
# bastion_key_name          = "my-keypair"
# bastion_enable_ssh        = true
# bastion_ssh_allowed_cidrs = ["203.0.113.0/24"]
```

### Connect via SSM Session Manager

```bash
# After terraform apply, the SSM command is in the outputs:
terraform output bastion_ssm_command

# Or connect directly:
aws ssm start-session --target <instance-id> --region us-west-2
```

> **Prerequisite:** Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI.

### Working from the bastion

The bastion comes pre-installed with kubectl, helm, terraform, git, and jq. Kubeconfig is pre-configured for the EKS cluster.

```bash
# After SSM-ing in:
kubectl get nodes                        # verify cluster access
git clone <your-repo-url>                # get the deployment code
cd ps-control-plane/terraform/aws

# Copy your terraform.tfvars and secrets, then run normally:
source infra/scripts/setup-env.sh
make plan
make apply
make deploy
```

### Important notes

- The bastion's IAM role has `AmazonSSMManagedInstanceCore` and `AmazonEKSClusterPolicy` attached. Add additional policies if you need the bastion to manage other AWS resources.
- The bastion lives in a **public subnet** (for SSM agent connectivity). It does not need a public IP if your VPC has VPC endpoints for SSM (`ssm`, `ssmmessages`, `ec2messages`).
- When the EKS API is private, `terraform plan/apply` targeting EKS resources **must** be run from within the VPC (i.e., the bastion). Running from your laptop will timeout.

---

### Verify and get endpoint

```bash
kubectl get pods -n langsmith
kubectl get ingress -n langsmith
```

---

## Variable Reference

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `name_prefix` | — | yes | Prefix for all resource names (1–11 chars, lowercase) |
| `environment` | `dev` | no | Environment: dev, staging, prod, test, uat |
| `region` | `us-west-2` | no | AWS region for all resources |
| `create_vpc` | `true` | no | Create a new VPC (set false to use existing) |
| `vpc_id` | `null` | when !create_vpc | Existing VPC ID |
| `private_subnets` | `[]` | when !create_vpc | Existing private subnet IDs |
| `public_subnets` | `[]` | when !create_vpc | Existing public subnet IDs |
| `vpc_cidr_block` | `null` | when !create_vpc | Existing VPC CIDR block |
| `enable_public_eks_cluster` | `true` | no | Enable public EKS API endpoint |
| `eks_public_access_cidrs` | `["0.0.0.0/0"]` | no | CIDRs allowed to reach the public EKS API endpoint |
| `eks_cluster_version` | `1.31` | no | EKS Kubernetes version |
| `eks_managed_node_group_defaults` | `{ami_type: AL2023}` | no | Default config for managed node groups |
| `eks_managed_node_groups` | `{default: m5.4xlarge}` | no | Managed node group definitions |
| `create_gp3_storage_class` | `true` | no | Create and set gp3 as default StorageClass |
| `eks_addons` | `{}` | no | EKS managed add-on configurations |
| `create_langsmith_irsa_role` | `true` | no | Create IRSA role for LangSmith pods (S3 access) |
| `postgres_source` | `external` | no | `external` (RDS) or `in-cluster` (Helm) |
| `postgres_instance_type` | `db.t3.large` | no | RDS instance class |
| `postgres_storage_gb` | `10` | no | Initial RDS storage in GB |
| `postgres_max_storage_gb` | `100` | no | Maximum RDS storage in GB (autoscaling) |
| `postgres_username` | `langsmith` | no | RDS database username |
| `postgres_password` | `""` | when external | RDS password — use `TF_VAR_postgres_password` |
| `postgres_iam_database_authentication_enabled` | `true` | no | Enable IAM database authentication on RDS |
| `postgres_deletion_protection` | `true` | no | Enable deletion protection on RDS |
| `redis_source` | `external` | no | `external` (ElastiCache) or `in-cluster` (Helm) |
| `redis_instance_type` | `cache.m6g.xlarge` | no | ElastiCache node type |
| `redis_auth_token` | `""` | when external | ElastiCache auth token (min 16 chars) — use `TF_VAR_redis_auth_token` |
| `s3_ttl_enabled` | `true` | no | Enable S3 lifecycle rules for trace TTL |
| `s3_ttl_short_days` | `14` | no | TTL for `ttl_s/` prefix in days |
| `s3_ttl_long_days` | `400` | no | TTL for `ttl_l/` prefix in days |
| `tls_certificate_source` | `acm` | no | `acm`, `letsencrypt`, or `none` |
| `acm_certificate_arn` | `""` | when acm | ACM certificate ARN |
| `letsencrypt_email` | `""` | when letsencrypt | Email for Let's Encrypt |
| `langsmith_domain` | `""` | no | Custom hostname (empty = use ALB DNS name) |
| `langsmith_namespace` | `langsmith` | no | Kubernetes namespace for LangSmith |
| `clickhouse_source` | `in-cluster` | no | `in-cluster` or `external` |
| `alb_access_logs_enabled` | `false` | no | Enable ALB access logging to S3 |
| `create_bastion` | `false` | no | Create EC2 bastion host for private cluster access (SSM or SSH) |
| `bastion_instance_type` | `t3.micro` | no | EC2 instance type for bastion |
| `bastion_key_name` | `null` | no | EC2 key pair for SSH (empty = SSM only) |
| `bastion_enable_ssh` | `false` | no | Open port 22 on bastion security group |
| `bastion_ssh_allowed_cidrs` | `[]` | no | CIDRs allowed to SSH to bastion |
| `bastion_root_volume_size_gb` | `20` | no | Root EBS volume size for bastion |
| `create_cloudtrail` | `false` | no | Create CloudTrail trail for AWS API audit |
| `cloudtrail_multi_region` | `true` | no | Record API calls across all regions |
| `cloudtrail_log_retention_days` | `365` | no | Days to retain CloudTrail logs |
| `create_waf` | `false` | no | Attach WAFv2 Web ACL to ALB |
| `langsmith_deployments_encryption_key` | `""` | no | Fernet key for LangSmith Deployments |
| `langsmith_agent_builder_encryption_key` | `""` | no | Fernet key for Agent Builder |
| `langsmith_insights_encryption_key` | `""` | no | Fernet key for Insights |
| `owner` | `""` | no | Owner tag applied to all resources |
| `cost_center` | `""` | no | Cost center tag for billing |
| `tags` | `{}` | no | Additional tags applied to all resources |

---

## Teardown

### If deployed via scripts (Option A)

```bash
cd terraform/aws
make uninstall
```

### If deployed via Terraform (Option B)

```bash
cd terraform/aws
make destroy-app
```

### Destroy infrastructure

```bash
# Disable deletion protection first
# Set postgres_deletion_protection = false in infra/terraform.tfvars

cd terraform/aws/infra
terraform apply
terraform destroy
```
