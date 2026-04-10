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
| **Dev** | In-cluster pod | In-cluster pod | In-cluster pod | Demo / POC |
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
│       ├── waf/            ← WAFv2 Web ACL attached to ALB (optional)
│       └── firewall/       ← AWS Network Firewall, FQDN-based egress filtering (optional)
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
│       │   ├── langsmith-values-sizing-production.yaml        ← Production sizing (multi-replica, HPA)
│       │   ├── langsmith-values-sizing-production-large.yaml ← Production large (high-volume, wider HPA)
│       │   ├── langsmith-values-sizing-dev.yaml              ← Dev sizing (single-replica, minimal)
│       │   ├── langsmith-values-agent-deploys.yaml      ← Deployments feature
│       │   ├── langsmith-values-agent-builder.yaml      ← Agent Builder
│       │   ├── langsmith-values-insights.yaml           ← ClickHouse Insights
│       │   └── langsmith-values-polly.yaml              ← Polly AI eval/monitoring
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

make init-values       # prompts: admin email; reads sizing + addons from terraform.tfvars
make deploy            # deploy LangSmith via Helm (includes ESO wiring)
```

`init-values.sh` reads `sizing_profile` and `enable_*` flags from `terraform.tfvars`, then copies the right values files from `helm/values/examples/`. On re-runs it preserves your choices and refreshes Terraform outputs.

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
sizing               = "production"   # production | production-large | dev | none
enable_agent_deploys = true
enable_agent_builder = true
enable_insights      = true
enable_polly         = true
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

## Command Glossary

All commands are run from `terraform/aws/`. Run `make help` for a quick summary.

---

### `make quickstart`

**When to use:** First time setting up a new deployment.

Runs `infra/scripts/quickstart.sh` — an interactive wizard that asks you questions (name prefix, region, TLS method, external vs in-cluster services, addons) and writes a ready-to-use `infra/terraform.tfvars` file. Saves you from editing the example file by hand.

```bash
make quickstart
```

---

### `make setup-env`

**When to use:** Before `make plan` or `make apply` on a fresh shell.

Prints the `source` command you need to run. It cannot export environment variables itself because `make` runs each target in a subshell — variables set there die when the shell exits. You must source the script directly:

```bash
source infra/scripts/setup-env.sh
```

**What `setup-env.sh` actually does:**

Builds the SSM path prefix from `terraform.tfvars`: `/langsmith/{name_prefix}-{environment}/`

For each secret it follows this priority order:
1. Already exported in the shell (`TF_VAR_*` or `LANGSMITH_*`) — use it, backfill SSM if missing
2. Exists in SSM Parameter Store — read it (no prompt)
3. Has an auto-generator — generate it (`openssl rand`), store in SSM
4. Interactive terminal — prompt you, store in SSM
5. No terminal (CI) — error with instructions to pre-export

**SSM parameters it manages (`/langsmith/{name_prefix}-{environment}/`):**

| SSM key | How it's set | Notes |
|---|---|---|
| `postgres-password` | You enter it | Terraform sets RDS with this password |
| `redis-auth-token` | Auto-generated (`openssl rand -hex 32`) | ElastiCache requires hex, not base64 |
| `langsmith-api-key-salt` | Auto-generated (`openssl rand -base64 32`) | **Never change** — invalidates all API keys |
| `langsmith-jwt-secret` | Auto-generated (`openssl rand -base64 32`) | **Never change** — invalidates all sessions |
| `langsmith-license-key` | You enter it | From your LangChain account |
| `langsmith-admin-password` | You enter it | Must contain `!#$%()+,-./:?@[\]^_{~}` |
| `deployments-encryption-key` | Auto-generated (Fernet key) | For Deployments/LangGraph Platform feature |
| `agent-builder-encryption-key` | Auto-generated (Fernet key) | For Agent Builder feature |
| `insights-encryption-key` | Auto-generated (Fernet key) | For Insights feature |
| `polly-encryption-key` | Auto-generated (Fernet key) | For Polly AI eval feature |

