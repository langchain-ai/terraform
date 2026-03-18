# LangSmith on AWS — Teardown Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before destroying for any notes on data migration or export.

This guide walks through a clean teardown — from removing the application layer down to destroying all AWS infrastructure.

---

## Overview

Teardown happens in reverse order of deployment:

```
Pass 3 (if enabled) — Remove LangGraph deployments (LGP CRDs + pods)
Pass 2              — Uninstall LangSmith Helm release
Pass 1              — Destroy all AWS infrastructure (terraform destroy)
```

---

## Step 1 — Remove LangGraph Platform Deployments (if enabled)

If Pass 3 (LangSmith Deployments) was enabled, remove LGP resources before uninstalling Helm.

The uninstall script (Step 2) handles LGP pod/service/deployment cleanup automatically. The LGP CRD is kept due to a resource policy and must be deleted manually:

```bash
# Delete all LangGraph deployments (operator cleans up pods)
kubectl delete lgp --all -n langsmith

# Wait for operator to finish
kubectl get pods -n langsmith -w

# Delete the LGP CRD — kept due to resource policy, must be done manually
kubectl delete crd lgps.apps.langchain.ai
```

---

## Step 2 — Uninstall LangSmith Helm Release

Use the provided script — it handles the Helm release, ESO resources, and operator-managed pods (agent-builder, LangGraph) in one pass:

```bash
cd aws/helm
./scripts/uninstall.sh
```

After the script completes:

```bash
# Delete the namespace if it wasn't removed automatically
kubectl delete namespace langsmith
```

---

## Step 3 — Remove Kubernetes Bootstrap Resources

Uninstall in this order — the ALB controller must go last so it can deprovision any ingress-managed ALBs before its IAM permissions are removed.

```bash
# Uninstall KEDA
helm uninstall keda -n keda
kubectl delete namespace keda

# Uninstall External Secrets Operator
helm uninstall external-secrets -n external-secrets
kubectl delete namespace external-secrets

# Uninstall AWS Load Balancer Controller — LAST
# Removing this triggers cleanup of any ALBs created by ingress objects
helm uninstall aws-load-balancer-controller -n kube-system
```

cert-manager is not installed by default in this stack — skip it if `helm list -A` doesn't show it.

After uninstalling the ALB controller, wait ~2 minutes and verify no ingress-provisioned ALBs remain:

```bash
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName, '<name_prefix>')].[LoadBalancerName,State.Code]" \
  --output table
```

If a stale ALB remains after 2 minutes, delete it manually — it will block VPC subnet deletion during `terraform destroy`.

---

## Step 4 — Pre-Destroy: Unblock RDS

Two things will cause `terraform destroy` to fail on RDS if not addressed first.

### 4a — Disable deletion protection

Check if deletion protection is on (it defaults to `true` in the postgres module):

```bash
aws rds describe-db-instances \
  --db-instance-identifier <name_prefix>-<environment>-pg \
  --region <region> \
  --query "DBInstances[0].DeletionProtection" \
  --output text
```

If `True`, disable it:

```bash
aws rds modify-db-instance \
  --db-instance-identifier <name_prefix>-<environment>-pg \
  --no-deletion-protection \
  --region <region>
```

### 4b — Enable skip_final_snapshot

The postgres module does not set `skip_final_snapshot`, so the AWS provider defaults to `false`. Without a `final_snapshot_identifier`, `terraform destroy` will fail immediately on the RDS step.

In `modules/postgres/main.tf`, uncomment the line before running destroy:

```hcl
# Uncomment before running terraform destroy
# skip_final_snapshot = true
```

Then run a targeted apply to push the change before destroying:

```bash
cd aws/infra
source ./setup-env.sh
terraform apply -target=module.postgres
```

---

## Step 5 — Destroy AWS Infrastructure

Run from the `aws/infra` directory:

```bash
cd aws/infra
source ./setup-env.sh

# Preview what will be destroyed
terraform plan -destroy

# Destroy all resources
terraform destroy
```

Terraform will destroy in dependency order:
- k8s-bootstrap (cluster-autoscaler, metrics-server Helm releases)
- RDS PostgreSQL instance
- ElastiCache Redis cluster
- S3 bucket
- ALB (pre-provisioned)
- IAM roles (IRSA, ESO)
- EKS node groups and cluster
- VPC, subnets, NAT gateway, route tables

> **Data warning:** `terraform destroy` permanently deletes the RDS instance and S3 bucket contents. Export any data you need to retain before proceeding.

**Note on `source ./setup-env.sh`:** The script sets `TF_VAR_postgres_password` and `TF_VAR_redis_auth_token`. If those SSM parameters don't exist (e.g. they were never stored there), the variables will be unset and Terraform will fail provider validation even during destroy. In that case, set them manually before running destroy:

```bash
export TF_VAR_postgres_password="any-placeholder"
export TF_VAR_redis_auth_token=$(openssl rand -hex 16)
```

---

## Step 6 — Manual Cleanup (if needed)

If Terraform state is out of sync, clean up manually:

```bash
# Delete EKS cluster
aws eks delete-cluster --name <name_prefix>-<environment>-eks --region <region>

# Delete RDS instance (skip final snapshot)
aws rds delete-db-instance \
  --db-instance-identifier <name_prefix>-<environment>-pg \
  --skip-final-snapshot \
  --region <region>

# Delete ElastiCache replication group
aws elasticache delete-replication-group \
  --replication-group-id <name_prefix>-<environment>-redis \
  --region <region>

# Empty and delete S3 bucket
aws s3 rm s3://<name_prefix>-<environment>-traces --recursive
aws s3api delete-bucket --bucket <name_prefix>-<environment>-traces --region <region>

# Delete VPC (after all dependent resources are removed)
aws ec2 delete-vpc --vpc-id <vpc-id> --region <region>
```

---

## Step 7 — Verify Cleanup

Replace `<name_prefix>` with your value from `terraform.tfvars`.

```bash
# No EKS clusters remaining
aws eks list-clusters --region <region>

# No RDS instances remaining
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '<name_prefix>')].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table

# No ElastiCache clusters remaining
aws elasticache describe-replication-groups \
  --query "ReplicationGroups[?contains(ReplicationGroupId, '<name_prefix>')].[ReplicationGroupId,Status]" \
  --output table

# No S3 bucket remaining
aws s3 ls | grep <name_prefix>

# No ALBs remaining
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName, '<name_prefix>')].[LoadBalancerName,State.Code]" \
  --output table

# No VPC remaining
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*<name_prefix>*" \
  --region <region> \
  --query "Vpcs[].VpcId" \
  --output text
```
