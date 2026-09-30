data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required", "opted-in"]
  }
}

data "aws_region" "current" {}

locals {
  vpc_id              = var.existing_vpc_id == null ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
  internet_gateway_id = var.existing_internet_gateway_id == null ? try(aws_internet_gateway.this[0].id, null) : data.aws_internet_gateway.existing[0].id

  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    min(3, length(data.aws_availability_zones.available.names)),
  )
  availability_zone_count = length(local.availability_zones)
  availability_zone_suffixes = {
    for az in local.availability_zones : az => trimprefix(az, data.aws_region.current.region)
  }

  derived_private_app_subnet_cidrs = [
    for index in range(local.availability_zone_count) : cidrsubnet(var.vpc_cidr_block, 2, index)
  ]
  derived_private_db_subnet_cidrs = [
    for index in range(local.availability_zone_count) : cidrsubnet(
      var.vpc_cidr_block,
      8,
      local.availability_zone_count * 64 + index,
    )
  ]
  derived_public_subnet_cidrs = [
    for index in range(local.availability_zone_count) : cidrsubnet(
      var.vpc_cidr_block,
      8,
      local.availability_zone_count * 64 + local.availability_zone_count + index,
    )
  ]

  private_app_subnet_cidrs = var.private_app_subnet_cidrs == null ? local.derived_private_app_subnet_cidrs : var.private_app_subnet_cidrs
  private_db_subnet_cidrs  = var.private_db_subnet_cidrs == null ? local.derived_private_db_subnet_cidrs : var.private_db_subnet_cidrs
  public_subnet_cidrs      = var.public_subnet_cidrs == null ? local.derived_public_subnet_cidrs : var.public_subnet_cidrs

  private_app_subnets = {
    for index, az in local.availability_zones : az => local.private_app_subnet_cidrs[index]
    if var.existing_private_app_subnet_ids == null && try(local.private_app_subnet_cidrs[index], null) != null
  }
  private_db_subnets = {
    for index, az in local.availability_zones : az => local.private_db_subnet_cidrs[index]
    if var.existing_private_db_subnet_ids == null && try(local.private_db_subnet_cidrs[index], null) != null
  }
  public_subnets = {
    for index, az in local.availability_zones : az => local.public_subnet_cidrs[index]
    if local.create_public_subnets && try(local.public_subnet_cidrs[index], null) != null
  }

  create_public_subnets = var.publicly_accessible && var.existing_public_subnet_ids == null

  subnet_tiers = {
    private_app = { ids = var.existing_private_app_subnet_ids, cidrs = var.private_app_subnet_cidrs }
    private_db  = { ids = var.existing_private_db_subnet_ids, cidrs = var.private_db_subnet_cidrs }
    public      = { ids = var.existing_public_subnet_ids, cidrs = var.public_subnet_cidrs }
  }
  existing_subnets = merge([
    for tier, config in local.subnet_tiers : {
      for index, id in(config.ids == null ? [] : config.ids) : "${tier}:${index}" => {
        id                = id
        availability_zone = try(var.availability_zones[index], "")
      }
    }
  ]...)

  private_app_subnet_ids = var.existing_private_app_subnet_ids == null ? [
    for az in local.availability_zones : aws_subnet.private_app[az].id if contains(keys(aws_subnet.private_app), az)
  ] : [for index, id in var.existing_private_app_subnet_ids : data.aws_subnet.existing["private_app:${index}"].id]
  private_db_subnet_ids = var.existing_private_db_subnet_ids == null ? [
    for az in local.availability_zones : aws_subnet.private_db[az].id if contains(keys(aws_subnet.private_db), az)
  ] : [for index, id in var.existing_private_db_subnet_ids : data.aws_subnet.existing["private_db:${index}"].id]
  public_subnet_ids = !var.publicly_accessible ? [] : (var.existing_public_subnet_ids == null ? [
    for az in local.availability_zones : aws_subnet.public[az].id if contains(keys(aws_subnet.public), az)
  ] : [for index, id in var.existing_public_subnet_ids : data.aws_subnet.existing["public:${index}"].id])

  tags = merge(
    var.tags,
    var.aws_marketplace_product_code == null ? {} : {
      aws-apn-id = "pc:${var.aws_marketplace_product_code}"
    },
  )
}

data "aws_vpc" "existing" {
  count = var.existing_vpc_id == null ? 0 : 1
  id    = var.existing_vpc_id

  lifecycle {
    postcondition {
      condition     = self.cidr_block == var.vpc_cidr_block
      error_message = "vpc_cidr_block must match the existing VPC's primary IPv4 CIDR block."
    }
    postcondition {
      condition     = self.enable_dns_support && self.enable_dns_hostnames
      error_message = "The existing VPC must have DNS support and DNS hostnames enabled."
    }
  }
}

data "aws_internet_gateway" "existing" {
  count               = var.existing_internet_gateway_id == null ? 0 : 1
  internet_gateway_id = var.existing_internet_gateway_id

  lifecycle {
    postcondition {
      condition     = anytrue([for attachment in self.attachments : attachment.vpc_id == var.existing_vpc_id])
      error_message = "The existing Internet Gateway must be attached to existing_vpc_id."
    }
  }
}

data "aws_subnet" "existing" {
  for_each = local.existing_subnets
  id       = each.value.id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.existing_vpc_id && self.availability_zone == each.value.availability_zone
      error_message = "Every supplied subnet must belong to existing_vpc_id and match its position in availability_zones."
    }
  }
}

