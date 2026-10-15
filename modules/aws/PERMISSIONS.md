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
| EC2 | `ec2:*` | VPC, subnets, NAT gateway, route tables, security groups, S3 gateway endpoint, interface endpoints, launch templates | Always |
| IAM | See [IAM actions](#iam-actions) | Service roles, IRSA roles, the cluster's OIDC provider | Always |
| KMS | `kms:CreateKey`, `kms:CreateAlias`, `kms:DeleteAlias`, `kms:ListAliases`, `kms:PutKeyPolicy`, `kms:GetKeyPolicy`, `kms:DescribeKey`, `kms:EnableKeyRotation`, `kms:GetKeyRotationStatus`, `kms:TagResource`, `kms:UntagResource`, `kms:ListResourceTags`, `kms:ScheduleKeyDeletion` | The EKS secrets encryption key | `eks_secrets_kms_key_arn` is empty (the default) |
| CloudWatch Logs | `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:TagResource`, `logs:DescribeLogGroups`, `logs:DeleteLogGroup` | The EKS control plane log group | Always |
| S3 | `s3:*` on the deployment's buckets | The LangSmith bucket, plus the SmithDB bucket and the `<name>-access-logs` ALB log bucket when those are enabled; their policies, encryption, and lifecycle | Always |
| Elastic Load Balancing | `elasticloadbalancing:*` | ALB, listeners, target group | Always |
| RDS | `rds:*` | PostgreSQL instance and subnet group | `postgres_source = "external"` (the default), or `enable_smithdb = true` |
| ElastiCache | `elasticache:*` | Redis replication group | `redis_source = "external"` (the default), or `enable_sandboxes = true` |
| ACM | `acm:*` | The LangSmith certificate and its validation | `langsmith_domain` is set and `acm_certificate_arn` is not |
| Route 53 | `route53:*` | Hosted zone and records | `langsmith_domain` is set and `acm_certificate_arn` is not |
| SQS, EventBridge | `sqs:*`, `events:*` | Karpenter's interruption queue and rules | `enable_smithdb = true` |
| WAF | `wafv2:*` | Web ACL and its ALB association | `create_waf = true` |
| Network Firewall | `network-firewall:*` | Egress firewall, policy, rule group | `create_firewall = true` |
| CloudTrail | `cloudtrail:*` | Trail | `create_cloudtrail = true` |
| CloudFormation | `cloudformation:CreateStack`, `cloudformation:DeleteStack`, `cloudformation:DescribeStacks`, `cloudformation:DescribeStackEvents`, `cloudformation:GetTemplate` | The EKS Blueprints usage-telemetry stack, which holds no resources | `create_eks_blueprints_telemetry_stack = true` (the default) |
| KMS | `kms:Decrypt`, `kms:GenerateDataKey` on the key | Bucket encryption with a customer-managed key | `s3_kms_key_arn` is set |
| KMS | `kms:DescribeKey`, `kms:CreateGrant` on each key | Postgres, Redis, EBS volumes, and Kubernetes secrets encrypted with a customer-managed key | `rds_kms_key_arn`, `elasticache_kms_key_arn`, `ebs_kms_key_arn`, or `eks_secrets_kms_key_arn` is set |

Terraform does not edit the policy of a key you supply, so each key policy already has to allow the deploying identity and the services that use the key. The [README](README.md#encrypt-with-customer-managed-kms-keys) lists what each key policy needs.

On an existing VPC, `enable_smithdb = true` tags each subnet in `private_subnets` with `karpenter.sh/discovery`, which needs `ec2:CreateTags` and `ec2:DeleteTags` on those subnets. Set `smithdb_karpenter_subnet_selector` to skip the tags.

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

An account whose SCP or IAM policy requires a permissions boundary on `iam:CreateRole` rejects every role created without one. Set `iam_permissions_boundary_arn` to the required boundary, and the module sets it on every role it creates. `iam_role_path` and `prefix_iam_role_names` meet a policy that limits role paths or names. See [IAM permissions boundary, path, and role names](README.md#iam-permissions-boundary-path-and-role-names).

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

The operator who runs the Make targets needs these permissions as well, where `<base_name>` is `<name_prefix>-<environment>`:

| Target | Actions |
|--------|---------|
| `make kubeconfig`, `make deploy` | `eks:DescribeCluster` |
| `make setup-env` | `ssm:PutParameter` and `ssm:GetParameter` on `/langsmith/<base_name>/*`. The script writes the application secrets to Parameter Store, where External Secrets reads them |
| `make purge-secrets`, and `manage-ssm.sh` | `ssm:GetParametersByPath`, `ssm:DeleteParameter`, and `ssm:DeleteParameters` on `/langsmith/<base_name>/*`, in addition to the `make setup-env` actions |
| `make tls` | `acm:RequestCertificate`, `acm:DescribeCertificate`, `route53:ListHostedZones`, `route53:ChangeResourceRecordSets`, and `elasticloadbalancing:DescribeLoadBalancers` |

With `ssm_kms_key_arn` set, the SSM targets also need `kms:Encrypt` and `kms:Decrypt` on that key.

## Verify access before the first apply

Run `make preflight`. It stops with exit 1 when Terraform is older than 1.11, the version `versions.tf` requires. It confirms credentials with `aws sts get-caller-identity`, prints the account, identity, and region, and then makes one read-only call per service. A denial on any required service stops the script with exit 1 and names the actions that service needs.

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
| IAM | `iam:GetPolicy` on the Engine policy | Only when `enable_engine = true`. A missing policy stops the script. A denial warns only |

A read-only call that succeeds does not prove the create action behind it is allowed. The read-only pass never tests `iam:PassRole`, KMS, CloudWatch Logs, SQS, or EventBridge, and never checks service quotas.

After the read-only pass, the script asks the IAM policy simulator whether the identity can call `iam:CreateRole`, `iam:PassRole`, `iam:CreateInstanceProfile`, `ec2:CreateVpcEndpoint`, `ec2:CreateTags`, `kms:CreateKey`, and `sqs:CreateQueue`. A denial there warns rather than exits. The simulator tests each action against any resource, so a policy scoped to the deployment's ARNs can show a denial that the apply would not hit. The step needs `iam:SimulatePrincipalPolicy`, plus `iam:GetRole` for an assumed role, and warns that it was skipped without them.

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
| `<base_name>-eso` | `external-secrets/external-secrets` | `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` on `/langsmith/<base_name>/*`, plus `kms:Decrypt` on `ssm_kms_key_arn` when it is set | Always |
| `<cluster-name>-irsa-role` | Every service account in `langsmith_namespace` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the LangSmith bucket, plus `kms:Decrypt` and `kms:GenerateDataKey` when `s3_kms_key_arn` is set. With `enable_bedrock_access = true`, `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream` on foundation models and inference profiles, and `bedrock:ListFoundationModels` and `bedrock:GetFoundationModel` | `create_langsmith_irsa_role = true` (the default) |
| `<cluster-name>-cert-manager` | `cert-manager/cert-manager` | `route53:ChangeResourceRecordSets` and `route53:ListResourceRecordSets` on the hosted zone, `route53:GetChange`, `route53:ListHostedZonesByName` | `create_cert_manager_irsa = true` |
| `<base_name>-engine-irsa` | Engine's API server and queue service accounts | `AmazonBedrockMantleInferenceAccess` (AWS managed), or the policy in `engine_bedrock_policy_arn`. Also the `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` access of the LangSmith role, and its Bedrock `InvokeModel` access when `enable_bedrock_access = true` | `enable_engine = true` |
| `<base_name>-smithdb-irsa` | The SmithDB service account | Object access on the SmithDB bucket, plus `kms:Decrypt` and `kms:GenerateDataKey` when `s3_kms_key_arn` is set | `enable_smithdb = true` |
| Karpenter controller and node roles | The Karpenter service account, and `ec2.amazonaws.com` | Policies the module creates for node provisioning and the interruption queue | `enable_smithdb = true` |
| `<base_name>-sandbox-host` | `ec2.amazonaws.com` | The node group policies above | `enable_sandboxes = true` |
| `<base_name>-bastion-bastion`, or `<base_name>-bastion` with `fix_bastion_names = true`, with an instance profile | `ec2.amazonaws.com` | `AmazonSSMManagedInstanceCore`, plus `eks:DescribeCluster` and `eks:ListClusters`. With `bastion_cluster_admin = true`, an EKS access entry with `AmazonEKSClusterAdminPolicy` | `create_bastion = true` |

The LangSmith role also gets `rds-db:connect` for one database user when `postgres_iam_database_authentication_enabled = true` and `postgres_iam_database_user` is set.

`create_langsmith_irsa_role = false` is not a way to deploy without creating IAM, because `make init-values` annotates the LangSmith service accounts with this role's ARN. To use roles your IAM team created, set `existing_iam_role_arns`. It covers every role above except the bastion role, with `node_group` covering the sandbox host too, and the module attaches no policies to a role you supply. The `iam_role_trust_policies` output gives the trust policy each supplied IRSA role needs. See [use existing IAM roles](README.md#iam-permissions-boundary-path-and-role-names).

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
