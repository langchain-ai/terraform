---
title: "Troubleshooting Guide"
description: "Common issues, diagnostics, and fixes for LangSmith deployments on AWS."
provider: "aws"
type: "troubleshooting"
---

# LangSmith on AWS — Troubleshooting Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before upgrading for breaking changes and required variable updates.

Run `aws eks update-kubeconfig --region <region> --name <cluster-name>` before using any `kubectl` commands.

---

## Known Issues

### Issue #1 — EKS node group creation fails: CREATE_FAILED

**Symptom:**
```
Error: waiting for EKS Node Group creation: unexpected state 'CREATE_FAILED'
```

**Cause:** The EKS cluster control plane is not yet fully active when the node group creation begins. This can happen if a previous apply was interrupted.

**Fix:**

```bash
# Wait for cluster to become active
aws eks wait cluster-active --name <cluster-name> --region <region>

# Check node group error details
aws eks describe-nodegroup \
  --cluster-name <cluster-name> \
  --nodegroup-name <nodegroup-name> \
  --region <region> \
  --query "nodegroup.health"

# Re-apply
terraform apply -var-file=terraform.tfvars
```

---

### Issue #2 — kubectl fails: You must be logged in to the server

**Symptom:** All `kubectl` commands fail with:
```
error: You must be logged in to the server (Unauthorized)
```

**Cause:** The kubeconfig is stale, the AWS credentials used to authenticate differ from those that created the cluster, or the token has expired.

**Fix:**

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl cluster-info

# Verify the identity being used
aws sts get-caller-identity
```

If the cluster was created with a different IAM role, grant `aws-auth` ConfigMap access:

```bash
kubectl edit configmap aws-auth -n kube-system
# Add your IAM user/role under mapUsers or mapRoles
```

---

### Issue #3 — ALB not created after Helm install

**Symptom:** `kubectl get ingress -n langsmith` shows no ADDRESS after several minutes.

**Cause:** AWS Load Balancer Controller is not running or lacks the required IRSA permissions, the Terraform-provisioned ALB is not being referenced correctly, or `alb_scheme = "internal"` is set (internal ALBs won't have a public address — see Issue #14).

**Fix:**

```bash
kubectl get pods -n kube-system | grep aws-load-balancer
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml | grep eks.amazonaws.com
```

Verify the ALB provisioned by Terraform is healthy:

```bash
terraform output alb_dns_name
aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='<alb-dns-name>'].State"
```

---

### Issue #4 — RDS connection refused from EKS pods

**Symptom:** Backend logs show `connection refused` or `timeout` for the RDS endpoint.

**Cause:** The RDS security group does not allow inbound TCP 5432 from the EKS node or cluster security group.

**Fix:**

```bash
# Get EKS cluster security group ID
aws eks describe-cluster --name <cluster-name> \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId"

# Get RDS security groups
aws rds describe-db-instances \
  --db-instance-identifier <db-id> \
  --query "DBInstances[0].VpcSecurityGroups"

# Verify inbound rule exists for TCP 5432 from EKS SG
aws ec2 describe-security-group-rules \
  --filter "Name=group-id,Values=<rds-sg-id>"
```

The Terraform `postgres` module sets up the correct security group automatically. If the rule is missing, re-apply the postgres module:

```bash
terraform apply -var-file=terraform.tfvars -target=module.postgres
```

---

### Issue #5 — S3 access denied from pods (IRSA not configured)

**Symptom:** Backend logs show `AccessDenied` when reading or writing to S3.

**Cause:** IRSA role annotation is missing from the LangSmith service account, or the S3 VPC Gateway Endpoint is not routing correctly.

**Fix:**

```bash
# Check IRSA annotation
kubectl get sa langsmith -n langsmith -o yaml | grep eks.amazonaws.com

# Verify VPC endpoint exists
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.<region>.s3" \
  --query "VpcEndpoints[].State"

