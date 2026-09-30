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
| `service_linked_roles_to_create` | Missing service-linked roles to create. Defaults to none. Import existing roles or leave them out. |
| `tags` | Customer tags. `managed_by` is reserved and enforced as `customer`. |

## Provisioning requirements
Prepare service-linked roles for EKS, node groups, ELB, RDS, ElastiCache,
  Auto Scaling, and Spot where needed.

Create these resources, then set `allow_iam_management_permissions = false`
in the [customer provisioning-role module](../langsmith-byoc-role/README.md).
At time of data plane creation, toggle off IAM role creation.

The outputs expose the shared role names and ARNs, Karpenter instance profile
name, and Karpenter controller policy ARN.
