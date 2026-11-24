# AWS BYOIAM

Use this module to create the LangSmith BYOC IAM roles, their
policies, and a Karpenter instance profile. 

Apply **once per AWS account** for all
configured regions and data planes.

## Usage

Use Terraform >= 1.7 and AWS provider 6.x, authenticated to your AWS account
with permission to provision IAM resources.

Example:
```hcl
module "byoiam" {
  source = "github.com/langchain-ai/terraform//modules/byoc/aws/byoiam?ref=main"

  regions = ["us-east-1", "us-west-1"]
}
```

| Input | Purpose |
| --- | --- |
| `regions` | AWS regions where data planes are to be deployed. |
| `permissions_boundary_arn` | Optional boundary for all roles. |
| `role_names` | Optional. Custom names for some or all roles, keyed by role purpose (the keys of the `role_names` output). Unset keys keep the default `byoc-smith-*` names. |
| `karpenter_instance_profile_name` | Optional. Custom name for the Karpenter instance profile. |
| `karpenter_controller_policy_name` | Optional. Custom name for the Karpenter controller policy. |
| `ebs_kms_key_arns` | Optional. Customer-managed KMS keys for EBS volumes: keys of encrypted custom AMI snapshots and the EBS default encryption key. The Karpenter controller and EBS CSI roles may use them through EC2. The key owner must also allow those roles. |
| `service_linked_roles_to_create` | Missing service-linked roles to create. Defaults to none. Import existing roles or leave them out. |
| `smithdb_migration_writer_principal_arns` | Optional. Self-hosted LangSmith roles or users that may assume the SmithDB role during a self-hosted to BYOC migration. Set to `[]` after the migration. |
| `workload_migration_source_blob_bucket_arns` | Optional. Self-hosted blob buckets the workload role may read to copy run attachments during a migration. Set to `[]` after the migration. |
| `workload_migration_source_blob_kms_key_arns` | Optional. KMS keys of those buckets. The workload role may decrypt objects of those buckets only. |
| `tags` | Customer tags. `managed_by` is reserved and enforced as `customer`. |

## Provisioning requirements
Prepare service-linked roles for EKS, node groups, ELB, RDS, ElastiCache,
  Auto Scaling, and Spot where needed.

Create these resources, then set `allow_iam_management_permissions = false`
in the [customer provisioning-role module](../langsmith-byoc-role/README.md).
At time of data plane creation, toggle off IAM role creation.

Engine: the shared workload role includes native Bedrock inference and Mantle
access, and trusts Engine service accounts. Engine remains opt-in per data plane.

The outputs expose the shared role names and ARNs, Karpenter instance profile
name, and Karpenter controller policy ARN.

### Custom names

Use `role_names`, `karpenter_instance_profile_name`, and
`karpenter_controller_policy_name` when your organization requires its own IAM
naming convention, for example a mandatory prefix:

```hcl
module "byoiam" {
  source = "github.com/langchain-ai/terraform//modules/byoc/aws/byoiam?ref=main"

  regions                  = ["us-east-1"]
  permissions_boundary_arn = "arn:aws:iam::<account-id>:policy/<boundary>"
  role_names = {
    eks-cluster-role        = "ACME-langsmith-eks-cluster"
    postgres-setup-iam-role = "ACME-langsmith-postgres-setup"
  }
  karpenter_instance_profile_name  = "ACME-langsmith-karpenter-node"
  karpenter_controller_policy_name = "ACME-langsmith-karpenter-controller"
}
```

IAM role names are limited to 64 characters. Custom names do not match the
provisioning role's default `*-smith-*` allowlists. Always pass these outputs
to the [customer provisioning-role module](../langsmith-byoc-role/README.md);
with default names the grants are redundant, with custom names they are required:

```hcl
byoiam_role_arns                       = values(module.byoiam.role_arns)
byoiam_instance_profile_name           = module.byoiam.karpenter_instance_profile_name
byoiam_karpenter_controller_policy_arn = module.byoiam.karpenter_controller_policy_arn
```

Keep the `role_names` and `karpenter_instance_profile_name` outputs until you
create the data plane; you paste them into the data plane setup in LangSmith.
You do not paste the Karpenter controller policy name into LangSmith. The
provisioning role still reads that policy, so pass its ARN as shown above.
