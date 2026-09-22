data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  artifact_account_id = "808407022534"
  account_id          = data.aws_caller_identity.current.account_id
  partition           = data.aws_partition.current.partition
  tags                = merge(var.tags, { managed_by = "customer" })
  cluster_arns = [for region in sort(tolist(var.regions)) :
    "arn:${local.partition}:eks:${region}:${local.account_id}:cluster/*-smith-eks"
  ]
}

resource "aws_iam_instance_profile" "karpenter" {
  name = "byoc-smith-karpenter-node-profile"
  path = "/"
  role = aws_iam_role.this["karpenter-node-role"].name
  tags = local.tags
}

resource "aws_iam_service_linked_role" "this" {
  for_each         = var.service_linked_roles_to_create
  aws_service_name = each.value
}
