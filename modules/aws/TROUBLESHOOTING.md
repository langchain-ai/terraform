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

**Cause:** AWS Load Balancer Controller is not running or lacks the required IRSA permissions, or the Terraform-provisioned ALB is not being referenced correctly.

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

## Diagnostic Commands

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
