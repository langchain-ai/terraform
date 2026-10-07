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

  lifecycle {
    postcondition {
      condition     = length(self.names) >= 2
      error_message = "This deployment requires at least two available AZs for its internet-facing Application Load Balancer."
    }
  }
}

locals {
  # Some regions, including us-west-1, expose only two standard AZs. Keep the
  # subnet lists aligned with the selected AZs so the VPC module never reuses
  # an AZ for an extra subnet.
  az_count = min(
    3,
    length(data.aws_availability_zones.available.names),
    length(var.private_subnets),
    length(var.public_subnets),
  )
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = var.vpc_name

  cidr = var.cidr_block
  azs  = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  private_subnets         = slice(var.private_subnets, 0, local.az_count)
  public_subnets          = slice(var.public_subnets, 0, local.az_count)
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
