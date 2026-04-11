output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "private_route_table_ids" {
  description = "IDs of the private route tables. With single_nat_gateway = true this is a single-element list."
  value       = module.vpc.private_route_table_ids
}

output "nat_gateway_id" {
  description = "ID of the single NAT gateway (nat-xxxxxxxxxxxxxxxxx)."
  value       = module.vpc.natgw_ids[0]
}

output "nat_gateway_az" {
  description = "Availability zone where the single NAT gateway is placed (first AZ of the VPC)."
  value       = module.vpc.azs[0]
}

output "azs" {
  description = "List of availability zones used by this VPC."
  value       = module.vpc.azs
}
