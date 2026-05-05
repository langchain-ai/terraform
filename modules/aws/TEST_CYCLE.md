# AWS LangSmith — Pass 1 Test Cycle

Repeatable runbook for deploying and tearing down the AWS infra layer (Pass 1 — Terraform only).
Run this before merging changes to validate everything works end-to-end.

**Scope**: Terraform infra only. Helm/Pass 2 is a separate cycle — stop after the verification
checklist below.

---

## Prerequisites

**Tools required** (all must be in PATH):
- `aws` CLI — authenticated to the target account
- `terraform` v1.0+
- `kubectl`
- `helm` v3+

**IAM permissions required** (run preflight to verify):
- EKS: create/describe/delete cluster, node groups, OIDC provider
- EC2: VPC, subnets, security groups, NAT gateway, ELB
- IAM: create/attach roles and policies
- RDS: create/delete DB instance
- ElastiCache: create/delete replication group
- S3: create/delete bucket, bucket policies
- SSM: GetParameter, PutParameter (for `source ./infra/scripts/setup-env.sh`)

---

## Bare Minimum Test Config

`aws/infra/terraform.tfvars` must include:

```hcl
tls_certificate_source       = "none"   # HTTP:80 only — no ACM/cert-manager needed
postgres_deletion_protection = false    # Required for clean terraform destroy after test
```

All other defaults are fine for testing. The current dev config uses:
- `name_prefix = "myco"`, `environment = "dev"`, `region = "us-east-2"`
- EKS: v1.31, `m5.4xlarge`, min 1 / max 10 nodes
- RDS: `db.t3.large`, 20 GB
- Redis: `cache.m6g.xlarge`

---

## Pass 1 Procedure

Run all commands from the `aws/` directory.

### Step 0 — Verify AWS credentials
```bash
aws sts get-caller-identity
```
Confirm the account ID and region match the target deployment.

### Step 1 — Preflight check
```bash
./infra/scripts/preflight.sh
```
All checks must be green before proceeding. Fix any permission errors first.

### Step 1.5 — Verify secrets status
```bash
make secrets              # verify SSM params and TF_VAR_* are set
make secrets-list         # list all SSM parameter paths
```
Run after `source ./infra/scripts/setup-env.sh` to confirm all required parameters are populated and exported before running Terraform.

### Step 2 — Set secrets and open a terraform shell
```bash
source ./infra/scripts/setup-env.sh
```
This script:
- Reads `name_prefix` and `environment` from `terraform.tfvars` to build the SSM path prefix
- Reads existing secrets from SSM Parameter Store (no prompts on re-runs)
- Prompts for new values on first run: `postgres_password`, `license_key`, `admin_password`
- Auto-generates stable secrets on first run: `redis_auth_token`, `api_key_salt`, `jwt_secret`
- Exports `TF_VAR_*` environment variables for Terraform

**Critical invariants — never violate on a live deployment:**
- `api_key_salt` is write-once: rotating it invalidates all API keys
- `jwt_secret` is write-once: rotating it invalidates all active user sessions
- `admin_password` must contain a symbol from `!#$%()+,-./:?@[\]^_{~}`

> **Must use `source`** — running `./infra/scripts/setup-env.sh` directly does not export variables
> to the calling shell.
>
> **All subsequent terraform commands MUST run in the same shell session** — exported `TF_VAR_*`
> variables do not persist across separate terminal sessions or shell invocations. If you open
> a new tab or restart your shell, re-source the script before running terraform again.

### Step 3 — Init
```bash
terraform -chdir=infra init
```
Downloads all providers and modules. Typical duration: 1–2 min.

### Step 4 — Validate
```bash
terraform -chdir=infra validate
```
Must return `Success! The configuration is valid.` — fix any errors before continuing.

### Step 5 — Plan
```bash
terraform -chdir=infra plan
```
Review the plan. Expected resource categories:
- VPC, subnets (5 private + 3 public), NAT gateway, route tables
- EKS cluster, managed node group, OIDC provider
- EBS CSI IRSA role + addon, cluster autoscaler, ALB controller, metrics-server
- gp3 StorageClass (Kubernetes)
- RDS PostgreSQL instance + subnet group + security group
- ElastiCache Redis replication group + subnet group + security group
- S3 bucket + public access block + encryption + VPC endpoint + bucket policy
- ALB + listeners + security group
- IAM roles: `langsmith_irsa_role`, `eso` (External Secrets Operator)
- Kubernetes namespace `langsmith`, K8s Secrets (`langsmith-postgres`, `langsmith-redis`)
- Helm releases: ESO, KEDA

