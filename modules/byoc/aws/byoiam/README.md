# AWS BYOIAM

Customer-run Terraform that creates 16 shared LangSmith BYOC IAM roles, their
policies, and a Karpenter instance profile. Apply **once per AWS account** for all
configured regions and data planes.

## Usage

Use Terraform >= 1.7 and AWS provider 6.x, authenticated to your AWS account
with permission to provision IAM resources.
In your Terraform configuration:

```hcl
module "byoiam" {
  source = "github.com/langchain-ai/terraform//modules/byoc/aws/byoiam?ref=main"

  regions = ["us-east-1", "us-west-1"]
}
```

| Input | Purpose |
| --- | --- |
| `regions` | Required AWS regions where the roles may operate. |
| `permissions_boundary_arn` | Optional boundary for all 16 roles. Must allow their required operations. |
| `service_linked_roles_to_create` | Missing service-linked roles to create; defaults to none. Import existing roles or leave them out. |
| `tags` | Customer tags. `managed_by` is reserved and enforced as `customer`. |

## Provisioning requirements

- Prepare service-linked roles for EKS, node groups, ELB, RDS, ElastiCache,
  Auto Scaling, and Spot where needed.

Create these resources before setting `allow_iam_management_permissions = false`
in the [customer provisioning-role module](../langsmith-byoc-role/README.md).
Configure LangSmith to observe these IAM resources instead of managing their
lifecycle. The provisioning-role switch does not configure observe mode itself.

The outputs expose the shared role names and ARNs, Karpenter instance profile
name, and Karpenter controller policy ARN. Keep this module in customer-managed
Terraform state and coordinate removal with LangChain; all data planes in the
account depend on these shared resources.

## Permission scope

Roles are separated by function but shared across deployments; they do not
provide IAM isolation between data planes in the same account.

- **Database authentication:** `rds-db:connect` covers `langsmith_admin` and
  `smithdb` users in the configured account/regions.
- **Master secrets:** setup roles require the AWS-owned
  `aws:rds:primaryDBInstanceArn` tag to match `*-smith-postgres` or
  `*-smithdb-metastore`, respectively.
- **External Secrets:** reads `langsmith/*` and SmithDB master secrets restricted
  by the same AWS-owned tag.
- **S3:** each role accesses its matching `*-smith-blob`, `*-smithdb-blob`,
  `*-smith-clickhouse-backups`, or `*-smith-sandbox-snapshots` buckets, restricted
  to the customer account.
- **Controllers:** Karpenter and LBC use Pod Identity cluster tags to scope
  mutations.
