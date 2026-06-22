# LangSmith BYOC - AWS Customer Role

Provisions the IAM roles in **your AWS account** that let the LangSmith control plane stand up and manage BYOC data planes in your account.

This module creates two roles:

| Role | Purpose | Trust |
|------|---------|-------|
| `var.role_name` (you choose) | Assumed by the LangSmith control-plane Crossplane controller to provision and manage resources. | Allow `var.control_plane_reconcile_role_arn`, gated on `sts:ExternalId` |
| `LangSmithBYOCBreakGlass` | Customer-side break-glass role for approved LangChain support engineers during incidents. | Deny by default. Optionally allow the LangSmith BYOCBreakGlass Identity Center permission set, gated on approved user IDs |

## Prerequisites

1. An AWS account where the LangSmith data plane will live, and AWS credentials with permission to create IAM roles and policies in it.
2. Terraform `>= 1.5` and the AWS provider `~> 6.0`.
3. The `control_plane_reconcile_role_arn` provided by LangChain.
4. An `external_id` value that you generate and provide to LangChain at data plane creation time. It is used in the trust policy `sts:ExternalId` condition.
5. For break-glass access, the LangChain engineer Identity Store user IDs and LangChain email addresses provided by LangChain.

Current LangSmith control-plane role values:

| Control-plane region | `control_plane_reconcile_role_arn` |
|----------------------|------------------------------------|
| `us-east-2` | `arn:aws:iam::808407022534:role/LangSmithCrossPlaneRole` |

## Usage

### As a root module

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

module "langsmith_byoc_role" {
  source = "github.com/langchain-ai/terraform//modules/byoc/aws/langsmith-byoc-role?ref=main"

  role_name                        = "langsmith-byoc"
  control_plane_reconcile_role_arn = "arn:aws:iam::<langsmith-account-id>:role/<crossplane-irsa-role>"
  external_id                      = var.external_id

