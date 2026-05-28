# LangSmith BYOC — AWS Customer Role

Provisions the IAM roles in **your AWS account** that let the LangSmith control plane stand up and manage a LangSmith data plane on your behalf, for BYOC.

This module creates four roles:

| Role | Purpose | Trust |
|------|---------|-------|
| `var.role_name` (you choose) | Assumed by the LangSmith control-plane Crossplane controller to provision and manage EKS, VPC, RDS, ElastiCache, S3, IAM, etc. | Allow `var.control_plane_reconcile_role_arn`, gated on `sts:ExternalId` |
| `LangSmithBYOCReadOnlyAccess` | Break-glass read-only EKS access for LangChain support during incidents. | **Deny by default**; flipped to Allow per incident |
| `LangSmithBYOCClusterAdminAccess` | Break-glass EKS cluster-admin (no data-tier reach) for LangChain support. | **Deny by default**; flipped to Allow per incident |
| `LangSmithBYOCDataAccess` | Break-glass full admin including data-tier reach for LangChain support. | **Deny by default**; flipped to Allow per incident |

## Prerequisites

1. An AWS account where the LangSmith data plane will live, and AWS credentials with permission to create IAM roles and policies in it.
2. Terraform `>= 1.5` and the AWS provider `~> 6.0`.
3. Three values provided to you out-of-band by LangChain:
   - `control_plane_reconcile_role_arn` — ARN of the LangSmith control-plane Crossplane IRSA role that will assume into your account.
   - `external_id` — Per-tenant secret used in the trust policy `sts:ExternalId` condition. Treat as sensitive; do not commit to source control in plaintext.
   - `langchain_break_glass_role_arn` — ARN of the LangChain support principal that the break-glass roles trust (Deny by default).

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

  role_name                      = "langsmith-byoc"
  control_plane_reconcile_role_arn         = "arn:aws:iam::<langsmith-account-id>:role/<crossplane-irsa-role>"
  external_id                    = var.external_id
  langchain_break_glass_role_arn = "arn:aws:iam::<langsmith-account-id>:role/<break-glass-role>"

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

output "role_arns" {
  value = {
    crossplane     = module.langsmith_byoc_role.crossplane_role_arn
    readonly       = module.langsmith_byoc_role.readonly_access_role_arn
    cluster_admin  = module.langsmith_byoc_role.cluster_admin_access_role_arn
    data_access    = module.langsmith_byoc_role.data_access_role_arn
  }
}
```

After `terraform apply`, share all four output ARNs with the LangChain team.

### Public-internet ingress

If your deployment exposes the LangSmith data plane on the public internet (Route 53 public hosted zones + ACM public certs), set:

```hcl
allow_public_ingress = true
```

This grants the additional Route 53 public-zone permissions needed for ACM DNS-01 validation. Leave it off (the default) for private/VPC-only deployments.

## Inputs

| Variable | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `role_name` | `string` | yes | — | Name of the Crossplane-assumed IAM role created in your account. |
| `control_plane_reconcile_role_arn` | `string` | yes | — | ARN of the LangSmith control-plane principal trusted to assume the role. |
| `external_id` | `string` | yes | — | Per-tenant `sts:ExternalId` value. Treat as a secret. |
| `langchain_break_glass_role_arn` | `string` | yes | — | ARN of the LangChain support principal trusted (Deny by default) by the break-glass roles. |
| `tags` | `map(string)` | no | `{}` | Tags applied to all roles and policies. |
| `allow_public_ingress` | `bool` | no | `false` | Grants the Route 53 public-zone permissions needed when exposing the data plane on the public internet. |

## Outputs

| Output | Description |
|--------|-------------|
| `crossplane_role_arn` | ARN of the Crossplane-assumed control role. |
| `readonly_access_role_arn` | ARN of the read-only break-glass role. |
| `cluster_admin_access_role_arn` | ARN of the cluster-admin break-glass role. |
| `data_access_role_arn` | ARN of the full-admin (incl. data tier) break-glass role. |

## Security model

### Crossplane control role

The role's trust policy allows exactly one principal (`var.control_plane_reconcile_role_arn`) and requires the matching `sts:ExternalId`. Both must be presented for any assume-role call to succeed. If either the role ARN or the External ID is compromised on its own, the trust still fails.

The attached permissions are split into nine managed policies, scoped to the AWS surface Crossplane needs to operate a LangSmith data plane:

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

The exact statements are in `policies/*.json` — read them before applying. Account IDs are templated in at apply time; no hardcoded principals reach the JSON files.

### Break-glass roles

The three `LangSmithBYOC*Access` roles exist so that, during an incident, LangChain support can assume into your account with a documented, auditable scope — but only when you explicitly enable it.

**They ship with `Effect = "Deny"` on the LangChain break-glass principal.** Assuming any of them will fail until you flip the relevant statement to `Effect = "Allow"`. Flipping back to Deny ends the access.

To preserve a per-incident flip across `terraform apply` runs, the resources include:

```hcl
lifecycle {
  ignore_changes = [assume_role_policy]
}
```

This means Terraform will not revert an Allow you set manually in the AWS console — but it also means Terraform will not detect drift on these trust policies. **Audit them periodically** (e.g., via AWS Access Analyzer, CloudTrail `AssumeRole` events, or a scheduled `aws iam get-role`).

The break-glass roles only carry an inline `eks:DescribeCluster` permission on `*-smith-eks` clusters at the module layer; the actual access tier (read-only vs. cluster-admin vs. data) is enforced by the EKS Access Entry that the LangSmith control plane creates separately for each role.

## Operational notes

- The Crossplane role's permissions are intentionally broad within the listed surfaces. Tightening them further breaks the control plane's ability to reconcile the data plane on upgrades — if you need tighter scope (e.g., resource-name prefixes), discuss with LangChain first.
- `data.aws_caller_identity.current` is used at plan time to template account IDs into the policies. Run `terraform apply` from credentials in the **target** account, not the LangSmith control-plane account.
- Removing this module will delete all four roles and all attached policies. The LangSmith data plane will lose all control-plane reconciliation; do not apply destroys without coordinating with LangChain.

## License

Apache 2.0 — see the repository [LICENSE](../../../../LICENSE).