Fernet keys are: `openssl rand -base64 32 | tr "+/" "-_"` (URL-safe base64, as required by the LangGraph platform).

After running, you'll see a summary of all values (masked) and the SSM prefix. Terraform then reads the secrets as `TF_VAR_*` variables during `plan` / `apply`.

> **Why SSM?** Secrets are never in git or `.tfvars`. ESO reads them from SSM at runtime and syncs them into the `langsmith-config` Kubernetes Secret that the Helm chart mounts.

---

### `make init`

**When to use:** First time, or after adding/upgrading a Terraform provider or module.

Runs `terraform -chdir=infra init`. Downloads all required providers (`hashicorp/aws`, `hashicorp/kubernetes`, `hashicorp/helm`, etc.) and modules (the EKS Blueprints module, VPC module, etc.) into `infra/.terraform/`. Configures the state backend defined in `backend.tf`.

Safe to re-run at any time — it's idempotent.

---

### `make plan`

**When to use:** Before every `make apply` to review what will change.

Runs `terraform -chdir=infra plan`. Compares your `.tf` files + `terraform.tfvars` + `TF_VAR_*` env vars against the current Terraform state file. Shows a diff: what will be created, changed, or destroyed.

**Nothing is created or modified.** The plan output is the single most important thing to review before applying — especially `destroy` actions.

> Requires `TF_VAR_postgres_password`, `TF_VAR_redis_auth_token`, and other secrets to be set in the environment (via `source infra/scripts/setup-env.sh`).

---

### `make apply`

**When to use:** To provision or update infrastructure.

Runs `terraform -chdir=infra apply`. Executes the plan — prompts for confirmation (`yes`) before making changes. Provisions resources in dependency order:

```
VPC + Subnets
  → Security Groups
  → EKS Cluster (~12 min)
    → Node Groups
    → k8s-bootstrap (KEDA, cert-manager, ESO, namespace, IRSA service accounts)
  → RDS PostgreSQL (~8 min, parallel with EKS)
  → ElastiCache Redis (parallel with EKS)
  → S3 Bucket + VPC Endpoint
  → ALB + Listeners
  → SSM Parameters
```

Resources with no dependencies are created in parallel. Total time: **~20–25 minutes**.

After apply, all outputs (cluster name, ALB DNS, S3 bucket, IRSA role ARN) are printed and stored in Terraform state. `init-values.sh` reads these outputs automatically.

---

### `make kubeconfig`

**When to use:** After `make apply` to configure `kubectl`, or when switching between deployments.

Runs `infra/scripts/set-kubeconfig.sh` which calls `aws eks update-kubeconfig` with the cluster name from Terraform outputs. Merges the cluster credentials into `~/.kube/config`.

```bash
make kubeconfig
kubectl get nodes   # verify
```

---

### `make ssm`

**When to use:** To view, update, or rotate secrets after the initial deployment.

Runs `infra/scripts/manage-ssm.sh` — a full-featured SSM secret manager for the deployment. Run it without arguments for an interactive menu, or pass a subcommand directly.

```bash
make ssm                                                # interactive menu
./infra/scripts/manage-ssm.sh list                     # show all params + last-modified date
./infra/scripts/manage-ssm.sh get langsmith-license-key
./infra/scripts/manage-ssm.sh set langsmith-admin-password 'NewP@ss!'
./infra/scripts/manage-ssm.sh validate                 # check all required params exist
./infra/scripts/manage-ssm.sh diff                     # compare SSM vs K8s secret (detects drift)
./infra/scripts/manage-ssm.sh delete <key>
```

**Subcommands:**

