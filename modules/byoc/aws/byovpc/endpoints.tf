locals {
  control_plane_service_name     = "com.amazonaws.vpce.us-east-2.vpce-svc-054f37092752bff6b"
  control_plane_service_region   = "us-east-2"
  control_plane_service_hostname = "aws.api.smith.langchain.com"
  control_plane_beacon_hostname  = "beacon.aws.langchain.com"
  control_plane_hostnames = var.enable_control_plane_privatelink ? toset([
    local.control_plane_service_hostname,
    local.control_plane_beacon_hostname,
  ]) : toset([])
}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for az in local.availability_zones : aws_route_table.private_app[az].id]

  tags = merge(local.tags, {
    Name = "${var.name}-smith-s3-endpoint"
  })
}

resource "aws_security_group" "interface_endpoints" {
  count = var.enable_vpc_endpoints || var.enable_control_plane_privatelink ? 1 : 0

  name        = "${var.name}-smith-vpc-endpoint-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpc-endpoint-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "interface_endpoints_https" {
  count = var.enable_vpc_endpoints || var.enable_control_plane_privatelink ? 1 : 0

  security_group_id = aws_security_group.interface_endpoints[0].id
  description       = "HTTPS from the LangSmith VPC"
  cidr_ipv4         = var.vpc_cidr_block
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443

  tags = merge(local.tags, {
    Name = "${var.name}-smith-vpce-sg-ingress-https"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_vpc_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for az in local.availability_zones : aws_subnet.private_app[az].id]
  security_group_ids  = [aws_security_group.interface_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, {
    Name = "${var.name}-smith-${replace(each.value, ".", "-")}-endpoint"
  })
}

resource "aws_vpc_endpoint" "control_plane" {
  count = var.enable_control_plane_privatelink ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = local.control_plane_service_name
  service_region      = local.control_plane_service_region
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for az in local.availability_zones : aws_subnet.private_app[az].id]
  security_group_ids  = [aws_security_group.interface_endpoints[0].id]
  private_dns_enabled = false

  tags = merge(local.tags, {
    Name = "${var.name}-smith-control-plane-endpoint"
  })
}

resource "aws_route53_zone" "control_plane" {
  for_each = local.control_plane_hostnames

  name = each.value

  vpc {
    vpc_id = aws_vpc.this.id
  }

  tags = merge(local.tags, {
    Name = "${var.name}-smith-${replace(each.value, ".", "-")}-zone"
  })
}

resource "aws_route53_record" "control_plane" {
  for_each = local.control_plane_hostnames

  zone_id = aws_route53_zone.control_plane[each.value].zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.control_plane[0].dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.control_plane[0].dns_entry[0].hosted_zone_id
    evaluate_target_health = true
  }
}
