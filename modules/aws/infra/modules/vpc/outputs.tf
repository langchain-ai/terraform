output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "nat_public_ips" {
  description = "Public egress IPs used by workloads in private subnets."
  value       = module.vpc.nat_public_ips
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "List of availability zones used by this VPC."
  value       = module.vpc.azs
}

output "pod_subnets" {
  description = "IDs of the pod subnets, in the same AZ order as azs. Empty when pod_cidr is null."
  value       = module.vpc.intra_subnets
}