  break_glass_identitystore_user_ids = [
    "<langchain-identity-store-user-id>",
  ]
  break_glass_source_identities = [
    "<langchain-engineer-email>",
  ]

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

output "role_arns" {
  value = {
    crossplane  = module.langsmith_byoc_role.crossplane_role_arn
    break_glass = module.langsmith_byoc_role.break_glass_role_arn
  }
}
```

After `terraform apply`, share the `crossplane_role_arn` and `break_glass_role_arn` outputs with the LangChain team.

We recommend keeping Terraform state in remote storage when possible, rather than storing it only on a local workstation.

### Enabling break-glass assume-role access

`LangSmithBYOCBreakGlass` defaults to `Deny`. To allow an approved LangChain engineer to assume the role, set `allow_break_glass_access = true` and include that engineer's Identity Store user ID and SourceIdentity email (the engineer will provide it to you):

```hcl
allow_break_glass_access = true

break_glass_identitystore_user_ids = [
  "<langchain-identity-store-user-id>",
]

break_glass_source_identities = [
  "<langchain-engineer-email>",
]
```

The Identity Store user ID is the strict authorization boundary. The SourceIdentity value is the service identity used for CloudTrail readability and should match the engineer's LangChain email.

Set `allow_break_glass_access` back to `false`, and remove the allowed identities when the break glass access is complete.

### Public-internet ingress

If your deployment exposes the LangSmith data plane on the public internet (Route 53 public hosted zones + ACM public certs), set:

```hcl
allow_public_ingress = true
```

This grants the additional Route 53 public-zone permissions needed for ACM DNS-01 validation. Leave it off (the default) for private/VPC-only deployments.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `role_name` | `string` | yes | - | Name of the Crossplane-assumed IAM role created in your account. |
| `control_plane_reconcile_role_arn` | `string` | yes | - | ARN of the LangSmith control-plane principal trusted to assume the role. |
| `external_id` | `string` | yes | - | Per-tenant `sts:ExternalId` value. Treat as a secret. |
| `break_glass_identitystore_user_ids` | `list(string)` | yes | - | IAM Identity Center user IDs allowed to assume the customer-side break-glass role. |
| `break_glass_source_identities` | `list(string)` | yes | - | SourceIdentity values allowed when assuming the customer-side break-glass role. |
| `allow_break_glass_access` | `bool` | no | `false` | Allows approved LangSmith Identity Center users to assume the customer-side break-glass role. |
| `langsmith_control_plane_account_id` | `string` | no | `808407022534` | AWS account ID of the LangSmith control plane. |
| `langsmith_byoc_break_glass_principal_arn_patterns` | `list(string)` | no | BYOCBreakGlass SSO role patterns | IAM principal ARN patterns for LangSmith Identity Center BYOC break-glass sessions. |
| `tags` | `map(string)` | no | `{}` | Tags applied to all roles and policies. |
| `allow_public_ingress` | `bool` | no | `false` | Grants the Route 53 public-zone permissions needed when exposing the data plane on the public internet. |

## Outputs

| Output | Description |
|--------|-------------|
| `crossplane_role_arn` | ARN of the Crossplane-assumed control role. |
| `break_glass_role_arn` | ARN of the customer-side LangSmith BYOC break-glass role. |

## Security model

### Crossplane control role

The role's trust policy allows exactly one principal (`var.control_plane_reconcile_role_arn`) and requires the matching `sts:ExternalId`.

The attached permissions are split into managed policies, scoped to the AWS surface Crossplane needs to operate a LangSmith data plane:

| Policy suffix | Surface |
|---------------|---------|
| `-vpc` | VPC, subnets, NAT, route tables, endpoints, security groups, VPC flow logs |
| `-ec2-eni` | `DetachNetworkInterface` on data-plane ENIs (Karpenter node teardown) |
| `-iam` | IAM role lifecycle for the data plane (EKS, IRSA, Karpenter, etc.) |
| `-iam-karpenter-eks-profiles` | EC2 instance profiles for Karpenter and EKS, plus the Karpenter controller customer-managed policy |
| `-eks` | EKS cluster, node groups, add-ons |
| `-elbv2` | Application Load Balancers for ingress |
| `-data` | RDS (Postgres), Secrets Manager, KMS |
| `-storage` | S3 (trace blobs), ElastiCache (Redis) |
| `-lambda` | Lambda + EventBridge for periodic jobs |
| `-dns` | Route 53, ACM (private by default; public when `allow_public_ingress = true`) |

The exact statements are in `policies/*.json`.

### Break-glass role

The `LangSmithBYOCBreakGlass` role exists so that, during an incident, approved LangChain support engineers can assume into your account with a documented, auditable scope.

The trust policy defaults to `Effect = "Deny"`. When `allow_break_glass_access = true`, it allows the LangSmith control plane account root, but only when all of these conditions match:

- the caller is an `AWSReservedSSO_BYOCBreakGlass_*` IAM Identity Center role in the LangSmith control plane account
- `identitystore:UserId` is in `break_glass_identitystore_user_ids`
- `sts:SourceIdentity` is in `break_glass_source_identities`

The Identity Store user ID will be provided to you by a langchain user, and ensures that only their credentials can be used to assume the role.
The source identity email will be added for better auditing in CloudTrail.

The break-glass role only carries an inline `eks:DescribeCluster` permission on `*-smith-eks` clusters at the module layer. Kubernetes access is controlled separately with EKS access entries in each target cluster and region.

## Operational notes

- The Crossplane role's permissions are intentionally broad within the listed surfaces. Tightening them further breaks the control plane's ability to reconcile the data plane on upgrades. If you need tighter scope, discuss with LangChain first.
- `data.aws_caller_identity.current` is used at plan time to template account IDs into the policies. Run `terraform apply` from credentials in the **target** account, not the LangSmith control-plane account.
- Removing this module will delete both roles and all attached policies. The LangSmith data plane will lose all control-plane reconciliation; do not apply destroys without coordinating with LangChain.

## License

Apache 2.0 - see the repository [LICENSE](../../../../LICENSE).
