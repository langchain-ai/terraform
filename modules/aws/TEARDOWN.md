# LangSmith on AWS — Teardown Guide

> Check the [LangSmith Self-Hosted Changelog](https://docs.langchain.com/langsmith/self-hosted-changelog) before destroying for any notes on data migration or export.

This guide covers two teardown scenarios:

1. **With Terraform state** — the happy path using `terraform destroy`
2. **Without Terraform state** — manual teardown via AWS CLI when state is lost

Both follow the same reverse-dependency order. Pick the section that matches your situation.

---

## Pre-Teardown Checklist

Before starting, confirm:

```bash
# Verify AWS identity and region
aws sts get-caller-identity
aws eks update-kubeconfig --name <name_prefix>-<environment>-eks --region <region>

# Verify kubectl is pointing to the right cluster
kubectl config current-context

# Check what's running
helm list -A
kubectl get namespaces
```

**Data warning:** Teardown permanently deletes the RDS instance, S3 bucket contents, and SSM parameters. Export any data you need to retain before proceeding.

---

# Option A: Teardown With Terraform State

Use this when `terraform state list` returns resources. Teardown happens in reverse order of deployment:

```
Pass 3 (if enabled) — Remove LangGraph deployments (LGP CRDs + pods)
Pass 2              — Uninstall LangSmith Helm release
Pass 1              — Destroy all AWS infrastructure (terraform destroy)
```

## A1 — Remove LangGraph Platform Deployments (if enabled)

If Pass 3 (LangSmith Deployments) was enabled, remove LGP resources before uninstalling Helm.

The uninstall script (Step A2) handles LGP pod/service/deployment cleanup automatically. The LGP CRD is kept due to a resource policy and must be deleted manually:

```bash
# Delete all LangGraph deployments (operator cleans up pods)
kubectl delete lgp --all -n langsmith

# Wait for operator to finish
kubectl get pods -n langsmith -w

# Delete the LGP CRD — kept due to resource policy, must be done manually
kubectl delete crd lgps.apps.langchain.ai
```

## A2 — Uninstall LangSmith Helm Release

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

## A3 — Remove Kubernetes Bootstrap Resources

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

## A4 — Pre-Destroy: Unblock RDS

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
source ./scripts/setup-env.sh
terraform apply -target=module.postgres
```

## A5 — Destroy AWS Infrastructure

Run from the `aws/infra` directory:

```bash
cd aws/infra
source ./scripts/setup-env.sh

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

**Note on `source ./scripts/setup-env.sh`:** The script sets `TF_VAR_postgres_password` and `TF_VAR_redis_auth_token`. If those SSM parameters don't exist (e.g. they were never stored there), the variables will be unset and Terraform will fail provider validation even during destroy. In that case, set them manually before running destroy:

```bash
export TF_VAR_postgres_password="any-placeholder"
export TF_VAR_redis_auth_token=$(openssl rand -hex 16)
```

## A6 — Verify Cleanup

Replace `<name_prefix>` with your value from `terraform.tfvars`.

```bash
aws eks list-clusters --region <region>
aws rds describe-db-instances \
  --query "DBInstances[?contains(DBInstanceIdentifier, '<name_prefix>')].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table
aws elasticache describe-replication-groups \
  --query "ReplicationGroups[?contains(ReplicationGroupId, '<name_prefix>')].[ReplicationGroupId,Status]" \
  --output table
aws s3 ls | grep <name_prefix>
aws elbv2 describe-load-balancers --region <region> \
  --query "LoadBalancers[?contains(LoadBalancerName, '<name_prefix>')].[LoadBalancerName,State.Code]" \
  --output table
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*<name_prefix>*" \
  --region <region> \
  --query "Vpcs[].VpcId" \
  --output text
```

---

# Option B: Teardown Without Terraform State

Use this when Terraform state is lost (deleted, corrupted, or never configured a remote backend). Everything must be deleted manually via AWS CLI in reverse dependency order.

**How this happens:** State loss typically occurs when using a local backend (`terraform.tfstate` file) and the file is deleted during a directory restructure, or a remote backend was never configured.

## B0 — Inventory What Exists

Before deleting anything, build a complete inventory. The naming convention `<name_prefix>-<environment>-{resource}` makes this straightforward:

```bash
REGION="<region>"
PREFIX="<name_prefix>-<environment>"

echo "=== EKS ===" && aws eks list-clusters --region $REGION --output json
echo "=== RDS ===" && aws rds describe-db-instances --region $REGION \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, \`$PREFIX\`)].DBInstanceIdentifier" --output json
echo "=== ElastiCache ===" && aws elasticache describe-replication-groups --region $REGION \
  --query "ReplicationGroups[?starts_with(ReplicationGroupId, \`$PREFIX\`)].ReplicationGroupId" --output json
echo "=== S3 ===" && aws s3 ls | grep "$PREFIX"
echo "=== SSM ===" && aws ssm describe-parameters --region $REGION \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/langsmith/$PREFIX" \
  --query 'Parameters[*].Name' --output json
echo "=== ALBs ===" && aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[*].[LoadBalancerName,State.Code]" --output table
echo "=== IAM ===" && aws iam list-roles \
  --query "Roles[?contains(RoleName, \`$PREFIX\`)].RoleName" --output json
echo "=== VPC ===" && aws ec2 describe-vpcs --region $REGION \
  --filters "Name=tag:Name,Values=*$PREFIX*" \
  --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table
```

Also use the tag API to catch anything you might miss:

```bash
aws resourcegroupstaggingapi get-resources --region $REGION \
  --tag-filters "Key=name-prefix,Values=<name_prefix>" \
  --query 'ResourceTagMappingList[*].ResourceARN' --output json
```

## B1 — Uninstall Helm Releases

Same as Option A, but since there's no Terraform to clean up k8s-bootstrap resources, you must uninstall everything manually.

**Critical ordering:**
1. Delete ingress resources *before* uninstalling the ALB controller
2. Uninstall KEDA *after* deleting namespaces that contain ScaledObjects, OR delete ScaledObjects first

```bash
# Uninstall LangSmith app
helm uninstall langsmith -n langsmith

# Delete the retained LGP CRD
kubectl delete crd lgps.apps.langchain.ai 2>/dev/null

# Delete ingress to trigger ALB controller cleanup BEFORE uninstalling the controller
kubectl delete ingress --all -n langsmith

# Uninstall supporting charts
helm uninstall external-secrets -n external-secrets
helm uninstall keda -n keda
helm uninstall metrics-server -n kube-system
helm uninstall cluster-autoscaler -n kube-system

# Verify ingress-created ALBs are gone, then uninstall ALB controller
aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?starts_with(LoadBalancerName, \`k8s-\`)].[LoadBalancerName]" --output text
helm uninstall aws-load-balancer-controller -n kube-system

# Delete namespaces
kubectl delete namespace langsmith external-secrets keda
```

**Known issue — KEDA finalizers:** If the `langsmith` namespace gets stuck in `Terminating`, KEDA ScaledObject finalizers are likely the cause (the KEDA controller is already gone so it can't clear them). Fix:

```bash
for obj in $(kubectl get scaledobjects -n langsmith -o name 2>/dev/null); do
  kubectl patch "$obj" -n langsmith --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

## B2 — Delete EKS Cluster

Node groups must be deleted first, then the cluster.

```bash
# List and delete node groups
for ng in $(aws eks list-nodegroups --cluster-name $PREFIX-eks --region $REGION --query 'nodegroups[*]' --output text); do
  echo "Deleting node group: $ng"
  aws eks delete-nodegroup --cluster-name $PREFIX-eks --nodegroup-name "$ng" --region $REGION
done

# Wait for node groups to be deleted (~5 min)
aws eks wait nodegroup-deleted --cluster-name $PREFIX-eks --nodegroup-name "$ng" --region $REGION 2>/dev/null

# Delete cluster
aws eks delete-cluster --name $PREFIX-eks --region $REGION
```

## B3 — Delete RDS Instance

```bash
# Check deletion protection
DELETION_PROTECTION=$(aws rds describe-db-instances \
  --db-instance-identifier $PREFIX-pg --region $REGION \
  --query 'DBInstances[0].DeletionProtection' --output text)

# Disable if needed
if [ "$DELETION_PROTECTION" = "True" ]; then
  aws rds modify-db-instance --db-instance-identifier $PREFIX-pg \
    --no-deletion-protection --region $REGION
  echo "Waiting for modification to apply..."
  aws rds wait db-instance-available --db-instance-identifier $PREFIX-pg --region $REGION
fi

# Delete (skip final snapshot for dev/test)
aws rds delete-db-instance --db-instance-identifier $PREFIX-pg \
  --skip-final-snapshot --region $REGION
```

## B4 — Delete ElastiCache

```bash
# Delete by replication group (not individual cache cluster)
aws elasticache delete-replication-group \
  --replication-group-id $PREFIX-redis --region $REGION
```

> **Note:** There is no `--no-final-snapshot-identifier` flag for ElastiCache. Simply omit `--final-snapshot-identifier` to skip it.

## B5 — Empty and Delete S3 Bucket

```bash
aws s3 rm s3://$PREFIX-traces --recursive
aws s3 rb s3://$PREFIX-traces
```

## B6 — Delete SSM Parameters

```bash
# List parameters first to confirm
aws ssm describe-parameters --region $REGION \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/langsmith/$PREFIX" \
  --query 'Parameters[*].Name' --output json

# Delete all
aws ssm delete-parameters --region $REGION --names \
  "/langsmith/$PREFIX/agent-builder-encryption-key" \
  "/langsmith/$PREFIX/insights-encryption-key" \
  "/langsmith/$PREFIX/langsmith-admin-password" \
  "/langsmith/$PREFIX/langsmith-api-key-salt" \
  "/langsmith/$PREFIX/langsmith-jwt-secret" \
  "/langsmith/$PREFIX/langsmith-license-key" \
  "/langsmith/$PREFIX/postgres-password" \
  "/langsmith/$PREFIX/redis-auth-token"
```

## B7 — Delete ALBs and Target Groups

```bash
# Delete pre-provisioned ALB
ALB_ARN=$(aws elbv2 describe-load-balancers --names $PREFIX-alb --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Delete listeners first
for listener_arn in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region $REGION \
  --query 'Listeners[*].ListenerArn' --output text); do
  aws elbv2 delete-listener --listener-arn "$listener_arn" --region $REGION
done

# Delete the ALB
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $REGION

# Clean up orphaned target groups (from ingress-created ALBs)
for tg_arn in $(aws elbv2 describe-target-groups --region $REGION \
  --query "TargetGroups[?contains(TargetGroupName, \`k8s-langsmit\`)].TargetGroupArn" --output text); do
  echo "Deleting target group: $tg_arn"
  aws elbv2 delete-target-group --target-group-arn "$tg_arn" --region $REGION
done
```

## B8 — Delete IAM Roles and Policies

Each role needs its policies detached/deleted before the role itself can be deleted. Use this pattern for each role:

```bash
delete_iam_role() {
  local ROLE="$1"
  echo "=== Deleting role: $ROLE ==="

  # Remove from instance profiles
  for ip in $(aws iam list-instance-profiles-for-role --role-name "$ROLE" \
    --query 'InstanceProfiles[*].InstanceProfileName' --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$ROLE"
    aws iam delete-instance-profile --instance-profile-name "$ip"
  done

  # Detach managed policies
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$policy_arn"
  done

  # Delete inline policies
  for policy_name in $(aws iam list-role-policies --role-name "$ROLE" \
    --query 'PolicyNames[*]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$policy_name"
  done

  aws iam delete-role --role-name "$ROLE"
}
```

Roles to delete (find exact names with `aws iam list-roles --query "Roles[?contains(RoleName, '<prefix>')]"`):

```bash
# ESO role
delete_iam_role "$PREFIX-eso"

# IRSA role
delete_iam_role "$PREFIX-eks-irsa-role"

# EKS cluster role (name has a timestamp suffix)
delete_iam_role "$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`$PREFIX-eks-cluster\`)].RoleName" --output text)"

# EBS CSI driver role
delete_iam_role "AmazonEKSTFEBSCSIRole-$PREFIX-eks"

# Node group role (name has a timestamp suffix)
delete_iam_role "$(aws iam list-roles --query "Roles[?starts_with(RoleName, \`node-group-default-eks-node-group\`)].RoleName" --output text)"

# Delete customer-managed policies
for policy_arn in $(aws iam list-policies --scope Local \
  --query "Policies[?contains(PolicyName, \`$PREFIX\`)].Arn" --output text); do
  aws iam delete-policy --policy-arn "$policy_arn"
done

# Delete OIDC provider
for oidc_arn in $(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[*].Arn" --output text); do
  tags=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" \
    --query "Tags[?Key=='name-prefix' && Value=='<name_prefix>']" --output text 2>/dev/null)
  if [ -n "$tags" ]; then
    echo "Deleting OIDC provider: $oidc_arn"
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn"
  fi
done
```

## B9 — Delete VPC and Networking

**Must be done last.** Order matters — dependencies must be removed before their parents.

```bash
VPC_ID="<vpc-id>"

# 1. Delete VPC endpoints
for vpce in $(aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'VpcEndpoints[*].VpcEndpointId' --output text); do
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$vpce" --region $REGION
done

# 2. Delete NAT gateways (and wait — required before releasing EIPs)
for nat_id in $(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text); do
  aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --region $REGION
done
echo "Waiting for NAT gateway deletion (~60s)..."
while true; do
  state=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" --region $REGION \
    --query 'NatGateways[?State!=`deleted`].State' --output text)
  [ -z "$state" ] && break
  sleep 10
done

# 3. Release Elastic IPs
for alloc_id in $(aws ec2 describe-addresses --region $REGION \
  --filters "Name=tag:Name,Values=*$PREFIX*" \
  --query 'Addresses[*].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$alloc_id" --region $REGION
done

# 4. Delete subnets
for subnet_id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'Subnets[*].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id "$subnet_id" --region $REGION
done

# 5. Detach and delete Internet Gateway
for igw_id in $(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'InternetGateways[*].InternetGatewayId' --output text); do
  aws ec2 detach-internet-gateway --internet-gateway-id "$igw_id" --vpc-id $VPC_ID --region $REGION
  aws ec2 delete-internet-gateway --internet-gateway-id "$igw_id" --region $REGION
done

# 6. Delete security groups (revoke cross-references first)
for sg_id in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  # Revoke all rules (ingress and egress) to break circular dependencies
  for rule_id in $(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg_id" --region $REGION \
    --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text); do
    aws ec2 revoke-security-group-ingress --group-id "$sg_id" --security-group-rule-ids "$rule_id" --region $REGION 2>/dev/null
  done
  for rule_id in $(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg_id" --region $REGION \
    --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text); do
    aws ec2 revoke-security-group-egress --group-id "$sg_id" --security-group-rule-ids "$rule_id" --region $REGION 2>/dev/null
  done
done
# Now delete them
for sg_id in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$sg_id" --region $REGION
done

# 7. Delete custom route tables
for rtb_id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text); do
  aws ec2 delete-route-table --route-table-id "$rtb_id" --region $REGION
done

# 8. Delete the VPC
aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION
```

**Known issue — EKS security groups:** EKS creates node and cluster security groups that reference each other. You must revoke all rules from both before either can be deleted, which is why the script above revokes rules in a separate pass before deleting.

## B10 — Clean Up Remaining Resources

These are easy to miss — use the tag API output from B0 to find them.

```bash
# RDS and ElastiCache subnet groups
aws rds delete-db-subnet-group --db-subnet-group-name $PREFIX-pg-subnet-group --region $REGION 2>/dev/null
aws elasticache delete-cache-subnet-group --cache-subnet-group-name $PREFIX-redis-subnet-group --region $REGION 2>/dev/null

# CloudWatch log group
aws logs delete-log-group --log-group-name "/aws/eks/$PREFIX-eks/cluster" --region $REGION 2>/dev/null

# Secrets Manager
aws secretsmanager delete-secret --secret-id $PREFIX-langsmith --force-delete-without-recovery --region $REGION 2>/dev/null

# CloudFormation stacks (EKS VPC CNI addon)
for stack in $(aws cloudformation list-stacks --region $REGION \
  --query "StackSummaries[?contains(StackName, \`$PREFIX\`) && StackStatus!='DELETE_COMPLETE'].StackName" --output text); do
  aws cloudformation delete-stack --stack-name "$stack" --region $REGION
done

# Launch templates
aws ec2 describe-launch-templates --region $REGION \
  --query "LaunchTemplates[*].[LaunchTemplateId,LaunchTemplateName]" --output table
# Delete the one matching your deploy timestamp

# KMS keys (7-day minimum deletion window enforced by AWS)
for alias in $(aws kms list-aliases --region $REGION \
  --query "Aliases[?contains(AliasName, \`$PREFIX\`)].TargetKeyId" --output text); do
  aws kms schedule-key-deletion --key-id "$alias" --pending-window-in-days 7 --region $REGION
done

# Local sensitive files
rm -f .admin_password .api_key_salt .jwt_secret .license_key .pg_password
```

## B11 — Verify Cleanup

```bash
aws eks list-clusters --region $REGION --query "clusters[?contains(@, \`$PREFIX\`)]"
aws rds describe-db-instances --region $REGION \
  --query "DBInstances[?starts_with(DBInstanceIdentifier, \`$PREFIX\`)].DBInstanceIdentifier"
aws elasticache describe-replication-groups --region $REGION \
  --query "ReplicationGroups[?starts_with(ReplicationGroupId, \`$PREFIX\`)].ReplicationGroupId"
aws s3 ls | grep "$PREFIX"
aws ssm describe-parameters --region $REGION \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/langsmith/$PREFIX" \
  --query 'Parameters[*].Name'
aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[?starts_with(LoadBalancerName, \`$PREFIX\`)].LoadBalancerName"
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=*$PREFIX*" --region $REGION \
  --query 'Vpcs[*].VpcId'
aws iam list-roles --query "Roles[?contains(RoleName, \`$PREFIX\`)].RoleName"

# Catch-all via tags
aws resourcegroupstaggingapi get-resources --region $REGION \
  --tag-filters "Key=name-prefix,Values=<name_prefix>" \
  --query 'ResourceTagMappingList[*].ResourceARN'
```

---

## Parallelization Notes

Several resources can be deleted in parallel since they have no dependencies on each other:

| Can run in parallel | Wait required before |
|---|---|
| RDS, ElastiCache, S3, SSM | These are independent — start all at once |
| EKS node groups | Must complete before cluster deletion |
| NAT gateway | Must complete before EIP release and subnet deletion |
| EKS cluster | Must complete before VPC networking cleanup |

## Lessons Learned

- **Always configure a remote backend** (S3 + DynamoDB) before `terraform apply` — local state is fragile and easily lost during directory restructuring
- **KEDA finalizers block namespace deletion** if the KEDA controller is uninstalled first — delete ScaledObjects before uninstalling KEDA, or patch out finalizers
- **Delete ingress resources before the ALB controller** — otherwise ingress-created ALBs become orphaned
- **EKS security groups cross-reference each other** — must revoke all rules before either can be deleted
- **ElastiCache has no `--no-final-snapshot-identifier` flag** — just omit `--final-snapshot-identifier` entirely
- **`aws resourcegroupstaggingapi get-resources`** is essential for finding orphaned resources (subnet groups, log groups, launch templates) that don't appear in service-specific queries
- **KMS keys have a mandatory 7-day deletion window** — schedule deletion but don't wait for it
