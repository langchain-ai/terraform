# LangSmith Self-Hosted — Preflight Checklist (P0)

**Purpose:**  
Ensure the environment is ready *before* running Terraform or Helm.  
Most deployment challenges can be prevented by completing these checks upfront, rather than discovering issues during installation.

If a preflight check fails, **address it before proceeding**. This ensures a smoother deployment experience.

---

## Automated Preflight Checks

You can use the provided preflight script to automatically verify AWS permissions and prerequisites before proceeding with manual checks.

### Quick Start

Run the automated preflight script:

```bash
./scripts/preflight.sh
```

### What the Script Does

The script performs **read-only** permission checks to verify you have the necessary AWS permissions for deploying LangSmith Self-Hosted. By default, it:

- Verifies AWS credentials are configured
- Tests permissions for required AWS services:
  - **EC2** (VPCs, subnets, availability zones)
  - **EKS** (cluster management)
  - **IAM** (role creation and management)
  - **RDS** (PostgreSQL/Aurora)
  - **ElastiCache** (Redis)
  - **Application Load Balancer** (ALB/ELB)
  - **ACM** (TLS certificates)
  - **Route53** (DNS management)
  - **WAFv2** (optional, for production)
- Checks for sandbox account restrictions
- Validates region configuration

**Note:** The script is read-only by default and does not create or modify any resources.

### Command-Line Options

```bash
./scripts/preflight.sh [OPTIONS]
```

**Options:**
- `-s, --skip_resource_tests, --skip_checks`  
  Skip resource creation tests (only run read-only permission checks)

- `-y, --yes`  
  Non-interactive mode (skip confirmation prompts). Automatically enabled in CI environments.

- `--create-test-resources`  
  Create temporary test resources (VPC, subnet, security group, IAM role) to verify write permissions. Resources are automatically cleaned up on exit. Use this to fully validate your permissions.

- `--domain <domain>`  
  Check for ACM certificate and Route53 hosted zone matching the specified domain (e.g., `langsmith.example.com`). The script will check for exact matches and wildcard certificates.

**Examples:**

```bash
# Basic permission check (read-only)
./scripts/preflight.sh

# Check permissions and verify ACM certificate exists
./scripts/preflight.sh --domain langsmith.example.com

# Full permission test including resource creation
./scripts/preflight.sh --create-test-resources

# Non-interactive mode (useful for CI/CD)
./scripts/preflight.sh --yes --domain langsmith.example.com
```

### When to Use the Script

- **Before starting deployment:** Run the script to verify all AWS permissions are in place
- **Troubleshooting permission issues:** Use `--create-test-resources` to test write permissions
- **CI/CD pipelines:** Use `--yes` flag for automated checks
- **Certificate validation:** Use `--domain` to verify ACM certificates and Route53 zones exist

The script provides clear success/failure indicators for each permission check, making it easy to identify and resolve permission issues before deployment.

---

## 1. Account & Access

### AWS Account
- [ ] You have **full access** to an AWS account (not a sandbox with hidden SCPs)
- [ ] You can create:
  - VPCs
  - EKS clusters
  - ALBs
  - IAM roles and policies
  - RDS / ElastiCache
  - EBS volumes
- [ ] No org-level policy blocks required services

### Credentials
- [ ] AWS credentials configured locally (`aws sts get-caller-identity` works)
- [ ] Region selected and consistent across Terraform and Helm
- [ ] You understand **who pays for this** (this will not be free)

---

## 2. Terraform Readiness

### Tooling
- [ ] Terraform installed (supported version)
- [ ] `kubectl` installed
- [ ] `helm` installed
- [ ] `awscli` installed

### State Management
- [ ] Terraform state backend chosen (S3 + DynamoDB recommended)
- [ ] State bucket exists or can be created
- [ ] You are not sharing state with another environment

### Assumptions (Explicit)
- [ ] You are deploying **one environment** (no shared dev/prod infra)
- [ ] You are okay with Terraform creating networking resources
- [ ] You will not “hot-edit” AWS resources Terraform owns

---

## 3. Network & DNS

### VPC
- [ ] A dedicated VPC will exist for LangSmith
- [ ] At least:
  - 2 public subnets (ALB)
  - 2 private subnets (EKS + data)
- [ ] NAT Gateway available for private subnet egress

### DNS
- [ ] A Route53 hosted zone exists (or you control DNS externally)
- [ ] You can create DNS records for the LangSmith endpoint
- [ ] You know whether this will be:
  - [ ] Publicly accessible
  - [ ] Private-only (VPN / PrivateLink)

---

## 4. Kubernetes (EKS) Expectations

### Cluster
- [ ] EKS will be used (not self-managed k8s)
- [ ] You accept managed node groups
- [ ] You are not using custom admission controllers that block installs