# Test S3 access from a pod
kubectl run s3-test --rm -it --image=amazon/aws-cli -n langsmith -- \
  s3 ls s3://<bucket-name>
```

If the IRSA annotation is missing, verify the `create_langsmith_irsa_role = true` in `terraform.tfvars` and that the service account name in the Helm values matches `langsmith`.

---

### Issue #6 — ElastiCache Redis connection timeout

**Symptom:** Pods cannot connect to Redis. Logs show `dial tcp: i/o timeout`.

**Cause:** ElastiCache security group does not allow inbound TCP 6379 from the EKS node security group.

**Fix:**

```bash
# Get ElastiCache security groups
aws elasticache describe-cache-clusters \
  --cache-cluster-id <cluster-id> \
  --query "CacheClusters[0].SecurityGroups"

# Test connectivity from a pod
kubectl run redis-test --rm -it --image=redis:7 -n langsmith -- \
  redis-cli -h <elasticache-endpoint> -a <auth-token> ping
```

---

### Issue #7 — EKS nodes not autoscaling

**Symptom:** Pods remain `Pending`. Node count does not increase.

**Cause:** Cluster Autoscaler lacks IAM permissions, is targeting the wrong Auto Scaling Group, or `min_size = max_size` on the node group.

**Fix:**

```bash
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50

# Check ASG tags required by Cluster Autoscaler
aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[].Key, 'k8s.io/cluster-autoscaler/<cluster-name>')].[AutoScalingGroupName]" \
  --output table
```

---

### Issue #8 — cert-manager fails to issue Let's Encrypt certificate

**Symptom:** `kubectl get certificate -n langsmith` shows `READY=False`. HTTP01 challenge failing.

**Cause:** The ALB is not forwarding port 80 to the cert-manager solver pod, or the DNS record for the domain does not point to the ALB.

**Fix:**

```bash
kubectl describe certificate <cert-name> -n langsmith
kubectl get challenges -n langsmith

# Check ALB listener for port 80
aws elbv2 describe-listeners --load-balancer-arn <alb-arn>

# Verify DNS
dig +short <your-langsmith-domain>
# Expected: CNAME to ALB DNS name
```

---

### Issue #9 — postgres_deletion_protection blocks terraform destroy

**Symptom:**
```
Error: deleting RDS DB Instance: InvalidParameterCombination:
Cannot delete, DeletionProtection is enabled.
```

**Fix:** Disable deletion protection in `terraform.tfvars`, apply, then destroy:

```hcl
postgres_deletion_protection = false
```

```bash
terraform apply -var-file=terraform.tfvars
terraform destroy
```

---

### Issue #10 — ESO fails to sync: langsmith-config secret missing

**Symptom:** Pods stuck in `CreateContainerConfigError`. No `langsmith-config` K8s secret exists:
```
kubectl get secret langsmith-config -n langsmith
# Error from server (NotFound): secrets "langsmith-config" not found
```

**Cause:** ESO sync is all-or-nothing. If **any single** SSM parameter referenced by the ExternalSecret is missing, ESO refuses to create the K8s secret — all pods fail, not just the feature that needs the missing param.

**Fix:**

```bash
# Check ExternalSecret status
kubectl get externalsecret langsmith-config -n langsmith
kubectl describe externalsecret langsmith-config -n langsmith

# Validate all required SSM parameters exist
./infra/scripts/manage-ssm.sh validate

# If params are missing, re-run setup-env.sh (from aws/ directory)
source ./infra/scripts/setup-env.sh

# Re-apply ESO resources
./helm/scripts/apply-eso.sh
```

The `describe` output shows which specific `remoteRef.key` failed — match it against the SSM prefix (`/langsmith/{name_prefix}-{environment}/`).

---

### Issue #11 — SSM parameter prefix mismatch

**Symptom:** `manage-ssm.sh validate` passes, but ESO still can't sync. Or `setup-env.sh` wrote params under a different prefix than ESO expects.

**Cause:** The SSM prefix is derived from `name_prefix` and `environment` in `terraform.tfvars`. If these changed after initial setup, the old params live under the old prefix and ESO looks under the new one.

**Fix:**

```bash
# Check what prefix ESO is using
kubectl get externalsecret langsmith-config -n langsmith -o yaml | grep 'key:'

