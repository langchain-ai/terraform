# AWS Deployment — Issues & Bugs Notes

**Author:** Richa Ranjan
**Date:** 2026-05-20

This document captures issues and bugs encountered during a first-time AWS LangSmith
deployment from a laptop using SSO credentials. Each entry includes symptom, root cause,
fix, and (where relevant) a README ask or source fix.

Two top-level sections follow:
- **Bugs** — defects in repo scripts/configs with fixes
- **Issues** — first-time-deploy gotchas with workarounds and prevention asks

---

# Bugs

Real bugs in the repo's scripts/configs — distinct from user-error issues below.

## Bug: Bastion EC2 instance create fails — root volume too small for AMI snapshot

**Discovered:** 2026-05-20

**Symptom**
```
Error: creating EC2 Instance: operation error EC2: RunInstances, ...
  api error InvalidBlockDeviceMapping: Volume of size 20GB is smaller than snapshot 'snap-...',
  expect size >= 30GB

  with module.bastion[0].aws_instance.bastion,
  on modules/bastion/main.tf line 105, in resource "aws_instance" "bastion":
```

**Root cause**
The bastion module's default root volume size is 20 GB, but the AMI in use has a 30 GB root snapshot. EC2 rejects RunInstances when the requested volume is smaller than the source snapshot.

Two places set the same too-small default:
- `modules/aws/infra/modules/bastion/variables.tf:62-65` → `default = 20`
- `modules/aws/infra/variables.tf:366` (`bastion_root_volume_size_gb`) → `default = 20`

The AMI was likely updated (e.g., AL2023 base image grew past 20 GB) but the default wasn't bumped to match.

**Impact**
`make apply` fails on the bastion EC2 instance creation when `create_bastion = true`, even after the em-dash fix from the bug above.

**Fix**
Bump both defaults to `30` (or larger — 40 GB gives operators headroom for kubectl, helm caches, logs):
```hcl
# modules/aws/infra/modules/bastion/variables.tf:62-65
variable "root_volume_size_gb" {
  type        = number
  description = "Root EBS volume size in GB"
  default     = 30
}

# modules/aws/infra/variables.tf:366
variable "bastion_root_volume_size_gb" {
  type        = number
  description = "Root EBS volume size in GB for the bastion host."
  default     = 30
}
```

Better long-term fix: parameterize against the AMI's actual snapshot size by computing it dynamically (`data.aws_ami.bastion.block_device_mappings[*].ebs.volume_size`) and taking `max(var.root_volume_size_gb, ami_snapshot_size)`. Avoids future drift if the AMI grows again.

**Workaround (until fixed)**
Set `bastion_root_volume_size_gb = 30` in `terraform.tfvars`, OR set `create_bastion = false` to skip the bastion entirely (recommended when public EKS endpoint is enabled with IP allowlist).

**README coverage**
Not warned. `modules/aws/README.md:980` documents the variable with the broken default (`20`) but gives no indication that it's smaller than the AMI snapshot or that apply will fail. The README's "Private Cluster with Bastion Host" section (lines 416-472) actively recommends `create_bastion = true` as the production path, so anyone following the docs hits this landmine. README needs either a warning + override snippet, or — better — the underlying default fixed.

---

## Bug: Bastion security group create fails — em-dash in description rejected by EC2

**Discovered:** 2026-05-20

**Symptom**
```
Error: creating Security Group (acme-prod-bastion-bastion-...): InvalidParameterValue:
  Value (Bastion host — SSM + optional SSH ingress) for parameter GroupDescription is invalid.
  Character sets beyond ASCII are not supported.

  with module.bastion[0].aws_security_group.bastion,
  on modules/bastion/main.tf line 71, in resource "aws_security_group" "bastion":
```

**Root cause**
`modules/aws/infra/modules/bastion/main.tf:73` uses an em-dash (`—`, U+2014) in the security group `description` field:
```hcl
description = "Bastion host — SSM + optional SSH ingress"
```
AWS EC2 restricts `GroupDescription` to ASCII characters. Any non-ASCII (em-dash, en-dash, curly quotes) causes the create call to 400.

**Impact**
`make apply` fails when `create_bastion = true` (the default). Users either get blocked on the bastion module or have to disable the bastion to proceed.

**Scope check — other modules**
Grep `description.*—\|description.*–` across `modules/aws/infra/modules/` surfaces em-dashes in five other places, but all are Terraform `variable` block descriptions (documentation only, not sent to AWS). The bastion security group is the only AWS-facing instance, so it's the only one that breaks apply. Worth scrubbing the rest for consistency anyway.