| Subcommand | What it does |
|---|---|
| `list` | Shows all parameters under the prefix with last-modified timestamps |
| `get <key>` | Decrypts and prints a single parameter value |
| `set <key> <value>` | Updates a parameter — validates format (e.g. admin password must contain a symbol); warns on stable secrets (`api-key-salt`, `jwt-secret`) |
| `validate` | Checks all required params exist and are non-empty; reports optional params |
| `diff` | Compares SSM values vs what's in the live `langsmith-config` K8s Secret — shows mismatches and how to force an ESO resync |
| `delete <key>` | Removes a parameter — requires double confirmation for stable secrets |

> After updating a secret with `set`, ESO syncs it to Kubernetes within 1 hour. To force an immediate sync:
> ```bash
> kubectl annotate externalsecret langsmith-config -n langsmith force-sync=$(date +%s) --overwrite
> ```

---

### `make init-values`

**When to use:** After `make apply`, or any time you change `terraform.tfvars` settings (addons, sizing, domain).

Runs `helm/scripts/init-values.sh`. This script is the bridge between Pass 1 and Pass 2:

1. Reads settings from `infra/terraform.tfvars` (`name_prefix`, `tls_certificate_source`, `sizing_profile`, `enable_*` flags, `langsmith_domain`)
2. Reads live outputs from Terraform state (`bucket_name`, `langsmith_irsa_role_arn`, `alb_dns_name`, `acm_certificate_arn`)
3. Generates `helm/values/langsmith-values-overrides.yaml` — the environment-specific overlay with your hostname, IRSA role ARNs, S3 bucket, and ACM cert ARN
4. Copies addon values files from `helm/values/examples/` based on which `enable_*` flags are set:
   - `enable_deployments = true` → copies `langsmith-values-agent-deploys.yaml`
   - `enable_agent_builder = true` → copies `langsmith-values-agent-builder.yaml`
   - `enable_insights = true` → copies `langsmith-values-insights.yaml`
   - `enable_polly = true` → copies `langsmith-values-polly.yaml`
5. Copies the appropriate sizing file if `sizing_profile` is set

Re-running is safe — it refreshes Terraform outputs and preserves your admin email and existing choices.

---

### `make deploy`

**When to use:** To deploy or upgrade LangSmith after `make init-values`.

Runs `helm/scripts/deploy.sh`. This is the main Helm orchestration script. Here is the exact sequence:

**Step 1 — Kubeconfig.** Reads `cluster_name` from `terraform output` and runs `aws eks update-kubeconfig`.

**Step 2 — Preflight checks** (`preflight-check.sh`). Confirms `aws`, `kubectl`, `helm`, `terraform` are installed; validates AWS credentials with `aws sts get-caller-identity`; verifies `kubectl` can reach the cluster; adds the `langchain` Helm repo if missing.

**Step 3 — ESO sync** (`apply-eso.sh`). Applies the `ClusterSecretStore` (points ESO at SSM in your region) and the `ExternalSecret` (defines which SSM paths map to which K8s secret keys). Dynamically includes optional encryption keys only if they already exist in SSM — so addon keys are only synced when the addon is enabled. Waits 60s for the sync to complete.

**Step 4 — Read feature flags.** Reads `enable_deployments`, `enable_agent_builder`, `enable_insights`, `enable_polly` from `terraform.tfvars`. Validates addon dependencies (agent_builder and polly require deployments).

**Step 5 — Build values chain.** Each values file is gated: it's included only if the corresponding `enable_*` flag is `true` AND the file exists. Files are added in this order (last wins):
```
-f langsmith-values.yaml                      (base — always)
-f langsmith-values-overrides.yaml            (your env — always)
-f langsmith-values-agent-deploys.yaml        (enable_deployments = true)
-f langsmith-values-agent-builder.yaml        (enable_agent_builder = true)
-f langsmith-values-insights.yaml             (enable_insights = true)
-f langsmith-values-polly.yaml                (enable_polly = true)
-f langsmith-values-sizing-{profile}.yaml     (if sizing_profile != default, loaded LAST)
```
The sizing file is always loaded last so it can override replicas/resources set by addon files.

