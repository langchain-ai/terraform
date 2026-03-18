# LangSmith on AWS — Deployment Guide

Self-hosted LangSmith on Amazon EKS, managed with Terraform.

---

## Overview

This directory contains the Terraform configuration to deploy LangSmith on AWS. Infrastructure is provisioned in three passes:

| Pass | What | Time |
|------|------|------|
| **Pass 1** | VPC, EKS cluster, RDS PostgreSQL, ElastiCache Redis, S3 bucket, ALB, IRSA, ESO | ~20–25 min |
| **Pass 2** | LangSmith Helm chart | ~10 min |
| **Pass 3** | LangSmith Deployments (KEDA-based, optional) | ~5 min |

### Two deployment tiers

| Tier | Postgres | Redis | ClickHouse | Use case |
|------|---------|-------|-----------|---------|
| **Light** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
| **Production** | RDS PostgreSQL (private) | ElastiCache Redis (private) | In-cluster pod | Scalable / persistent |

> **Blob storage is always required.** Trace payloads must go to S3 — never to ClickHouse.

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
├── infra/
│   ├── main.tf             ← Root module — wires all sub-modules, IRSA + ESO setup
│   ├── variables.tf        ← All input variables with defaults
│   ├── locals.tf           ← Naming: {name_prefix}-{environment}-{resource}
│   ├── outputs.tf          ← Cluster, DB, Redis, S3, ALB, IAM outputs
│   ├── backend.tf          ← Remote state backend (configure before init)
│   ├── versions.tf         ← Required provider versions
│   └── modules/
│       ├── vpc/            ← VPC (10.0.0.0/16), 5 private + 3 public subnets, NAT
│       ├── eks/            ← EKS cluster, managed node groups, IRSA role, GP3 storage class
│       ├── postgres/       ← RDS PostgreSQL, subnet group, security group, IAM auth
│       ├── redis/          ← ElastiCache Redis, subnet group, security group, auth token
│       ├── storage/        ← S3 bucket, VPC Gateway Endpoint, bucket policy, TTL lifecycle
│       ├── alb/            ← Application Load Balancer, security group, ACM integration
│       ├── k8s-bootstrap/  ← Namespace, cert-manager, ESO IRSA binding
│       ├── secrets/        ← SSM Parameter Store secrets (Postgres password, Redis token)
│       ├── iam/            ← Additional IAM roles and policies
│       ├── dns/            ← Route 53 hosted zone (optional)
│       ├── cloudtrail/     ← CloudTrail trail to S3 (optional)
│       └── waf/            ← WAFv2 Web ACL attached to ALB (optional)
└── helm/
    ├── scripts/
    │   ├── deploy.sh               ← Helm deploy automation
    │   ├── generate-secrets.sh     ← Generate API key salt, JWT secret, Fernet keys
    │   ├── preflight-check.sh      ← Pre-deploy validation
    │   ├── init-overrides.sh       ← Initialize values-overrides.yaml from Terraform outputs
    │   └── uninstall.sh            ← Helm uninstall + cleanup
    └── values/
        ├── langsmith-values.yaml.example              ← Base values template
        ├── langsmith-values-production.yaml.example   ← Production overlay
        ├── langsmith-values-agent-deploys.yaml.example ← Pass 3 overlay
        ├── langsmith-values-agent-builder.yaml.example ← Agent Builder overlay
        └── langsmith-values-insights.yaml.example     ← Insights overlay
```

---

## Configuration

Copy and populate the variables file:

```bash
cd aws/infra
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

Configure `aws/infra/backend.tf`:

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
cd aws/infra

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

> **Duration:** ~20–25 minutes. EKS cluster creation takes 12–15 minutes. RDS takes additional 5–8 minutes. Do not interrupt.

### After apply — get cluster credentials

```bash
aws eks update-kubeconfig \
  --region $(terraform output -raw region 2>/dev/null || echo us-west-2) \
  --name $(terraform output -raw cluster_name)

kubectl get nodes
kubectl get ns
kubectl get pods -n kube-system
```

### Verify IRSA for S3

```bash
terraform output langsmith_irsa_role_arn
kubectl get sa langsmith -n langsmith -o jsonpath='{.metadata.annotations}' 2>/dev/null || true
```

---

## Pass 2 — LangSmith Helm Deploy

```bash
# Get outputs
cd aws/infra
terraform output -raw alb_dns_name
terraform output -raw langsmith_irsa_role_arn

helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export INSIGHTS_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export ADMIN_EMAIL="admin@example.com"
export ADMIN_PASSWORD="<strong-password>"

helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith \
  --create-namespace \
  -f ../helm/values/langsmith-values.yaml.example \
  --set config.langsmithLicenseKey="<your-license-key>" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="$(terraform output -raw alb_dns_name)" \
  --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
  --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
  --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
  --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
  --set config.blobStorage.provider="s3" \
  --set config.blobStorage.bucketName="$(terraform output -raw bucket_name)" \
  --set config.blobStorage.region="us-west-2" \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform output -raw langsmith_irsa_role_arn)" \
  --wait --timeout 15m
```

### Verify and get endpoint

```bash
kubectl get pods -n langsmith

# ALB DNS name (for DNS CNAME record)
terraform output -raw alb_dns_name

# Get ingress address
kubectl get ingress -n langsmith
```

---

## Pass 3 — LangSmith Deployments (Optional)

```bash
# Install KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --wait

# Upgrade LangSmith with Deployments enabled
helm upgrade langsmith langchain/langsmith \
  --namespace langsmith \
  -f ../helm/values/langsmith-values.yaml.example \
  -f ../helm/values/langsmith-values-agent-deploys.yaml.example \
  --set config.deployment.enabled=true \
  --set config.deployment.url="https://<your-langsmith-domain>" \
  --wait --timeout 10m

kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
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

```bash
# 1. Remove LangSmith Deployments (if Pass 3 was enabled)
kubectl delete lgp --all -n langsmith 2>/dev/null || true

# 2. Uninstall LangSmith
helm uninstall langsmith -n langsmith --wait

# 3. Delete namespace
kubectl delete namespace langsmith --timeout=60s

# 4. Disable deletion protection, then destroy
cd aws/infra
# Set postgres_deletion_protection = false in terraform.tfvars
terraform apply -var-file=terraform.tfvars
terraform destroy
```