moved {
  from = aws_route_table.private_db
  to   = aws_route_table.private_db[0]
}

moved {
  from = aws_vpc.this
  to   = aws_vpc.this[0]
}

moved {
  from = aws_default_security_group.this
  to   = aws_default_security_group.this[0]
}

resource "aws_vpc" "this" {
  count = var.existing_vpc_id == null ? 1 : 0

  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpc"
  })
}

# These checks must run even when the VPC is supplied by the caller.
resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition = alltrue([
        for tier in local.subnet_tiers : tier.ids == null ? true : (
          var.existing_vpc_id != null && length(var.availability_zones) >= 2 &&
          length(tier.ids) == length(var.availability_zones) && tier.cidrs == null
        )
      ])
      error_message = "Supplied subnet IDs require existing_vpc_id, explicit availability_zones, one subnet per AZ, and no CIDR override for that tier."
    }
    precondition {
      condition = (
        length(distinct([for subnet in local.existing_subnets : subnet.id])) == length(local.existing_subnets) &&
        alltrue([for subnet in local.existing_subnets : can(regex("^subnet-([0-9a-f]{8}|[0-9a-f]{17})$", subnet.id))])
      )
      error_message = "Supplied subnet IDs must be valid and unique across all tiers."
    }
    precondition {
      condition     = var.existing_public_subnet_ids == null || var.publicly_accessible
      error_message = "existing_public_subnet_ids requires publicly_accessible = true."
    }
    precondition {
      condition     = var.existing_private_app_subnet_ids == null || !var.create_nat_gateway
      error_message = "Set create_nat_gateway = false when supplying application subnets; their egress routing remains caller-managed."
    }
    precondition {
      condition     = local.availability_zone_count >= 2 && local.availability_zone_count <= 3
      error_message = "The selected AWS region must expose at least two standard availability zones; at most three are used."
    }
    precondition {
      condition = alltrue([
        for az in local.availability_zones : contains(data.aws_availability_zones.available.names, az)
      ])
      error_message = "Every selected availability zone must be a standard availability zone in the configured AWS region."
    }
    precondition {
      condition = (
        (var.existing_private_app_subnet_ids != null || length(local.private_app_subnet_cidrs) == local.availability_zone_count) &&
        (var.existing_private_db_subnet_ids != null || length(local.private_db_subnet_cidrs) == local.availability_zone_count) &&
        (!local.create_public_subnets || length(local.public_subnet_cidrs) == local.availability_zone_count)
      )
      error_message = "Provide exactly one private-app and private-DB CIDR per selected AZ, plus one public CIDR per AZ when publicly_accessible is true."
    }
    precondition {
      condition     = !var.create_nat_gateway || var.create_internet_gateway || var.existing_internet_gateway_id != null
      error_message = "create_nat_gateway requires create_internet_gateway or existing_internet_gateway_id because AWS regional public NAT gateways require an attached Internet Gateway."
    }
    precondition {
      condition     = !local.create_public_subnets || var.create_internet_gateway || var.existing_internet_gateway_id != null
      error_message = "Creating public subnets requires create_internet_gateway or existing_internet_gateway_id."
    }
    precondition {
      condition     = !var.enable_vpc_endpoints || length(var.interface_endpoint_services) > 0
      error_message = "enable_vpc_endpoints requires at least one interface_endpoint_services entry."
    }
  }
}

resource "aws_subnet" "private_app" {
  for_each = local.private_app_subnets

  vpc_id                  = local.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                              = "${var.name}-smith-private-app-subnet-${local.availability_zone_suffixes[each.key]}"
    type                              = "private-app"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "private_db" {
  for_each = local.private_db_subnets

  vpc_id                  = local.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${var.name}-smith-private-db-subnet-${local.availability_zone_suffixes[each.key]}"
    type = "private-db"
  })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = local.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name                     = "${var.name}-smith-public-subnet-${local.availability_zone_suffixes[each.key]}"
    type                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.create_internet_gateway ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-igw"
  })
}

resource "aws_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  vpc_id            = local.vpc_id
  availability_mode = "regional"

  tags = merge(local.tags, {
    Name = "${var.name}-smith-nat"
  })

  depends_on = [aws_internet_gateway.this, data.aws_internet_gateway.existing]
}

resource "aws_route_table" "private_app" {
  for_each = local.private_app_subnets

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-rt-private-app-${local.availability_zone_suffixes[each.key]}"
    type = "private-app"
  })
}

resource "aws_route" "private_app_nat" {
  for_each = var.create_nat_gateway ? aws_route_table.private_app : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private_app" {
  for_each = local.private_app_subnets

  subnet_id      = aws_subnet.private_app[each.key].id
  route_table_id = aws_route_table.private_app[each.key].id
}

resource "aws_route_table" "private_db" {
  count = var.existing_private_db_subnet_ids == null ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-rt-private-db"
    type = "private-db"
  })
}

resource "aws_route_table_association" "private_db" {
  for_each = local.private_db_subnets

  subnet_id      = aws_subnet.private_db[each.key].id
  route_table_id = aws_route_table.private_db[0].id
}

resource "aws_route_table" "public" {
  count = local.create_public_subnets ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-rt-public"
    type = "public"
  })
}

resource "aws_route" "public_internet_gateway" {
  count = local.create_public_subnets && (var.create_internet_gateway || var.existing_internet_gateway_id != null) ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = local.internet_gateway_id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_default_security_group" "this" {
  count = var.existing_vpc_id == null ? 1 : 0

  vpc_id = local.vpc_id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-default-sg"
  })
}