**Step 6 — Pre-deploy hostname check.** If the ingress already exists and `langsmith_domain` is not set, compares `config.hostname` in the overrides file against the live ALB hostname. Auto-updates it if stale (prevents agent deployments getting stuck in `DEPLOYING` state with the wrong endpoint URL).

**Step 7 — Broken release recovery.** Checks the current Helm release status. If `pending-upgrade` (left by a Ctrl+C'd upgrade), rolls back automatically. If `failed` (common after a first deploy timeout), logs a warning and proceeds — Helm upgrade works fine on a failed release.

**Step 8 — Helm upgrade.** Runs `helm upgrade --install` with `--server-side=false`. Server-side apply (Helm 3.14+ default) conflicts with the AWS Load Balancer Controller over ownership of `ingress.spec.rules` — client-side apply avoids this. Does **not** use `--wait` because the post-install bootstrap job can take 10+ minutes while agent pods spin up on new nodes.

**Step 9 — Core readiness.** Polls each core deployment with `kubectl rollout status --timeout=5m`:
- `langsmith-frontend`, `langsmith-backend`, `langsmith-platform-backend`, `langsmith-ingest-queue`, `langsmith-queue`
- Plus `langsmith-host-backend`, `langsmith-listener`, `langsmith-operator` if Deployments is enabled

**Step 10 — IRSA annotation for `langsmith-ksa`.** The `langsmith-ksa` service account is created by the operator at runtime (not part of the Helm release). It's used by all operator-spawned agent deployment pods. After every deploy, `deploy.sh` ensures this SA exists and carries the IRSA role ARN annotation — without it, new agent pod revisions can't access S3/SSM and the bootstrap job hangs.

**Step 11 — Frontend restart.** Restarts the frontend deployment to pick up the latest ConfigMap. Then prints the ALB hostname and port-forward instructions.

---

### `make apply-eso`

**When to use:** When SSM secrets change but you don't need to redeploy Helm.

Runs `helm/scripts/apply-eso.sh`. Re-applies just the ESO `ClusterSecretStore` and `ExternalSecret` resources and waits for the sync to complete (60s timeout). Useful for rotating credentials (license key, admin password) without triggering a full Helm upgrade.

**What it creates/updates in Kubernetes:**

1. `ClusterSecretStore langsmith-ssm` — a cluster-wide ESO provider pointing at AWS SSM Parameter Store in your region. Uses the IRSA role on the ESO pod for authentication.

2. `ExternalSecret langsmith-config` (in the langsmith namespace) — maps SSM paths to K8s secret keys:

   | SSM path | K8s secret key |
   |---|---|
   | `.../langsmith-license-key` | `langsmith_license_key` |
   | `.../langsmith-api-key-salt` | `api_key_salt` |
   | `.../langsmith-jwt-secret` | `jwt_secret` |
   | `.../langsmith-admin-password` | `initial_org_admin_password` |
   | `.../agent-builder-encryption-key` | `agent_builder_encryption_key` *(only if key exists in SSM)* |
   | `.../insights-encryption-key` | `insights_encryption_key` *(only if key exists in SSM)* |
   | `.../deployments-encryption-key` | `deployments_encryption_key` *(only if key exists in SSM)* |
   | `.../polly-encryption-key` | `polly_encryption_key` *(only if key exists in SSM)* |

The optional keys are dynamically included — `apply-eso.sh` probes SSM for each one and only adds it to the ExternalSecret if it exists. This prevents ESO from failing to sync because a disabled addon's key isn't in SSM yet.

---

### `make status`

**When to use:** At any point to check where you are in the deployment process.

Runs `infra/scripts/status.sh`. Works through 10 checks in sequence and tells you exactly what to run next. The first failing check sets the "Next Step" recommendation at the end.

```bash
make status          # full check
make status-quick    # skip SSM + K8s queries (faster, for quick credential checks)
```

**The 10 sections it checks:**

| # | Check | What it looks at |
|---|---|---|
| 1 | **terraform.tfvars** | File exists; `name_prefix`, `environment`, `region` are filled in |
| 2 | **Environment Variables** | All `TF_VAR_*` and `LANGSMITH_*` secrets are exported in your shell |
| 3 | **AWS Credentials** | `aws sts get-caller-identity` succeeds — prints account ID and ARN |
| 4 | **SSM Parameters** | All 6 required params exist; shows which optional addon keys are present |
| 5 | **Terraform Infra** | `terraform output` returns outputs — confirms `apply` has run; prints cluster name, ALB, bucket, IRSA role |
| 6 | **Kubeconfig** | `kubectl` context matches the cluster name; can reach the API server |
| 7 | **Helm Values** | `langsmith-values-overrides.yaml` exists; hostname is populated; addon files present |
| 8 | **Kubernetes Resources** | Namespace exists; ESO `ClusterSecretStore` and `ExternalSecret` are deployed and synced; `langsmith-config` secret exists |
| 9 | **Helm Release** | Release status (`deployed`, `failed`, `pending-upgrade`); pod count |
| 10 | **Terraform Helm App** | `app/` Terraform module state (alternative Pass 2 path only) |

---

### `make uninstall`

**When to use:** To remove the LangSmith Helm release (keeps infrastructure intact).

Runs `helm/scripts/uninstall.sh`. Uninstalls the `langsmith` Helm release and cleans up associated Kubernetes resources (ESO objects, service accounts). Does **not** destroy Terraform infrastructure (VPC, EKS, RDS, Redis, S3).

---

### `make init-app` / `make plan-app` / `make apply-app` / `make destroy-app`

**When to use:** Pass 2 Option B — managing the Helm deploy via Terraform instead of scripts.

These targets use the `app/` Terraform module which manages the ESO resources and `helm_release` resource inside Terraform state.

- `make init-app` — pulls live Terraform outputs from `infra/` into `app/infra.auto.tfvars.json`
- `make plan-app` — runs `init-app` then `terraform plan` in `app/`
- `make apply-app` — applies the Helm release via Terraform
- `make destroy-app` — destroys just the Helm release (keeps infra)

> Requires `make init-values` first — the app module reads YAML values files from `helm/values/`.

---

### `make deploy-all`

**When to use:** Single-command full deploy (infra already initialized).

Runs: `make apply` → `make init-values` → `make deploy` in sequence. Convenient for `terraform apply` + immediate Helm upgrade in one shot.

---

## Supporting Scripts

These scripts are not exposed as `make` targets but are used internally by the scripts above.

### `infra/scripts/_common.sh`

Shared library sourced by every script. Provides:
- `_parse_tfvar <key>` — extracts a value from `terraform.tfvars` using sed
- `_tfvar_is_true <key>` — returns 0 if a variable is set to `true` in tfvars
- `INFRA_DIR` — absolute path to `infra/`, resolved from the sourcing script's location
- Terminal color helpers: `_green`, `_red`, `_yellow`, `_bold`
- Status output helpers: `pass`, `fail`, `warn`, `skip`, `info`, `action`, `header` (used by `status.sh`)

### `helm/scripts/preflight-check.sh`

Called at the start of every `deploy.sh` run. Checks:
1. Required binaries exist: `aws`, `kubectl`, `helm`, `terraform`
2. AWS credentials work: `aws sts get-caller-identity`
3. Cluster is reachable: `kubectl cluster-info --request-timeout=5s`
4. `langchain` Helm repo is registered (adds it if missing, then updates)

Exits non-zero on any failure so `deploy.sh` aborts before touching the cluster.

### `infra/scripts/set-kubeconfig.sh`

Called by `make kubeconfig`. Reads `cluster_name` from `terraform output` and runs:
```bash
aws eks update-kubeconfig --name <cluster_name> --region <region>
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
| `eks_cluster_enabled_log_types` | `["api", "audit", ...]` | no | EKS control plane log types (CloudWatch) |
| `eks_addons` | `{}` | no | EKS managed add-on configurations |
| `create_langsmith_irsa_role` | `true` | no | Create IRSA role for LangSmith pods (S3 access) |
| `postgres_source` | `external` | no | `external` (RDS) or `in-cluster` (Helm) |
| `postgres_instance_type` | `db.t3.large` | no | RDS instance class |
| `postgres_storage_gb` | `10` | no | Initial RDS storage in GB |
| `postgres_max_storage_gb` | `100` | no | Maximum RDS storage in GB (autoscaling) |
| `postgres_username` | `langsmith` | no | RDS database username |
| `postgres_engine_version` | `16` | no | PostgreSQL engine version for RDS |
| `postgres_password` | `""` | when external | RDS password — use `TF_VAR_postgres_password` |
| `postgres_iam_database_authentication_enabled` | `true` | no | Enable IAM database authentication on RDS |
| `postgres_deletion_protection` | `true` | no | Enable deletion protection on RDS |
| `postgres_backup_retention_period` | `7` | no | Days to retain automated RDS backups (0 = disabled) |
| `redis_source` | `external` | no | `external` (ElastiCache) or `in-cluster` (Helm) |
| `redis_instance_type` | `cache.m6g.xlarge` | no | ElastiCache node type |
| `redis_auth_token` | `""` | when external | ElastiCache auth token (min 16 chars) — use `TF_VAR_redis_auth_token` |
| `s3_ttl_enabled` | `true` | no | Enable S3 lifecycle rules for trace TTL |
| `s3_ttl_short_days` | `14` | no | TTL for `ttl_s/` prefix in days |
| `s3_ttl_long_days` | `400` | no | TTL for `ttl_l/` prefix in days |
| `s3_kms_key_arn` | `""` | no | KMS CMK ARN for S3 encryption (empty = SSE-S3) |
| `s3_versioning_enabled` | `false` | no | Enable S3 bucket versioning |
| `tls_certificate_source` | `acm` | no | `acm`, `letsencrypt`, or `none` |
| `acm_certificate_arn` | `""` | when acm | ACM certificate ARN |
| `letsencrypt_email` | `""` | when letsencrypt | Email for Let's Encrypt |
| `langsmith_domain` | `""` | no | Custom hostname (empty = use ALB DNS name) |
| `langsmith_namespace` | `langsmith` | no | Kubernetes namespace for LangSmith |
| `clickhouse_source` | `in-cluster` | no | `in-cluster` or `external` |
| `alb_scheme` | `internet-facing` | no | ALB scheme: `internet-facing` or `internal` |
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
| `create_firewall` | `false` | no | Deploy AWS Network Firewall for FQDN-based egress filtering. Requires `create_vpc = true`. Cost: ~$0.395/hr/endpoint + $0.065/GB. |
| `firewall_allowed_fqdns` | `["beacon.langchain.com"]` | no | Domains allowed for outbound internet traffic when `create_firewall = true`. Matched against TLS SNI (HTTPS) and HTTP Host header. All other destinations are dropped. |
| `firewall_subnet_cidr` | `"10.0.64.0/21"` | no | CIDR for the firewall subnet. Must not overlap with private (10.0.0.0/21–10.0.32.0/21) or public (10.0.40.0/21–10.0.56.0/21) subnets. |
| `sizing_profile` | `default` | no | Helm sizing: `production`, `production-large`, `dev`, `minimum`, `default` |
| `enable_deployments` | `false` | no | Enable LangGraph Platform (listener, operator, host-backend) |
| `enable_agent_builder` | `false` | no | Enable Agent Builder (requires `enable_deployments`) |
| `enable_insights` | `false` | no | Enable ClickHouse-backed analytics |
| `enable_polly` | `false` | no | Enable Polly AI eval/monitoring (requires `enable_deployments`) |
| `enable_usage_telemetry` | `false` | no | Enable extended usage telemetry reporting |
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
