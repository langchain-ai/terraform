data "aws_vpc" "self_hosted" {
  id = var.self_hosted_vpc_id
}

data "aws_route_tables" "self_hosted" {
  count  = var.self_hosted_route_table_ids == null ? 1 : 0
  vpc_id = var.self_hosted_vpc_id
}

locals {
  self_hosted_cidrs = data.aws_vpc.self_hosted.cidr_block_associations[*].cidr_block
  self_hosted_route_table_ids = (
    var.self_hosted_route_table_ids != null
    ? var.self_hosted_route_table_ids
    : toset(data.aws_route_tables.self_hosted[0].ids)
  )

  cidr_ranges = {
    for c in distinct(concat(local.self_hosted_cidrs, [var.data_plane_vpc_cidr_block])) : c => [
      sum([for i, octet in split(".", cidrhost(c, 0)) : tonumber(octet) * pow(256, 3 - i)]),
      pow(2, 32 - tonumber(split("/", c)[1])),
    ]
  }
  data_plane_range = local.cidr_ranges[var.data_plane_vpc_cidr_block]

  overlapping_self_hosted_cidrs = [
    for c in local.self_hosted_cidrs : c
    if local.cidr_ranges[c][0] < local.data_plane_range[0] + local.data_plane_range[1]
    && local.data_plane_range[0] < local.cidr_ranges[c][0] + local.cidr_ranges[c][1]
  ]
}

resource "aws_vpc_peering_connection" "data_plane" {
  vpc_id        = var.self_hosted_vpc_id
  peer_vpc_id   = var.data_plane_vpc_id
  peer_owner_id = var.data_plane_account_id
  peer_region   = var.data_plane_region
  auto_accept   = false

  tags = merge(var.tags, {
    Name       = "${var.name}-peering"
    managed_by = "customer"
  })

  lifecycle {
    ignore_changes = [tags, tags_all]

    precondition {
      condition     = length(local.overlapping_self_hosted_cidrs) == 0
      error_message = "The data plane VPC CIDR ${var.data_plane_vpc_cidr_block} overlaps self-hosted VPC CIDRs ${join(", ", local.overlapping_self_hosted_cidrs)}. Peering requires that no CIDR on either VPC overlaps."
    }
  }
}

resource "aws_route" "to_data_plane" {
  for_each = local.self_hosted_route_table_ids

  route_table_id            = each.value
  destination_cidr_block    = var.data_plane_vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.data_plane.id
}

resource "aws_iam_role_policy" "assume_data_plane_smithdb_role" {
  name = "${var.name}-assume-smithdb-role"
  role = regex("[^/]+$", var.self_hosted_role_arn)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeDataPlaneSmithDBRole"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = var.data_plane_smithdb_role_arn
    }]
  })
}
