data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required", "opted-in"]
  }
}

data "aws_region" "current" {}

locals {
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
    if try(local.private_app_subnet_cidrs[index], null) != null
  }
  private_db_subnets = {
    for index, az in local.availability_zones : az => local.private_db_subnet_cidrs[index]
    if try(local.private_db_subnet_cidrs[index], null) != null
  }
  public_subnets = {
    for index, az in local.availability_zones : az => local.public_subnet_cidrs[index]
    if var.publicly_accessible && try(local.public_subnet_cidrs[index], null) != null
  }

  tags = merge(
    var.tags,
    var.aws_marketplace_product_code == null ? {} : {
      aws-apn-id = "pc:${var.aws_marketplace_product_code}"
    },
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpc"
  })

  lifecycle {
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
        length(local.private_app_subnet_cidrs) == local.availability_zone_count &&
        length(local.private_db_subnet_cidrs) == local.availability_zone_count &&
        (!var.publicly_accessible || length(local.public_subnet_cidrs) == local.availability_zone_count)
      )
      error_message = "Provide exactly one private-app and private-DB CIDR per selected AZ, plus one public CIDR per AZ when publicly_accessible is true."
    }
    precondition {
      condition     = !var.create_nat_gateway || var.create_internet_gateway
      error_message = "create_nat_gateway requires create_internet_gateway because AWS regional public NAT gateways require an attached Internet Gateway."
    }
    precondition {
      condition     = !var.publicly_accessible || var.create_internet_gateway
      error_message = "publicly_accessible requires create_internet_gateway."
    }
    precondition {
      condition     = !var.enable_vpc_endpoints || length(var.interface_endpoint_services) > 0
      error_message = "enable_vpc_endpoints requires at least one interface_endpoint_services entry."
    }
  }
}

resource "aws_subnet" "private_app" {
  for_each = local.private_app_subnets

  vpc_id                  = aws_vpc.this.id
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

  vpc_id                  = aws_vpc.this.id
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

  vpc_id                  = aws_vpc.this.id
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

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-igw"
  })
}

resource "aws_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  vpc_id            = aws_vpc.this.id
  availability_mode = "regional"

  tags = merge(local.tags, {
    Name = "${var.name}-smith-nat"
  })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private_app" {
  for_each = local.private_app_subnets

  vpc_id = aws_vpc.this.id

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
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-rt-private-db"
    type = "private-db"
  })
}

resource "aws_route_table_association" "private_db" {
  for_each = local.private_db_subnets

  subnet_id      = aws_subnet.private_db[each.key].id
  route_table_id = aws_route_table.private_db.id
}

resource "aws_route_table" "public" {
  count = var.publicly_accessible ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-rt-public"
    type = "public"
  })
}

resource "aws_route" "public_internet_gateway" {
  count = var.publicly_accessible ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-default-sg"
  })
}
