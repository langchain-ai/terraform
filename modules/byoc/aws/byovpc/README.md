# AWS BYOVPC reference module

This module creates standardized AWS networking for LangSmith BYOC, either in a new VPC or in an existing VPC you supply. Use it directly or copy and adapt it to your networking requirements. LangSmith validates the supplied network configuration during data-plane creation.

The module provisions networking only. Create the customer-side IAM role separately with [`langsmith-byoc-role`](../langsmith-byoc-role/README.md).

## Requirements

- Terraform >= 1.11.0 and the HashiCorp AWS provider >= 6.62.0, < 7.0.0.
- Configure the AWS provider to your AWS account and data-plane region. Select a region with at least two available standard availability zones and regional NAT gateway support when NAT is enabled.
- Keep Terraform state in your own backend. This reusable module does not configure a provider or backend.

## What it creates

By default, the module creates:

- A DNS-enabled VPC.
- Two or three private application subnets, selected automatically from the provider region. Three are used when available, with an automatic fallback to two. Availability zones can be overridden explicitly.
- Matching isolated database subnets.
- One route table per private application subnet and one shared isolated database route table.
- An Internet Gateway and a regional NAT gateway for application-subnet egress.
- A default security group with no ingress or egress rules.
- S3-backed VPC flow logs for accepted and rejected traffic.

Set `publicly_accessible = true` to create matching public subnets and their Internet Gateway route. These subnets do not automatically assign public IP addresses. Use this setting if you are going to deploy LangSmith BYOC with internet-facing load balancers.

For the default `10.0.0.0/16` VPC across three availability zones, the canonical layout is:

| Tier | CIDRs |
| --- | --- |
| Private application | `10.0.0.0/18`, `10.0.64.0/18`, `10.0.128.0/18` |
| Private database | `10.0.192.0/24`, `10.0.193.0/24`, `10.0.194.0/24` |
| Public | `10.0.195.0/24`, `10.0.196.0/24`, `10.0.197.0/24` |

- The VPC CIDR must be a network-aligned RFC1918 IPv4 prefix from `/16` through `/18`.
- Each subnet tier can be overridden, with exactly one subnet per selected availability zone. 
- Custom subnet CIDRs must be:
  - Network-aligned
  - Contained within the VPC
  - Non-overlapping across all tiers 
  - Sized for your workloads. 
- The module checks IPv4 syntax and subnet counts. LangSmith perform further network validation upon data plane creation.

## Optional connectivity

Customers can opt into:

- AWS service endpoints: an S3 Gateway endpoint and a set of Interface endpoints.
- A PrivateLink endpoint for data-plane to control-plane traffic.

Customize `interface_endpoint_services` to the supported services you need. Enabling endpoints does not remove NAT routes or provide all external connectivity needed by workloads.

## Flow logs

Flow logs are enabled by default with `traffic_type = "ALL"`. Set `enable_vpc_flow_logs = false` to disable flow logs and creation of their S3 bucket.

The bucket defaults to S3-managed encryption (SSE-S3). To use a customer-managed KMS key (SSE-KMS), set `flow_logs_kms_key_arn` in your module call:

```hcl
flow_logs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
```

- Supply a symmetric encryption key in the bucket's region using its full key ARN, not a key ID or alias. 
- Before enabling it, configure the key policy to permit `delivery.logs.amazonaws.com` to deliver encrypted logs, following the [AWS key-policy requirements for VPC flow logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-s3-cmk-policy.html). 

Leave `flow_logs_kms_key_arn = null` (the default) to use SSE-S3. Security scanners requiring a customer-managed key may still report the default configuration. Changing the key setting affects new objects; existing logs retain their original encryption.

## Customer-managed responsibilities

This module deliberately does not manage:

- Network Firewall or other egress-filtering policy.
- Network ACL customization.
- Transit Gateway, peering, VPN, or custom DNS integrations.
- Workload resources or workload security groups.

## Usage

```hcl
provider "aws" {
  region = "us-east-1"
}

module "langsmith_byovpc" {
  source = "../terraform/modules/byoc/aws/byovpc"

  name           = "langsmith-production"
  vpc_cidr_block = "10.0.0.0/16"

  tags = {
    Environment = "production"
  }
}

output "langsmith_network_config" {
  value = module.langsmith_byovpc.langsmith_network_config
}
```

- For internet-facing load balancers, add `publicly_accessible = true`. 
- For an explicit two-AZ deployment, configure the provider for `us-west-1` and set `availability_zones = ["us-west-1a", "us-west-1c"]`, after checking that both zones are available in your account.
- For centralized customer-managed egress, set both `create_nat_gateway = false` and `create_internet_gateway = false`, then add the required routes outside this module. 
- To enable data-plane-to-control-plane PrivateLink:

```hcl
module "langsmith_byovpc" {
  source = "../terraform/modules/byoc/aws/byovpc"

  name                             = "langsmith-production"
  vpc_cidr_block                   = "10.0.0.0/16"
  enable_control_plane_privatelink = true
}
```

PrivateLink targets the LangSmith AWS control-plane endpoint service in `us-east-2` and creates private DNS zones for both `aws.api.smith.langchain.com` and `beacon.aws.langchain.com`. Confirm endpoint-service access and cross-region availability with LangChain before enabling it.

## Use an existing VPC

Set `existing_vpc_id` and match `vpc_cidr_block` to its primary CIDR. The VPC must have DNS support and DNS hostnames enabled. Choose unused subnet ranges:

```hcl
module "langsmith_byovpc" {
  source = "../terraform/modules/byoc/aws/byovpc"

  existing_vpc_id     = "vpc-0123456789abcdef0"
  vpc_cidr_block      = "10.20.0.0/16"
  availability_zones = ["us-east-1a", "us-east-1b"]

  private_app_subnet_cidrs = ["10.20.0.0/18", "10.20.64.0/18"]
  private_db_subnet_cidrs  = ["10.20.128.0/24", "10.20.129.0/24"]

  create_internet_gateway      = false
  existing_internet_gateway_id = "igw-0123456789abcdef0"
}
```

This creates the surrounding networking while leaving VPC settings and its default security group unmanaged. Omit the gateway inputs to create a new Internet Gateway if none is attached. Flow logs cover the entire VPC; disable them if logging already exists.

### Reuse existing subnets

Replace a tier's CIDR inputs with subnet IDs from the same VPC, one per AZ in `availability_zones` order. Omitted tiers are created normally:

```hcl
existing_private_app_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
existing_private_db_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004"]
create_nat_gateway             = false
```

Public subnet reuse also requires `publicly_accessible = true`. Supplied subnets retain their routing and tags; you manage egress, database isolation, and load-balancer discovery tags. Application subnet reuse requires NAT creation disabled.

Outputs and Interface/PrivateLink endpoints use the selected subnets. Route-table outputs and S3 Gateway endpoint associations cover only module-created tables; manage S3 associations for reused subnets separately using `s3_gateway_endpoint_id`.

Switching existing deployments from created resources to supplied IDs requires a separate state migration to avoid planned deletions.

## Inputs

All inputs are optional. Full types and validation rules are in [`variables.tf`](variables.tf).

| Input | Default | Purpose |
| --- | --- | --- |
| `name` | `"dataplane"` | Resource prefix, 2–32 lowercase letters, digits, or hyphens. |
| `existing_vpc_id` | `null` | Use an existing VPC and leave its default security group unmanaged. |
| `existing_internet_gateway_id` | `null` | Reuse a gateway attached to the supplied VPC; requires `create_internet_gateway = false`. |
| `vpc_cidr_block` | `"10.0.0.0/16"` | Primary network-aligned RFC1918 IPv4 prefix, `/16`–`/18`; must match a supplied VPC. |
| `availability_zones` | `[]` | Automatically select up to three AZs, or supply two or three unique AZ names. |
| `existing_private_app_subnet_ids` | `null` | Application subnets in AZ order; requires `create_nat_gateway = false`. |
| `existing_private_db_subnet_ids` | `null` | Database subnets in AZ order. |
| `existing_public_subnet_ids` | `null` | Public subnets in AZ order; requires `publicly_accessible`. |
| `private_app_subnet_cidrs` | `null` | Override application subnet CIDRs in AZ order. |
| `private_db_subnet_cidrs` | `null` | Override isolated database subnet CIDRs in AZ order. |
| `public_subnet_cidrs` | `null` | Override public subnet CIDRs in AZ order. |
| `publicly_accessible` | `false` | Create public subnets for internet-facing load balancers. |
| `create_internet_gateway` | `true` | Attach an Internet Gateway. |
| `create_nat_gateway` | `true` | Create regional NAT and application egress routes. |
| `enable_vpc_endpoints` | `false` | Create S3 Gateway and AWS Interface endpoints. |
| `interface_endpoint_services` | See `variables.tf` | Unique service names from the module's allowlist. |
| `enable_control_plane_privatelink` | `false` | Create a control-plane endpoint and private DNS. |
| `enable_vpc_flow_logs` | `true` | Record accepted and rejected traffic in S3; set to `false` to disable. |
| `flow_logs_kms_key_arn` | `null` | Customer-managed KMS key ARN for flow-log encryption; `null` uses S3-managed encryption. |
| `aws_marketplace_product_code` | `"5iyery30g5gp8777bzkpum6uq"` | AWS Marketplace attribution via `aws-apn-id`; set to `null` to omit the module-generated tag. |
| `tags` | `{}` | Customer tags; generated `Name` and Marketplace tags take precedence. |

## Outputs

Use `langsmith_network_config` for inputs when creating the data plane.