Confirm no unexpected `destroy` or `replace` actions on existing resources.

### Step 6 — Apply
```bash
terraform -chdir=infra apply
```
Typical duration: **20–30 min** (EKS cluster provisioning takes ~15 min alone).

If apply fails partway through, it is safe to re-run — Terraform is idempotent. See the
Known Issues section for specific error patterns.

### Step 6.5 — Post-infra preflight
```bash
make preflight-post       # after apply: verify kubectl + SSM + helm values
```
Run this before starting Pass 2 (Helm). Confirms the cluster is reachable, all SSM parameters are present, and Helm values files exist.

---

## Verification Checklist

Run these after `apply` completes successfully.

### Cluster access
```bash
REGION=$(grep '^region' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
NAME_PREFIX=$(grep '^name_prefix' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
ENVIRONMENT=$(grep '^environment' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
aws eks update-kubeconfig --region "$REGION" --name "${NAME_PREFIX}-${ENVIRONMENT}-eks"
kubectl get nodes
```
Expected: 1+ nodes in `Ready` state.

### System pods
```bash
kubectl get pods -n kube-system
```
Expected `Running`: `aws-load-balancer-controller-*`, `cluster-autoscaler-*`, `coredns-*`,
`ebs-csi-controller-*`, `kube-proxy-*`, `metrics-server-*`.

### Bootstrap components (Pass 2 prerequisites)
```bash
kubectl get pods -n external-secrets   # ESO controller + cert-controller + webhook
kubectl get pods -n keda               # KEDA controller + metrics adapter + webhooks
kubectl get storageclass               # gp3 should show (default)
```

### LangSmith namespace
```bash
kubectl get all -n langsmith
kubectl get secret -n langsmith
```
Expected: namespace exists, `langsmith-postgres` and `langsmith-redis` secrets present.

### IRSA roles
```bash
terraform -chdir=infra output langsmith_irsa_role_arn
terraform -chdir=infra output | grep eso
```
Both role ARNs must be present — needed by Pass 2.

### ALB
```bash
terraform -chdir=infra output alb_dns_name
```
Expected: `<name_prefix>-<environment>-alb-<id>.<region>.elb.amazonaws.com`
(Use `terraform -chdir=infra output langsmith_url` for the full URL with protocol.)

---

## Optional Modules

Run this section **after** the main verification checklist is fully green. Each module is tested
as an incremental apply on top of the existing baseline — this mirrors how a customer would enable
them post-deployment.

For each module: uncomment the relevant variable(s) in `terraform.tfvars`, plan to confirm the
expected resources, apply, then verify.

### ALB Access Logs

```hcl
# terraform.tfvars
alb_access_logs_enabled = true
```

**Expected plan**: +2 resources — `aws_s3_bucket.access_logs`, `aws_s3_bucket_policy.access_logs`;
`aws_lb.this` updated in-place to attach the `access_logs` block.

**Verify**:
```bash
NAME_PREFIX=$(grep '^name_prefix' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
ENVIRONMENT=$(grep '^environment' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
aws s3api get-bucket-policy --bucket "${NAME_PREFIX}-${ENVIRONMENT}-alb-access-logs" \
  | grep elasticloadbalancing   # ELB delivery service principal present

# Confirm access logs are enabled on the ALB
ALB_ARN=$(terraform -chdir=infra output -raw alb_arn)
aws elbv2 describe-load-balancer-attributes --load-balancer-arn "$ALB_ARN" \
  --query 'Attributes[?Key==`access_logs.s3.enabled`].Value'   # ["true"]
```

---

### CloudTrail

Skip if the account already has an org-level or account-level trail.

```hcl
# terraform.tfvars
create_cloudtrail             = true
cloudtrail_multi_region       = true
cloudtrail_log_retention_days = 365
```