**Fix**
Replace the em-dash with a regular hyphen in `modules/aws/infra/modules/bastion/main.tf:73`:
```hcl
description = "Bastion host - SSM + optional SSH ingress"
```
Also audit any other security group / IAM / AWS-API-facing string fields across all modules for non-ASCII characters. A grep guard in CI would catch future regressions:
```bash
grep -rn $'[^\x00-\x7F]' modules/aws/infra/modules/ --include='*.tf'
```

A companion PR in this repo applies the one-line em-dash fix to `modules/aws/infra/modules/bastion/main.tf:73`.

**Workaround (until fixed)**
Set `create_bastion = false` in `terraform.tfvars` to skip the bastion entirely. Acceptable when EKS public endpoint is enabled with an IP allowlist — the bastion exists for private-endpoint access.

**README coverage**
Not mentioned anywhere. The em-dash failure is invisible until the operator runs `make apply` with `create_bastion = true`. Because the README's "Private Cluster with Bastion Host" section (lines 416-472) presents the bastion as the recommended path for production-grade private clusters, this bug blocks the documented happy path. README needs a warning until the source string is fixed.

---

## Bug: `manage-ssm.sh set` fails with `--output: Found invalid choice 'none'`

**Discovered:** 2026-05-20

**Symptom**
```bash
infra/scripts/manage-ssm.sh set postgres-password 'LSawsPG_54321'
aws: [ERROR]: An error occurred (ParamValidation): argument --output: Found invalid choice 'none'
```

**Root cause**
`modules/aws/infra/scripts/manage-ssm.sh:218` invokes `aws ssm put-parameter` with `--output none`. The AWS CLI does not accept `none` as an output format — valid choices are `json`, `text`, `table`, `yaml`, and `yaml-stream`. The call fails before any SSM write occurs.

```bash
# manage-ssm.sh:212-218
_aws ssm put-parameter \
  --region "$_region" \
  --name "$path" \
  --value "$val" \
  --type SecureString \
  --overwrite \
  --output none       # ← invalid
```

**Impact**
`manage-ssm.sh set <key> <value>` is unusable. Users must either work around it by calling `aws ssm put-parameter` directly, or fix the script.

**Fix**
Replace `--output none` with the standard idiom for discarding output:
```bash
  --output text >/dev/null
```
Audit the rest of the script for any other `--output none` usages and apply the same change.

**Workaround (until fixed)**
Call AWS CLI directly:
```bash
aws ssm put-parameter \
  --region us-west-2 \
  --name "/langsmith/<name_prefix>-<env>/<param-name>" \
  --value '<value>' \
  --type SecureString \
  --overwrite
```

---

# Issues

## Issue: ALB URL returns 404 — two ALBs exist, ingress rules landed on the wrong one with a mismatched Host header

**Date:** 2026-05-20

**Symptom**
After `make deploy` finishes, the URL printed in the deploy output (`http://acme-prod-alb-<id>.us-west-2.elb.amazonaws.com`) returns:
```
HTTP/1.1 404 Not Found
Server: awselb/2.0
```
All 16 pods in the `langsmith` namespace are `1/1 Running` — the application itself is healthy. Port-forward (`kubectl port-forward svc/langsmith-frontend -n langsmith 8080:80`) loads the UI fine, confirming the workload works.

**Root cause — two competing ALBs**

`kubectl describe ingress langsmith-ingress -n langsmith` reveals two AWS ALB DNS names and a Host-based rule:

| ALB | DNS | State | Why |
|---|---|---|---|
| **Terraform-provisioned** `acme-prod-alb` | `acme-prod-alb-<id>.us-west-2.elb.amazonaws.com` | Exists, no listener rules → 404 | Created by `modules/alb` in Pass 1 Terraform. Ingress annotation `alb.ingress.kubernetes.io/load-balancer-arn` references it. |
| **Controller-created** `k8s-acmeprod-<controller-id>` | `k8s-acmeprod-<controller-id>-<elb-id>.us-west-2.elb.amazonaws.com` | Has listener rules → 200 | Created by AWS Load Balancer Controller when it saw the ingress. Annotation `alb.ingress.kubernetes.io/group.name: acme-prod` triggered group-managed ALB creation. |

The chart sets *both* annotations on the ingress — `load-balancer-arn` (BYO ALB) AND `group.name` (auto-manage by group). They are mutually contradictory. The controller chose `group.name`, created its own ALB, and ignored the BYO ARN. The Terraform-provisioned ALB is orphaned (still incurring cost, no traffic).