# List what's actually in SSM
./infra/scripts/manage-ssm.sh list

# If prefixes diverged, migrate params
./infra/scripts/migrate-ssm.sh
```

**Prevention:** Never change `name_prefix` or `environment` on an existing deployment.

---

### Issue #12 — Postgres password rejected by Terraform validation

**Symptom:**
```
Error: Invalid value for variable "postgres_password"
RDS master password must not contain '/', '@', '"', single quotes, or spaces.
```

**Cause:** The password contains characters that RDS does not allow in the master password.

**Fix:** Re-generate the password without restricted characters:

```bash
# If using setup-env.sh, it auto-generates a compliant password.
# To manually update an existing password in SSM:
./infra/scripts/manage-ssm.sh set postgres-password "$(openssl rand -base64 24 | tr -d '/+= ')"
```

Then re-export and apply:
```bash
source ./infra/scripts/setup-env.sh
terraform apply -var-file=terraform.tfvars
```

---

### Issue #13 — Private EKS cluster unreachable from outside the VPC

**Symptom:** `kubectl` and `terraform apply` timeout when `enable_public_eks_cluster = false`. During Pass 1 the in-cluster resources (gp3 StorageClass, AWS Load Balancer Controller, Cluster Autoscaler, Metrics Server) all fail together:
```
Error: Post "https://<cluster-id>.gr7.<region>.eks.amazonaws.com/apis/storage.k8s.io/v1/storageclasses":
       dial tcp 10.0.3.234:443: i/o timeout

Error: Kubernetes cluster unreachable: Get "https://<cluster-id>.gr7.<region>.eks.amazonaws.com/version":
       dial tcp 10.0.3.234:443: i/o timeout
```

**Cause:** The EKS API endpoint is private-only. The `kubernetes` and `helm` providers run wherever Terraform runs, so the address in the error is a private VPC IP with no route from outside. You must run commands from within the VPC — via the bastion host or a VPN connection — or expose the endpoint.

**Fix — from inside the VPC:**

```bash
# If bastion was provisioned (create_bastion = true):
aws ssm start-session --target <bastion-instance-id>

# From the bastion, update kubeconfig and proceed normally:
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl get nodes
```

If the bastion wasn't provisioned, set `create_bastion = true` and re-apply.

**Fix — from a workstation outside the VPC:** expose the API endpoint and restrict it to your address:

```bash
curl -s https://checkip.amazonaws.com
```

```hcl
# terraform.tfvars
enable_public_eks_cluster = true
eks_public_access_cidrs   = ["<your-ip>/32"]
```

```bash
make plan    # shows the endpoint update plus the in-cluster resources still to add
make apply
```

The endpoint update takes a few minutes, after which the previously failed resources converge on the same apply run. Note the allowlist has to be updated whenever your address changes — point it at a stable VPN egress range for anything beyond one-off testing, and never widen it to `0.0.0.0/0`.

---

### Issue #14 — ALB has no public address (internal scheme)

**Symptom:** `kubectl get ingress -n langsmith` shows an ADDRESS, but the hostname resolves only within the VPC. Browser access from outside the network fails.

**Cause:** `alb_scheme = "internal"` was set in `terraform.tfvars`. Internal ALBs are only reachable from within the VPC (via VPN, peering, or PrivateLink).

**Fix:** This is intentional for private deployments. To make it publicly reachable:

```hcl
# terraform.tfvars
alb_scheme = "internet-facing"
```

```bash
terraform apply -var-file=terraform.tfvars
# Then redeploy Helm to pick up the new ALB
```

---

### Issue #15 — ALB hostname changed after ingress recreation

**Symptom:** LangSmith URL stops working. Agent deployments stuck in DEPLOYING state.
DNS records or bookmarks point to an old ALB hostname that no longer resolves.

**Cause:** Deleting the Kubernetes ingress (via `helm uninstall`, `kubectl delete ingress`,
or namespace deletion) deprovisions the ALB. When the ingress is recreated, a new ALB with
a different hostname is issued. The `config.deployment.url` in the Helm values still points
to the old hostname, so the operator's health checks fail and deployments stay stuck.

This also happens if the ALB controller creates a new ALB instead of reusing the
existing one. The `group.name` annotation is what keeps the controller reusing a
single stable ALB across ingress reconciliations. There is no supported annotation
for binding an ingress to a pre-provisioned ALB — `load-balancer-arn` is not a real
controller annotation, it was silently ignored, and setting it produced a second,
orphaned ALB. `init-values.sh` no longer emits it.

**Prevention:**
- Ensure the `group.name` annotation is set (`init-values.sh` does this automatically)
- Never delete the ingress unless you plan to update all hostname-dependent config
- Avoid `helm rollback` without `--server-side=false` — the ingress SSA conflict
  can trigger a delete/recreate cycle

**Fix:**
```bash
# 1. Check what hostname the ingress currently has
kubectl get ingress langsmith-ingress -n langsmith \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# 2. Check what Terraform expects
terraform output alb_dns_name