**Expected plan**: +3 resources — `aws_s3_bucket.cloudtrail`, `aws_s3_bucket_policy.cloudtrail`,
`aws_cloudtrail.this`.

**Verify**:
```bash
NAME_PREFIX=$(grep '^name_prefix' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
ENVIRONMENT=$(grep '^environment' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
aws cloudtrail get-trail-status --name "${NAME_PREFIX}-${ENVIRONMENT}-trail" \
  --query 'IsLogging'   # true
```

---

### WAF

Requires the ALB module to be enabled (`create_alb = true`) — WAF attaches to the ALB ARN.

```hcl
# terraform.tfvars
create_waf = true
```

**Expected plan**: +2 resources — `aws_wafv2_web_acl.this`, `aws_wafv2_web_acl_association.this`.

**Verify**:
```bash
REGION=$(grep '^region' infra/terraform.tfvars | sed 's/.*= *"\(.*\)".*/\1/')
ALB_ARN=$(terraform -chdir=infra output -raw alb_arn)
aws wafv2 get-web-acl-for-resource --region "$REGION" \
  --resource-arn "$ALB_ARN" \
  --query 'WebACL.Name'   # "{name_prefix}-{environment}-waf"
```

---

## Pass 2 Quick Start

After Pass 1 completes and `make preflight-post` is green, use `make quickdeploy` as a shortcut to run the full Pass 2 sequence in one command:

```bash
make quickdeploy          # init-values + deploy (interactive)
make quickdeploy-auto     # same, non-interactive (auto-approves all prompts)
```

Both targets gate on secrets being loaded (`TF_VAR_*` present) and `terraform.tfvars` existing before proceeding.

---

## Known Issues & Fixes — Pass 2 (Helm)

| Issue | Symptom | Fix |
|-------|---------|-----|
| `langsmith-ksa` SA missing after reinstall | `agent-bootstrap` job hangs indefinitely; `helm --wait` times out after 20 min even though all other pods are Running. Root cause: `langsmith-ksa` is created by the operator on first agent deploy and is NOT part of the Helm release — it does not survive namespace teardown or fresh cluster rebuilds. New agent pod revisions reference the missing SA and cannot be scheduled. | **Fixed in `deploy.sh`** — idempotently creates and annotates `langsmith-ksa` after every deploy. Manual fix: `kubectl create serviceaccount langsmith-ksa -n langsmith && kubectl annotate serviceaccount langsmith-ksa -n langsmith eks.amazonaws.com/role-arn=<irsa_arn> --overwrite` |
| Agent builder encryption key dropped on redeploy | Agent builder pods stay up but fail silently after an uninstall + reinstall cycle. Root cause: `deploy.sh` was gating the `agent_builder_encryption_key` ExternalSecret entry on the presence of `langsmith-values-agent-builder.yaml`. After reinstall the file is absent, the key is dropped, and pods can no longer decrypt. | **Fixed in `deploy.sh`** — both `agent_builder_encryption_key` and `insights_encryption_key` are now gated on SSM parameter existence rather than local file presence. |
| Insights example file enables external ClickHouse | Following the example verbatim sets `clickhouse.external.enabled: true`, replacing the in-cluster ClickHouse — wrong for internal deployments. | For internal ClickHouse, only set `config.insights.enabled: true`. Do not copy the `clickhouse.external.*` block from the example. Insights uses the same ClickHouse as the rest of the app. |

---

## Known Issues & Fixes — Pass 1 (Terraform)