On top of that, the ingress rule is host-restricted:
```
Host: acme-prod-alb-<id>.us-west-2.elb.amazonaws.com
Path: /
Backend: langsmith-frontend:80
```
So even though the controller-created ALB has the rules, it only matches requests with `Host: acme-prod-alb-<id>...`. Browsers send `Host: <whatever-url-they-typed>`, so:
- Hitting the orphan ALB (`acme-prod-alb-<id>...`) → wrong ALB → 404
- Hitting the working ALB (`k8s-acmeprod-<controller-id>...`) → wrong Host header → 404
- The only request that returns 200 is one with the destination = working ALB *and* Host header = `acme-prod-alb-<id>...`. Browsers can't do this without an extension.

**Diagnosis steps**
```bash
# 1. Identify ingress + show both ALB DNS names
kubectl get ingress -n langsmith
kubectl describe ingress langsmith-ingress -n langsmith

# 2. Test each ALB with explicit Host header — pinpoints which is "live"
curl -I --max-time 10 -H "Host: acme-prod-alb-<id>.us-west-2.elb.amazonaws.com" \
  http://acme-prod-alb-<id>.us-west-2.elb.amazonaws.com/   # orphan → 404
curl -I --max-time 10 -H "Host: acme-prod-alb-<id>.us-west-2.elb.amazonaws.com" \
  http://k8s-acmeprod-<controller-id>-<elb-id>.us-west-2.elb.amazonaws.com/   # working → 200

# 3. Confirm pods serve traffic — if port-forward works, app is fine; problem is ingress/ALB-layer
kubectl port-forward svc/langsmith-frontend -n langsmith 8080:80
# then: curl -I http://localhost:8080/  → 200
```

**Fix — immediate unblock**
Port-forward for any browser-based testing. No DNS or Host-header gymnastics required.
```bash
kubectl port-forward svc/langsmith-frontend -n langsmith 8080:80
# Browser: http://localhost:8080
```

**Fix — real ALB access via /etc/hosts (quick workaround)**
Browsers can't override Host headers, but the OS hosts file can alias the expected hostname to the working ALB's IP:
```bash
# Resolve the working ALB to an IP (ALBs are multi-AZ — any one IP works)
dig +short k8s-acmeprod-<controller-id>-<elb-id>.us-west-2.elb.amazonaws.com | head -1

# Append to /etc/hosts (replace <IP>)
sudo sh -c 'echo "<IP> acme-prod-alb-<id>.us-west-2.elb.amazonaws.com" >> /etc/hosts'

# Now http://acme-prod-alb-<id>.us-west-2.elb.amazonaws.com/ in browser → 200
```
Caveat: ALB IPs rotate; this needs occasional refresh. Acceptable for SA testing, not for anything shared.

**Fix — proper, requires re-deploy**
Set `langsmith_domain` in `terraform.tfvars` to a DNS name you control, point a CNAME at the controller-created ALB, and re-run `make apply`. The ingress host rule changes to your domain, and browsers will send the matching Host header naturally.

**Fix — root-cause cleanup**
Decide which ALB lifecycle you want:
1. **Controller-owned ALB** (recommended for self-hosted Helm flows). Remove the `load-balancer-arn` annotation from the chart's ingress values, and `terraform destroy -target=module.alb` (or equivalent) to remove the orphan Terraform ALB. Stops paying for an unused load balancer.
2. **Terraform-owned ALB**. Drop the `group.name` annotation so the controller respects the `load-balancer-arn` BYO directive and attaches rules to the Terraform ALB instead of creating its own.

Both annotations together is the bug — they should be mutually exclusive in the chart's values.

**Prevention / README ask**
The conflicting annotation pair is invisible to anyone running `make deploy` and reading the printed URL — they get a 404, with no signal that the deployment succeeded. Worth either:
1. Resolving the annotation conflict at the chart/Helm-values layer so only one ALB is created, or
2. Having `make deploy` (or the deploy script) print the *actual* working URL (the controller-created ALB DNS + a curl-with-Host-header sanity check), not the Terraform ALB DNS that's likely orphaned.

---

## Issue: `make apply` fails with `i/o timeout` reaching EKS API server (private IP)

**Date:** 2026-05-20

**Symptom**
After the EKS control plane and node group come up, the next batch of resources (gp3 StorageClass, AWS Load Balancer Controller, Cluster Autoscaler, Metrics Server) all fail with:
```
Error: Post "https://<cluster-id>.gr7.us-west-2.eks.amazonaws.com/apis/storage.k8s.io/v1/storageclasses":
       dial tcp 10.0.3.234:443: i/o timeout

Error: Kubernetes cluster unreachable: Get "https://<cluster-id>.gr7.us-west-2.eks.amazonaws.com/version":
       dial tcp 10.0.3.234:443: i/o timeout
```

