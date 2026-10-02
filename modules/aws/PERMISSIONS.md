# AWS permissions

The identity that runs `terraform apply` needs two kinds of access: permission to create resources, and permission to create IAM roles and pass them to AWS services. `PowerUserAccess` grants the first and not the second, so an identity that holds only `PowerUserAccess` fails with `AccessDenied` on the first IAM role the apply creates.

## Required policies

Attach one of these to the deploying identity. With SSO, attach it to the permission set you assume rather than to your user.

| Policies | Covers |
|----------|--------|
| `AdministratorAccess` | Everything |
| `PowerUserAccess` + `IAMFullAccess` | Everything the deployment needs, as a pairing of AWS managed policies |
| A custom policy with the services in the next table | Narrowest option |

A custom policy needs these services. The **Required when** column is the configuration that brings each one into the apply.

| Service | Actions | Needed for | Required when |
|---------|---------|-----------|---------------|
| EKS | `eks:*` | Cluster, managed node groups, add-ons, access entries | Always |
| EC2 | `ec2:*` | VPC, subnets, NAT gateway, route tables, security groups, S3 gateway endpoint, launch templates | Always |
| IAM | See [IAM actions](#iam-actions) | Service roles, IRSA roles, the cluster's OIDC provider | Always |
| KMS | `kms:CreateKey`, `kms:CreateAlias`, `kms:PutKeyPolicy`, `kms:TagResource`, `kms:DescribeKey`, `kms:GetKeyPolicy`, `kms:ScheduleKeyDeletion` | The EKS secrets encryption key | Always |
| CloudWatch Logs | `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:TagResource`, `logs:DescribeLogGroups`, `logs:DeleteLogGroup` | The EKS control plane log group | Always |
| S3 | `s3:*` on the deployment's buckets | LangSmith bucket, bucket policy, encryption, lifecycle | Always |
| Elastic Load Balancing | `elasticloadbalancing:*` | ALB, listeners, target group | Always |
| RDS | `rds:*` | PostgreSQL instance and subnet group | `postgres_source = "external"` (the default), or `enable_smithdb = true` |
| ElastiCache | `elasticache:*` | Redis replication group | `redis_source = "external"` (the default), or `enable_sandboxes = true` |
| ACM | `acm:*` | The LangSmith certificate and its validation | `langsmith_domain` is set and `acm_certificate_arn` is not |
| Route 53 | `route53:*` | Hosted zone and records | `langsmith_domain` is set and `acm_certificate_arn` is not |
| SQS, EventBridge | `sqs:*`, `events:*` | Karpenter's interruption queue and rules | `enable_smithdb = true` |
| WAF | `wafv2:*` | Web ACL and its ALB association | `create_waf = true` |
| Network Firewall | `network-firewall:*` | Egress firewall, policy, rule group | `create_firewall = true` |
| CloudTrail | `cloudtrail:*` | Trail | `create_cloudtrail = true` |
| KMS | `kms:Decrypt`, `kms:GenerateDataKey` on the key | Bucket encryption with a customer-managed key | `s3_kms_key_arn` is set |

The existing S3 key already has to allow the deploying identity; Terraform does not edit its key policy.

### IAM actions

```text
iam:CreateRole
iam:DeleteRole
iam:GetRole
iam:TagRole
iam:UpdateAssumeRolePolicy
iam:ListRolePolicies
iam:ListAttachedRolePolicies
iam:ListInstanceProfilesForRole
iam:PutRolePolicy
iam:GetRolePolicy
iam:DeleteRolePolicy
iam:CreatePolicy
iam:CreatePolicyVersion
iam:DeletePolicy
iam:DeletePolicyVersion
iam:GetPolicy
iam:GetPolicyVersion
iam:ListPolicyVersions
iam:TagPolicy
iam:AttachRolePolicy
iam:DetachRolePolicy
iam:CreateOpenIDConnectProvider
iam:DeleteOpenIDConnectProvider
iam:GetOpenIDConnectProvider
iam:TagOpenIDConnectProvider
iam:CreateInstanceProfile
iam:DeleteInstanceProfile
iam:GetInstanceProfile
iam:AddRoleToInstanceProfile
iam:RemoveRoleFromInstanceProfile
iam:TagInstanceProfile
iam:PassRole
iam:CreateServiceLinkedRole
```

`iam:PassRole` covers the roles Terraform hands to AWS services: the EKS cluster role, the node group roles, the EBS CSI add-on role, and the bastion's instance profile. `iam:CreateServiceLinkedRole` is needed the first time the account uses EKS, Elastic Load Balancing, RDS, ElastiCache, or Auto Scaling.

## Permissions boundaries and SCPs

The module sets no permissions boundary on the roles it creates, and it has no variable for one. An account whose SCP or IAM policy requires a boundary on `iam:CreateRole` rejects the first role the apply creates. Ask for an exception for the deploying identity, or deploy into an account without that requirement.

SCPs override every grant in the tables above. A common case is an SCP that allows only certain regions, which denies every action in any other region even to `AdministratorAccess`. `make preflight` warns when the account alias contains `sandbox`, `test`, or `dev`, because those accounts are the ones most often under restrictive SCPs.

## Authenticate

Terraform uses the standard AWS credential chain: environment variables, `AWS_PROFILE`, then `~/.aws/credentials`. The setup steps for access keys and for SSO are in the [README](README.md#authenticate). Confirm the identity before every apply:

```bash
aws sts get-caller-identity
```

The identity that creates the cluster becomes its admin. Terraform sets `enable_cluster_creator_admin_permissions = true`, which gives that identity an EKS access entry with `AmazonEKSClusterAdminPolicy`, and grants cluster access to no one else. Run `make deploy` and the other Helm steps as the same identity, or add an access entry for each additional operator:

```bash
aws eks create-access-entry --cluster-name <cluster-name> --principal-arn <role-arn>
aws eks associate-access-policy --cluster-name <cluster-name> --principal-arn <role-arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

The operator who runs `make setup-env` also needs `ssm:PutParameter` and `ssm:GetParameter` on `/langsmith/<base_name>/*`, where `<base_name>` is `<name_prefix>-<environment>`. That script writes the application secrets to Parameter Store, where External Secrets reads them.

## Verify access before the first apply

Run `make preflight`. It confirms credentials with `aws sts get-caller-identity`, prints the account, identity, and region, and then makes one read-only call per service. A denial on any required service stops the script with exit 1 and names the actions that service needs.

| Service | Call the script makes | Required |
|---------|----------------------|----------|
| EC2 | `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeAvailabilityZones`, `ec2:DescribeVpcEndpoints` | Yes |
| EKS | `eks:DescribeCluster`, falling back to `eks:ListClusters` | Yes |
| IAM | `iam:ListRoles` | Yes |
| RDS | `rds:DescribeDBInstances` | Yes |
| ElastiCache | `elasticache:DescribeCacheClusters` | Yes |
| Elastic Load Balancing | `elasticloadbalancing:DescribeLoadBalancers` | Yes |
| S3 | `s3:ListAllMyBuckets` | Yes |
| SSM | `ssm:DescribeParameters` | Yes |
| ACM | `acm:ListCertificates` | Yes |
| Route 53 | `route53:ListHostedZones` | Yes |
| WAF | `wafv2:ListWebACLs` | No, warns only |

A read-only call that succeeds does not prove the create action behind it is allowed. The read-only pass never tests `iam:PassRole`, KMS, CloudWatch Logs, SQS, or EventBridge, and never checks service quotas.

To test creation, pass `--create-test-resources`:

```bash
make preflight ARGS="--create-test-resources"
```

It creates and then deletes a VPC, a subnet, a security group, and an IAM role, which confirms `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:CreateSecurityGroup`, and `iam:CreateRole`. Add `--domain <your-domain>` inside `ARGS` to confirm an ACM certificate and a Route 53 zone exist for it.

To test the actions the script does not cover, use the IAM policy simulator. It evaluates the principal's identity policies, its permissions boundary, and the SCPs on the account. For an SSO or other assumed role, simulate the role, not the session: take the role name from the `assumed-role/<role-name>/<session>` ARN that `aws sts get-caller-identity` prints.

```bash
aws iam get-role --role-name <role-name> --query Role.Arn --output text
```

```bash
aws iam simulate-principal-policy \
  --policy-source-arn <role-arn> \
  --action-names eks:CreateCluster iam:CreateRole iam:PassRole \
    iam:CreateOpenIDConnectProvider kms:CreateKey logs:CreateLogGroup \
    rds:CreateDBInstance elasticache:CreateReplicationGroup s3:CreateBucket \
    elasticloadbalancing:CreateLoadBalancer \
  --query 'EvaluationResults[].{action:EvalActionName,decision:EvalDecision}' \
  --output table
```

Every row must read `allowed`. `implicitDeny` means no policy grants the action. `explicitDeny` means a policy, a permissions boundary, or an SCP denies it, which no additional grant overrides. The simulator itself needs `iam:SimulatePrincipalPolicy`.

## IAM created during deployment

The deployment creates the following roles. IRSA roles trust the cluster's OIDC provider and are limited to one Kubernetes service account, or to one namespace for the LangSmith role.

| Role | Trusted by | Permissions | Created when |
|------|-----------|-------------|--------------|
| EKS cluster role | `eks.amazonaws.com` | `AmazonEKSClusterPolicy`, `AmazonEKSVPCResourceController` | Always |
| Node group role, one per managed node group | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` | Always |
| `AmazonEKSTFEBSCSIRole-<cluster-name>` | `kube-system/ebs-csi-controller-sa` | `AmazonEBSCSIDriverPolicy` | Always |
| AWS Load Balancer Controller role | Its controller service account | A policy the module creates for ALB and target group management | Always |
| Cluster Autoscaler role | Its controller service account | A policy the module creates for Auto Scaling group scaling | Always |
| `<base_name>-eso` | `external-secrets/external-secrets` | `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` on `/langsmith/<base_name>/*` | Always |
| `<cluster-name>-irsa-role` | Every service account in `langsmith_namespace` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the LangSmith bucket | `create_langsmith_irsa_role = true` (the default) |
| `<cluster-name>-cert-manager` | `cert-manager/cert-manager` | `route53:ChangeResourceRecordSets` and `route53:ListResourceRecordSets` on the hosted zone, `route53:GetChange`, `route53:ListHostedZonesByName` | `create_cert_manager_irsa = true` |
| `<base_name>-smithdb-irsa` | The SmithDB service account | Object access on the SmithDB bucket, plus `kms:Decrypt` and `kms:GenerateDataKey` when `s3_kms_key_arn` is set | `enable_smithdb = true` |
| Karpenter controller and node roles | The Karpenter service account, and `ec2.amazonaws.com` | Policies the module creates for node provisioning and the interruption queue | `enable_smithdb = true` |
| `<base_name>-sandbox-host` | `ec2.amazonaws.com` | The node group policies above | `enable_sandboxes = true` |
| `<name>-bastion`, with an instance profile | `ec2.amazonaws.com` | `AmazonSSMManagedInstanceCore`, plus `eks:DescribeCluster` and `eks:ListClusters` | `create_bastion = true` |

The LangSmith role also gets `rds-db:connect` for one database user when `postgres_iam_database_user` is set.

`create_langsmith_irsa_role = false` is not a way to deploy without creating IAM. No variable accepts an existing role in its place, and `make init-values` annotates the LangSmith service accounts with this role's ARN. The module has no bring-your-own path for any of the roles above.

## Resolve AccessDenied during apply

A denial names the action and the principal:

```text
Error: creating IAM Role (<name>): operation error IAM: CreateRole,
https response error StatusCode: 403, api error AccessDenied: User:
arn:aws:sts::<account>:assumed-role/<role>/<session> is not authorized to
perform: iam:CreateRole on resource: arn:aws:iam::<account>:role/<name>
```

Work through these causes in order:

1. **The identity lacks the action.** Add it, or attach `IAMFullAccess` for an IAM action. This is the common case.
2. **The message says `with an explicit deny in a service control policy`.** An SCP blocks the action, and only the organization's administrator can change it. The same message with `in a permissions boundary` means a boundary on the deploying identity blocks it.
3. **The failure names `iam:PassRole`.** The identity can create the role but not hand it to EKS or EC2. Grant `iam:PassRole` on the deployment's roles.
4. **The message carries an `Encoded authorization failure message`.** EC2 returns denials in encoded form. Decode it to see which statement denied the call, which needs `sts:DecodeAuthorizationMessage`:

   ```bash
   aws sts decode-authorization-message --encoded-message <message> \
     --query DecodedMessage --output text
   ```

After granting the missing permission, re-run `terraform apply`. Resources created before the failure stay in state.