### Capacity (Hard Requirement)
- [ ] Minimum **16 vCPU / 64 GB RAM** allocatable cluster capacity
- [ ] Nodes are sized to allow:
  - LangSmith services
  - ClickHouse
  - System overhead

> **For detailed production capacity and resource requirements, see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md).**

### Required Add-ons
- [ ] Metrics Server enabled
- [ ] Cluster Autoscaler enabled
- [ ] You can install CRDs

---

## 5. Data Stores

### PostgreSQL
- [ ] PostgreSQL **14+**
- [ ] Managed service (RDS/Aurora) preferred
- [ ] Automated backups enabled
- [ ] Network access from EKS confirmed

### Redis
- [ ] Redis OSS **5+**
- [ ] Managed (ElastiCache) or in-cluster
- [ ] Network access from EKS confirmed

### ClickHouse (Critical)
- [ ] Deployment model chosen:
  - [ ] Externally managed (recommended for production)
  - [ ] In-cluster (StatefulSet)
- [ ] If in-cluster:
  - [ ] **Production:** Capacity for 3 replicas, each with **8 vCPU / 32 GB RAM** available (single-node ClickHouse is not supported for production)
  - [ ] **Dev-only:** Single node with **8 vCPU / 32 GB RAM** available (non-production proof-of-concept only)
  - [ ] SSD-backed storage
  - [ ] PersistentVolume provisioner available
- [ ] You understand ClickHouse is **not stateless**

> **For detailed production ClickHouse topology requirements (3 replicas minimum), see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#3-clickhouse-traces--analytics-required).**

---

## 6. Object Storage (Strongly Recommended)

> **For blob storage requirements and workload triggers, see [`PROD_CHECKLIST.md`](./PROD_CHECKLIST.md#4-blob-storage-strongly-recommended).**

### S3
- [ ] S3 bucket planned for LangSmith artifacts
- [ ] Bucket region matches deployment region
- [ ] IAM access model chosen:
  - [ ] IRSA (preferred)
  - [ ] Explicit credentials (discouraged)

---

## 7. Secrets Management

- [ ] Secrets **will not** be committed to git
- [ ] Secrets backend chosen:
  - [ ] AWS Secrets Manager
  - [ ] External Secrets
  - [ ] CSI driver
- [ ] Rotation strategy understood (even if manual)

---

## 8. Auth & Access Model

- [ ] Auth strategy selected:
  - [ ] Token-based
  - [ ] OIDC / SSO
- [ ] You know **who can access LangSmith**
- [ ] You know **how access is revoked**
- [ ] You are not assuming “security by obscurity”

> Pick one auth model for initial enablement. Others are out of scope.

---

## 9. Ingress (P0 Hard Gate) — ALB Only

Ingress configuration is a critical component that requires careful attention. For the P0 reference deployment, ingress is **not optional** and there are **no alternative controllers**.

**P0 Requirement:** AWS ALB via **AWS Load Balancer Controller**.  
If you are using NGINX/Traefik/Istio/API Gateway/etc., you are operating **outside the reference path**.

### Controller & Permissions
- [ ] AWS Load Balancer Controller is installed in the cluster
- [ ] Controller pods are healthy (no CrashLoopBackOff)
- [ ] Controller IAM permissions are in place (IRSA strongly preferred)

### Subnet Discovery (Common Failure)
- [ ] Public subnets are correctly tagged for ALB discovery (public ALB)
- [ ] Private subnets are correctly tagged if you plan an internal ALB
- [ ] You know which subnets ALBs will land in

### TLS & DNS
- [ ] ACM certificate exists for `langsmith.<domain>` (same region as ALB)
- [ ] You control DNS and can create records for the endpoint

### Mandatory Proof (Stop if not true)
- [ ] You have successfully provisioned a **test ALB** from Kubernetes Ingress
  - ALB created
  - target group created
  - targets become healthy
  - HTTPS works on your DNS name

If you cannot prove ALB ingress works **before** LangSmith, resolve the ingress configuration before proceeding with the LangSmith installation.

---

## 10. Operational Expectations (Read This)

Before proceeding, confirm you accept:

- [ ] You are responsible for upgrades
- [ ] You are responsible for backups
- [ ] You are responsible for incident response
- [ ] Support will assume this reference architecture when debugging

If any of these are unacceptable, **review your requirements** before proceeding, as these responsibilities are fundamental to operating a self-hosted deployment.

---

## 11. Preflight Outcome

- [ ] All required checks passed  
→ You may proceed to **Terraform deployment**.

- [ ] One or more checks failed  
→ Address them **before** continuing. Proceeding without resolving these issues will likely result in deployment challenges.

---

## Why This Checklist Exists

Every unchecked box above corresponds to common issues that have caused:
- Support escalations
- Deployment delays
- Production incidents

Completing preflight checks thoroughly significantly increases your chances of a successful deployment. While passing preflight does not guarantee success, **failing to address these checks almost guarantees challenges**.
