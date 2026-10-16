# Self-hosted to BYOC migration

Customer-run Terraform that connects a self-hosted LangSmith VPC to a BYOC
data plane VPC for the duration of a migration.

The module runs in the account that hosts the self-hosted installation.

It creates the peering request and the routes from the self-hosted VPC to the
data plane VPC in one apply. By default every route table in the self-hosted
VPC gets the route; pass `self_hosted_route_table_ids` to limit it to the
subnets that run the LangSmith pods. The routes stay blackhole until the peering
is accepted and carry traffic from then on.

LangChain accepts the request,
adds the return routes, and opens the data plane security group to the
self-hosted CIDR from the data plane side.

## Requirements

- The data plane VPC CIDR must not overlap any CIDR of the self-hosted VPC,
  including secondary CIDRs. AWS rejects peering between overlapping
  networks; the module fails at plan and names the conflicting CIDRs.
- Terraform >= 1.11 and AWS provider 6.x, authenticated to the self-hosted
  account with permission to create peering connections and routes and to
  put an inline policy on the self-hosted LangSmith role.

## Usage

1. Fill in the data plane VPC ID, CIDR, account, region, and data plane SmithDB role
   provided by the LangChain team, and the role your self-hosted installation runs as.
2. Run `terraform apply`. Share the `peering_connection_id` and
   `self_hosted_vpc_cidr_block` outputs with LangChain. LangChain accepts
   the peering from the data plane side; `peering_status` reports `active`
   on the next plan or apply.
3. After the migration completes, wait for LangChain to confirm that the
   data plane has cleared the peering from its configuration.
   Only then run `terraform destroy` here.
4. Once this module is destroyed, the data plane IAM role can turn
   `allow_self_hosted_migration_permissions` back off in the
   [data plane role module](../langsmith-byoc-role/README.md).


```hcl
module "byoc_migration" {
  source = "github.com/langchain-ai/terraform//modules/byoc/aws/self-hosted-byoc-migration?ref=main"

  self_hosted_vpc_id        = "vpc-0fedcba9876543210"
  data_plane_vpc_id         = "vpc-0123456789abcdef0"
  data_plane_vpc_cidr_block = "10.64.0.0/16"
  data_plane_account_id     = "123456789012"
  data_plane_region         = "us-east-2"

  self_hosted_role_arn         = "arn:aws:iam::210987654321:role/langsmith-irsa"
  data_plane_smithdb_role_arn  = "arn:aws:iam::123456789012:role/dp-smith-smithdb-iam-role"
  self_hosted_blob_kms_key_arn = "arn:aws:kms:us-east-1:210987654321:key/11111111-2222-3333-4444-555555555555"
  data_plane_workload_role_arn = "arn:aws:iam::123456789012:role/dp-smith-workload-iam-role"
}
```

| Input | Purpose |
| --- | --- |
| `self_hosted_vpc_id` | VPC of the self-hosted installation. |
| `self_hosted_route_table_ids` | Optional. Route tables that get the route; defaults to every route table in the VPC. |
| `data_plane_vpc_id` | Data plane VPC to peer with. |
| `data_plane_vpc_cidr_block` | Data plane VPC CIDR used for the routes. |
| `data_plane_account_id` | Account that owns the data plane. |
| `data_plane_region` | Region of the data plane VPC. |
| `data_plane_smithdb_role_arn` | Data plane SmithDB role the self-hosted role may assume. |
| `self_hosted_blob_kms_key_arn` | Optional. Customer-managed KMS key of the blob storage bucket. The data plane role gets a decrypt grant on it. |
| `data_plane_workload_role_arn` | Data plane workload role that receives the grant. Required with `self_hosted_blob_kms_key_arn`. |
| `name` | Name prefix for the created resources. |
| `tags` | Extra tags. `managed_by` is set to `customer`. |

## Network egress

The self-hosted pods reach the metastore on TCP 5432 inside the data plane
CIDR. If the self-hosted subnets use a network firewall or restrictive
security group egress, allow that destination before starting the SmithDB
migration.