# 3. If they differ, re-run init-values.sh to refresh the hostname and redeploy
make init-values
make deploy
```

**On deployments created before `load-balancer-arn` was removed:** the printed URL
returns `404 Not Found` from `awselb/2.0` while every pod is `Running`.
`kubectl describe ingress langsmith-ingress -n langsmith` shows two ALB hostnames —
the Terraform-provisioned one carrying the host rule but no listener rules, and the
controller-created `k8s-<group>-<id>` one carrying the listener rules. Confirm the
workload is healthy, then repoint at the controller-owned ALB and delete the orphan.

```bash
# App is fine if this serves the UI — the problem is at the ALB/ingress layer
kubectl port-forward svc/langsmith-frontend -n langsmith 8080:80

# Identify which ALB actually has the rules
curl -I --max-time 10 -H "Host: <ingress-host-rule>" http://<alb-dns-name>/

make init-values && make deploy
```

---

### Issue #16 — Node group scaling changes not applied by terraform

**Symptom:** Changing `min_size` or `max_size` in `terraform.tfvars` shows
"No changes" on `terraform plan`.

**Cause:** The ASG was changed out-of-band (e.g. via AWS CLI, console, or
cluster autoscaler) and the Terraform state already reflects the new values.
The community EKS module ignores `desired_size` changes (so the autoscaler can
manage it), but `min_size` and `max_size` should propagate normally.

**Fix:**
```bash
# Refresh state to pull real ASG values, then plan
terraform refresh
terraform plan

# If you need an immediate change, use the AWS CLI directly
aws eks update-nodegroup-config \
  --cluster-name <cluster> \
  --nodegroup-name <nodegroup> \
  --scaling-config minSize=3,maxSize=8,desiredSize=5 \
  --region <region>
```

---

### Issue #17 — aws configure sso fails: RegisterClient invalid_request

**Symptom:** The command fails immediately after the SSO start URL, region, and scopes are entered:
```
aws: [ERROR]: An error occurred (InvalidRequestException) when calling the RegisterClient operation:

error: invalid_request
error_description: Invalid request.
```

**Cause:** The **SSO region** prompt has to be answered with the region where the IAM Identity Center instance is provisioned, not the region you intend to deploy into. The directory (`d-<id>.awsapps.com/start`) lives in exactly one region.

**Fix:** Confirm the region in the AWS console under IAM Identity Center, then re-run `aws configure sso`:

```
SSO session name:          <your-sso-session>
SSO start URL:             https://<directory>.awsapps.com/start
SSO region:                us-east-1        # where Identity Center lives
SSO registration scopes:   sso:account:access
Default client Region:     us-west-2        # where you deploy
CLI default output format: json
Profile name:              <your-profile>
```

This is a one-time setup. Each session afterwards needs only `aws sso login --profile <your-profile>` and `export AWS_PROFILE=<your-profile>`. The Authenticate section of the [README](README.md#authenticate) covers the full SSO flow.

---

### Issue #18 — setup-env.sh completes but every SSM parameter is MISSING

**Symptom:** `source infra/scripts/setup-env.sh` prints its usual summary and `TF_VAR_*` are exported, but `make secrets` reports all required SSM parameters as `MISSING`, and:
```
aws sts get-caller-identity
# Unable to locate credentials
```

**Cause:** No AWS credentials were active in the shell when the script was sourced. `setup-env.sh` suppresses AWS CLI errors so it can fall back to local `.secret` files, and it exports each value into the shell whether or not the SSM write succeeded. The result is a shell that looks correctly configured while SSM is empty.

**Fix:**

```bash
export AWS_PROFILE=<your-profile>
aws sso login                        # or aws configure, for key-based accounts
aws sts get-caller-identity          # must succeed before continuing

source ./infra/scripts/setup-env.sh  # backfills TF_VAR_* already in the shell into SSM
make secrets                         # all SET
```

The backfill path detects "set in the environment, missing in SSM" and writes without re-prompting, so the license key and admin password do not have to be entered again.

**Prevention:** Run `make preflight` before `make setup-env` — it fails fast when `aws sts get-caller-identity` returns nothing.

---

### Issue #19 — Resuming setup-env.sh after aborting at a prompt

**Symptom:** The script was interrupted partway through, commonly at the `LANGSMITH_LICENSE_KEY` prompt. It is unclear whether re-sourcing in the same shell is safe.

**Cause:** Not a defect — the script is idempotent and reads existing values back from SSM. The ambiguity is that when `LANGSMITH_LICENSE_KEY` or `LANGSMITH_ADMIN_PASSWORD` are already exported, the script skips both the prompt and the SSM write for them.

**Fix:** SSO credentials are short-lived, so refresh first. If neither secret was entered before the abort, the same shell is fine:

```bash
aws sso login --profile <your-profile>
source ./infra/scripts/setup-env.sh
```

If either was entered and the script failed afterwards, clear them first (or open a new shell) so they are re-prompted and written to SSM:

```bash
unset LANGSMITH_LICENSE_KEY LANGSMITH_ADMIN_PASSWORD
```

Secrets already in SSM (postgres password, redis token, api key salt, jwt secret) are read back silently; only what is missing is prompted for.

---

### Issue #20 — manage-ssm.sh set fails: invalid choice 'none'

**Symptom:**
```
./infra/scripts/manage-ssm.sh set postgres-password '<value>'
aws: [ERROR]: An error occurred (ParamValidation): argument --output: Found invalid choice 'none'
```

**Cause:** The script passes `--output none` to `aws ssm put-parameter`. The AWS CLI accepts `json`, `text`, `table`, `yaml`, and `yaml-stream` — `none` is not valid, so the call fails before anything is written to SSM.

**Fix:** Write the parameter with the CLI directly, then verify:

```bash
aws ssm put-parameter \
  --region <region> \
  --name "/langsmith/<name_prefix>-<environment>/<param-name>" \
  --value '<value>' \
  --type SecureString \
  --overwrite

./infra/scripts/manage-ssm.sh list
```

In the script itself, `--output none` should be replaced with `--output text >/dev/null`.

---

### Issue #21 — make init fails: S3 backend bucket does not exist

**Symptom:**
```
Initializing the backend...
Error: Failed to get existing workspaces: S3 bucket "<your-tf-state-bucket>" does not exist.
The referenced S3 bucket must have been previously created.
```

**Cause:** `infra/backend.tf` was populated from `backend.tf.example` with a bucket that does not exist yet. Terraform cannot bootstrap its own state bucket — the bucket has to exist before `terraform init` runs. The shipped `backend.tf` uses local state, so this only appears once you opt into the S3 backend.

**Fix — create the bucket first** (recommended whenever more than one person applies against the deployment):

```bash
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region <region> \
  --create-bucket-configuration LocationConstraint=<region>   # omit this line in us-east-1

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