| Issue | Symptom | Fix |
|-------|---------|-----|
| Precondition failed: postgres_password / redis_auth_token is required | `terraform plan` fails with "Resource precondition failed" | Re-source setup-env.sh in the SAME shell before running terraform: `source ./infra/scripts/setup-env.sh` — TF_VAR_* do not persist across shell sessions |
| Secrets Manager "secret scheduled for deletion" | `apply` fails with `InvalidRequestException: You can't create this secret because a secret with this name is already scheduled for deletion` | **No longer applicable** — `modules/secrets/` has been removed. Secrets are managed exclusively via SSM Parameter Store + ESO. If you still have a lingering Secrets Manager secret from a prior deploy, force-delete it: `aws secretsmanager delete-secret --region <region> --secret-id <name_prefix>-<environment>-langsmith --force-delete-without-recovery` |
| `setup-env.sh` keeps showing "Migrating postgres-password → SSM" on every run | Migration message on each source | The IAM user may lack `ssm:PutParameter` — the value loads from the local `.pg_password` file as a fallback; safe for testing but fix permissions for production |
| EBS CSI addon not ready when StorageClass is created | `Error: Failed to create StorageClass` | Re-run `terraform apply` — EKS addon becomes active asynchronously |
| ESO or KEDA Helm release times out | `context deadline exceeded` on k8s_bootstrap module | Uninstall the stuck release, then re-apply: `helm uninstall external-secrets -n external-secrets` |
| Node group not yet scheduled | StorageClass or pods stuck Pending | Wait 2–3 min for cluster autoscaler to provision the first node, then re-apply |
| `cluster_autoscaler` RBAC error on K8s 1.33+ | `forbidden: User "system:serviceaccount..."` | Fixed: EKS Blueprints Addons v1.23.0 + `chart_version = "9.47.0"` |
| `moved` block warnings | `Warning: Moved block still exists` | Safe to ignore — blocks kept for state migration compatibility |
| `gp2` StorageClass still default | `kubectl get sc` shows `gp2 (default)` | Patch it: `kubectl patch sc gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'` |
| IRSA trust policy error | `AssumeRoleWithWebIdentity` denied | Verify `langsmith_namespace` in tfvars matches the K8s namespace; IRSA trust is scoped to `system:serviceaccount:<namespace>:*` |
| ALB webhook not ready | `failed calling webhook "mservice.elbv2.k8s.aws": no endpoints available for service "aws-load-balancer-webhook-service"` during ESO/KEDA Helm install | The ALB controller mutating webhook intercepts Service creation but its pods aren't ready yet. **Fixed**: a `time_sleep` (30s) between the EKS module and k8s-bootstrap gives the webhook time to become available. If you still hit this on a slow cluster, re-run `terraform apply`. |
| KMS alias already exists | `AlreadyExistsException: An alias with the name alias/eks/<name>-eks already exists` | Orphaned from a prior incomplete destroy. Import it: `terraform import 'module.eks.module.eks.module.kms.aws_kms_alias.this["cluster"]' 'alias/eks/<name>-eks'` then re-apply |
| Node group `minSize > desiredSize` | `InvalidParameterException: minSize can't be greater than desiredSize` | **Fixed**: `desired_size` now defaults to `min_size` when omitted from `eks_managed_node_groups`. If using an older version, add `desired_size` to your tfvars node group config. |
| `setup-env.sh` hangs in non-interactive shell | Script blocks on `read` when stdin is not a terminal (CI, piped, redirected) | **Fixed**: script now detects non-interactive shell via `[[ -t 0 ]]` and fails fast with instructions to pre-export env vars or populate SSM directly |

---

## Teardown

```bash
# 1. Remove Helm releases managed by k8s-bootstrap (prevents stuck finalizers)
helm uninstall external-secrets -n external-secrets 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true

# 2. Destroy all infrastructure
terraform -chdir=infra destroy
```

**Before destroy, verify:**
- `postgres_deletion_protection = false` is set in `terraform.tfvars`
- No custom DNS records pointing at the ALB (they will break permanently — a new hostname is
  issued on the next deploy)

**If destroy hangs on security groups**: the ALB controller may have created extra security
group rules. Check the AWS Console → EC2 → Security Groups, find any with names containing
`myco-dev`, and delete the extra rules or groups manually, then re-run destroy.

---

## SSM Parameter Reference

Secrets stored at `/langsmith/myco-dev/`:

| Parameter | Auto-generated | Rotatable |
|-----------|---------------|-----------|
| `postgres-password` | No (prompted) | Yes, with app restart |
| `redis-auth-token` | Yes (hex-32) | Yes, with app restart |
| `langsmith-api-key-salt` | Yes (base64-32) | **Never** — invalidates all API keys |
| `langsmith-jwt-secret` | Yes (base64-32) | **Never** — invalidates all sessions |
| `langsmith-license-key` | No (prompted) | N/A |
| `langsmith-admin-password` | No (prompted) | Yes |

To inspect: `aws ssm get-parameters-by-path --path /langsmith/myco-dev/ --with-decryption`
