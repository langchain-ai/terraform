locals {
  public_subnet_tags = merge(
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    },
    var.extra_public_subnet_tags
  )
  private_subnet_tags = merge(
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    },
    var.extra_private_subnet_tags
  )
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.vpc_name

  cidr = var.cidr_block
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets         = var.private_subnets
  public_subnets          = var.public_subnets
  map_public_ip_on_launch = true

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # When the firewall module is enabled it owns the 0.0.0.0/0 route in private
  # route tables. Setting a non-routable destination here prevents the vpc
  # module from creating a conflicting 0.0.0.0/0 → NAT GW route.
  # 100.64.0.0/10 is RFC 6598 Shared Address Space — reserved, never reaches
  # the internet, so this route is effectively inert.
  nat_gateway_destination_cidr_block = var.firewall_enabled ? "100.64.0.0/10" : "0.0.0.0/0"

  public_subnet_tags = local.public_subnet_tags

  private_subnet_tags = local.private_subnet_tags
}
