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

### Issue #13 — Private EKS cluster unreachable (bastion required)

**Symptom:** `kubectl` and `terraform apply` timeout when `enable_public_eks_cluster = false`.

**Cause:** The EKS API endpoint is private-only. You must run commands from within the VPC — either via the bastion host or a VPN connection.

**Fix:**

```bash
# If bastion was provisioned (create_bastion = true):
aws ssm start-session --target <bastion-instance-id>

# From the bastion, update kubeconfig and proceed normally:
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl get nodes
```

If the bastion wasn't provisioned, either set `create_bastion = true` and re-apply, or temporarily set `enable_public_eks_cluster = true`.

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

### Issue #15 — ALB hostname changed after ingress recreation

**Symptom:** LangSmith URL stops working. Agent deployments stuck in DEPLOYING state.
DNS records or bookmarks point to an old ALB hostname that no longer resolves.

**Cause:** Deleting the Kubernetes ingress (via `helm uninstall`, `kubectl delete ingress`,
or namespace deletion) deprovisions the ALB. When the ingress is recreated, a new ALB with
a different hostname is issued. The `config.deployment.url` in the Helm values still points
to the old hostname, so the operator's health checks fail and deployments stay stuck.

This also happens if the ALB controller creates a new ALB instead of reusing the
Terraform pre-provisioned one. The `group.name` annotation is required alongside
`load-balancer-arn` to prevent this — without it, the controller's behavior is
inconsistent across ingress reconciliations.

**Prevention:**
- Ensure `group.name` and `load-balancer-arn` annotations are both set
  (`init-values.sh` does this automatically when a pre-provisioned ALB exists)
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