The IP `10.0.3.x` is a private VPC address — Terraform on the laptop has no route to it.

**Root cause**
`enable_public_eks_cluster = false` is the default in `terraform.tfvars.example` (secure-by-default). The EKS API endpoint is reachable only from inside the VPC. Terraform's `kubernetes` and `helm` providers run on the operator's laptop and time out trying to reach the private endpoint.

The default assumes the operator runs Terraform from inside the VPC (bastion, CI runner, or VPN). For laptop-based SA testing that's not the case.

**Fix**
Get your current public IP, then edit `terraform.tfvars`:
```bash
curl -s https://checkip.amazonaws.com
```

```hcl
enable_public_eks_cluster = true
eks_public_access_cidrs   = ["<your-ip>/32"]
```

Then:
```bash
make plan    # shows EKS endpoint update + 4 in-cluster resources to add
make apply
```

EKS endpoint update takes a few minutes. Once flipped to public, the previously-failed resources deploy on the same apply run.

**Other approaches (heavier lifts, not chosen here)**
- Bastion host + SSM Session Manager port-forward to the EKS API
- VPN into the VPC
- Run Terraform from a CI/CD runner inside a private subnet

**Caveat for ongoing work**
If your home/office IP changes, you'll need to update `eks_public_access_cidrs` and re-apply. Setting it to a team-wide VPN egress range avoids the churn.

**Prevention / README ask**
The AWS quickstart README should call out this default explicitly for first-time laptop deploys. Either:
1. Add a pre-flight prompt in `setup-env.sh` / `quickstart.sh` to detect the operator's IP and offer to set `enable_public_eks_cluster = true` + the CIDR, or
2. Document the laptop-deploy path prominently at the top of the README (current docs at tfvars lines 156-180 are easy to skim past).

---

## Issue: `make init` fails — S3 backend bucket does not exist

**Date:** 2026-05-20

**Symptom**
```
Initializing the backend...
Error: Failed to get existing workspaces: S3 bucket "<your-tf-state-bucket>" does not exist.
The referenced S3 bucket must have been previously created.
```

**Root cause**
`modules/aws/infra/backend.tf` was configured to use an S3 remote backend (copied from `backend.tf.example` and customized with a personal bucket name), but the bucket was never created in AWS. Terraform cannot bootstrap its own state bucket — it needs the bucket to exist *before* `terraform init` runs (chicken-and-egg).