**Fix — fall back to local state:** remove or rename `infra/backend.tf`. Terraform then writes `terraform.tfstate` into `infra/`. Acceptable for single-operator testing only, since the state file is not shared, locked, or versioned.

---

### Issue #22 — Bastion instance create fails: root volume smaller than AMI snapshot

**Symptom:**
```
Error: creating EC2 Instance: operation error EC2: RunInstances, ...
  api error InvalidBlockDeviceMapping: Volume of size 20GB is smaller than snapshot 'snap-...',
  expect size >= 30GB

  with module.bastion[0].aws_instance.bastion,
```

**Cause:** The bastion root volume defaults to 20 GB (`bastion_root_volume_size_gb` in `infra/variables.tf`, `root_volume_size_gb` in `infra/modules/bastion/variables.tf`) while the AMI in use has a 30 GB root snapshot. EC2 rejects `RunInstances` when the requested volume is smaller than the source snapshot.

**Fix:** Override the size in `terraform.tfvars` and re-apply:

```hcl
bastion_root_volume_size_gb = 30   # 40 leaves headroom for kubectl and helm caches, and logs
```

If the bastion is not needed — for example when the EKS endpoint is public with an IP allowlist (Issue #13) — set `create_bastion = false` instead.

---

## Diagnostic Commands

> **Quick start:** Before running individual commands, try the automated diagnostics:
> ```bash
> # Deployment status and next-step guidance
> ./infra/scripts/status.sh
> make status              # equivalent
>
> # SSM parameter validation
> ./infra/scripts/manage-ssm.sh validate
> ```

### Cluster access

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl config current-context
kubectl get nodes -o wide
aws sts get-caller-identity
```

### Pods

```bash
kubectl get pods -n langsmith
kubectl get pods -n langsmith -w
kubectl describe pod <pod-name> -n langsmith
kubectl logs <pod-name> -n langsmith --tail=50
kubectl logs <pod-name> -n langsmith --previous --tail=50
kubectl logs -n langsmith deploy/langsmith-backend --tail=100 -f
```

### ALB and ingress

```bash
kubectl get ingress -n langsmith
kubectl describe ingress -n langsmith
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'langsmith')]"
```

### TLS and certificates

```bash
kubectl get certificate -n langsmith
kubectl describe certificate <cert-name> -n langsmith
kubectl get challenges -n langsmith
kubectl get clusterissuer
```

### ESO and secrets

```bash
kubectl get externalsecret -n langsmith
kubectl describe externalsecret langsmith-config -n langsmith
kubectl get clustersecretstore langsmith-ssm
kubectl get secret langsmith-config -n langsmith -o jsonpath='{.data}' | jq 'keys'
./infra/scripts/manage-ssm.sh validate
./infra/scripts/manage-ssm.sh diff
```

### Helm

```bash
helm status langsmith -n langsmith
helm history langsmith -n langsmith
helm get values langsmith -n langsmith
```

### IRSA and IAM

```bash
kubectl get sa langsmith -n langsmith -o yaml | grep eks.amazonaws.com
terraform output langsmith_irsa_role_arn
aws iam get-role --role-name <irsa-role-name>
```

### LangSmith Deployments

```bash
kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
kubectl get lgp -n langsmith
kubectl get crd | grep langchain
kubectl get pods -n keda
```

### Quick health check

```bash
echo "=== Context ===" && kubectl config current-context
echo "=== Nodes ===" && kubectl get nodes
echo "=== Pods ===" && kubectl get pods -n langsmith
echo "=== Ingress ===" && kubectl get ingress -n langsmith
echo "=== Helm ===" && helm status langsmith -n langsmith 2>/dev/null | grep -E "STATUS|LAST DEPLOYED"
```