**Fix — Option A: Create the bucket via CLI**
```bash
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket <your-tf-state-bucket> \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket <your-tf-state-bucket> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**Fix — Option B: Use local state**
Delete or rename `modules/aws/infra/backend.tf`. Terraform falls back to a local `terraform.tfstate` in the infra directory. Fine for solo SA testing; not appropriate when multiple people share a deployment.

**Prevention / README ask**
The AWS README should either:
1. Document the bucket-creation prerequisite clearly (with CLI snippet) before `make init`, or
2. Default `backend.tf` to local state and treat S3 backend as opt-in via `backend.tf.example`, or
3. Ship a helper script (`infra/scripts/bootstrap-backend.sh`) that creates the bucket idempotently with versioning + encryption + public-access-block in one call.

---

## Issue: `setup-env.sh` runs cleanly but `make secrets` shows all SSM params MISSING

**Date:** 2026-05-20

**Symptom**
- `source infra/scripts/setup-env.sh` completed and printed the "Terraform environment variables set" summary.
- `TF_VAR_*` were exported in the shell (terraform plan/apply would work).
- `make secrets` (`infra/scripts/secrets-status.sh`) reported all 6 required SSM params as `✗ MISSING`.
- `aws sts get-caller-identity` returned `NoCredentials: Unable to locate credentials`.

**Root cause**
No AWS credentials were active in the shell when `setup-env.sh` was sourced. `AWS_PROFILE` was not set, and the SSO session was not loaded. Every `aws ssm put-parameter` call inside `_ssm_put_safe` silently failed (the script's design intentionally suppresses stderr so it can fall back gracefully). The script's `export "$varname"="$val"` runs unconditionally at the end of `_ssm_secret`, so the shell ended up with the values even though SSM never received them.

**Why it's silent**
`setup-env.sh:200-210` tries SSM first; if SSM fails AND a `file_name` fallback is configured, it writes to a local `.secret` file; if neither succeeds, it prints a one-line warning and moves on. Without `AWS_PROFILE` set, both paths fail and the only visible signal is at the very end.

**Fix**
```bash
export AWS_PROFILE=<your-profile>
aws sso login                       # refresh token
aws sts get-caller-identity         # verify
cd modules/aws
source infra/scripts/setup-env.sh   # backfill logic pushes existing TF_VAR_* into SSM
make secrets                        # all ✓ SET
```

The backfill path at `setup-env.sh:130-143` detects "var set in env, missing in SSM" and writes without re-prompting, so the license key + admin password don't need to be re-entered.

**Prevention / README ask**
The AWS quickstart README should add a pre-flight step:
1. `export AWS_PROFILE=<profile>` (or document persisting in `~/.zshrc`)
2. `aws sso login`
3. `aws sts get-caller-identity` — must succeed before sourcing `setup-env.sh`

Without this, the first-time experience is "everything looks fine until you check SSM."

---

## Issue: Resuming `setup-env.sh` mid-run after getting stuck on a prompt

**Date:** 2026-05-20

**Symptom**
- Sourced `setup-env.sh`, got partway through, hit the LangSmith license key prompt without a key handy.
- Aborted (Ctrl-C) before completing license + admin password + admin email.
- Came back the next day with the same terminal open. Unsure whether to re-source or start fresh.

**Root cause**
Not actually a bug — the script is idempotent and reads existing SSM values on re-run. Confusion stemmed from not knowing:
1. Whether the SSO token was still valid (it typically expires in 8–12 hours)
2. Whether stale env vars from a partial run would cause the script to skip prompts (relevant only if `LANGSMITH_LICENSE_KEY` or `LANGSMITH_ADMIN_PASSWORD` were exported)

**Fix / Resume protocol**
- If license key + admin password were **never** entered: same terminal is safe. Just refresh SSO and re-source.
- If either was entered then the script errored later: `unset LANGSMITH_LICENSE_KEY LANGSMITH_ADMIN_PASSWORD` first (or open a fresh terminal), to avoid the warning at `setup-env.sh:66-73` that skips re-prompting and skips SSM write.

```bash
aws sso login --profile <your-profile>
source infra/scripts/setup-env.sh
```

Already-stored secrets (postgres password, redis token, api key salt, jwt secret) are read silently from SSM. Only what's missing gets re-prompted.

---

## Issue: Where to obtain `LANGSMITH_LICENSE_KEY`

**Date:** 2026-05-20

**Symptom**
- `setup-env.sh` prompts for `LANGSMITH_LICENSE_KEY`. No clear guidance in the AWS README on how to get one.

**Root cause**
Only customer-facing guidance exists in the repo (`docs/content/onboarding/self-hosted-overview.md:78`): "LangSmith License Key received from your Account Executive."

**Fix**
For SA internal testing: ping the PS team in Slack — typically Michael (AWS owner) or a shared vault has test/dev license keys. There is no documented internal source in the repo today.

**Prevention / README ask**
Add an SA-internal note to the AWS README (or to an internal team doc) pointing to whichever Slack channel / 1Password vault holds test license keys.

---

## Issue: `aws configure sso` fails with `RegisterClient` `invalid_request`

**Date:** 2026-05-19

**Symptom**
```
aws: [ERROR]: An error occurred (InvalidRequestException) when calling the RegisterClient operation:

Additional error details:
error: invalid_request
error_description: Invalid request.
```
Got this immediately after entering SSO start URL, region, and scopes.

**Root cause (most common)**
The SSO region entered at the prompt must match the region where the IAM Identity Center instance is provisioned — not the region where you want to operate resources. The directory URL (`d-<id>.awsapps.com/start`) lives in one specific region.

**Other potential causes ruled out in this session**
- AWS CLI version: confirmed v2.15+ (modern, supports `sso-session`)
- Stale registration cache: ruled out (first attempt on this machine)
- Session name format: `<your-sso-session>` is valid

**Fix**
1. Sign in to AWS console with admin → IAM Identity Center → confirm the region banner.
2. Re-run `aws configure sso` using that region for the **SSO region** prompt.
3. The **default client region** can still be whatever you want to operate in (e.g. `us-west-2`).

**Successful config example**
```
aws configure sso
SSO session name: <your-sso-session>
SSO start URL: https://<directory>.awsapps.com/start
SSO region: us-east-1           # ← matches Identity Center instance region
SSO registration scopes: sso:account:access
[browser auth]
Default client Region: us-west-2  # ← where you'll deploy
CLI default output format: json
Profile name: <your-profile>
```

**Next-session reminder (not an issue, but related)**
`aws configure sso` is one-time. To resume:
```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

Terraform's AWS provider auto-picks up `AWS_PROFILE`, so no extra config needed.

---
