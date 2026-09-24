output "langsmith_network_config" {
  description = "Network identifiers to provide when creating the LangSmith data plane."
  value = {
    vpc_id                 = local.vpc_id
    availability_zones     = local.availability_zones
    private_app_subnet_ids = local.private_app_subnet_ids
    private_db_subnet_ids  = local.private_db_subnet_ids
    public_subnet_ids      = local.public_subnet_ids
  }
}

output "vpc_id" {
  description = "ID of the created or supplied VPC."
  value       = local.vpc_id
}

output "vpc_cidr_block" {
  description = "Primary IPv4 CIDR block of the created or supplied VPC."
  value       = var.vpc_cidr_block
}

output "availability_zones" {
  description = "Ordered availability zones used by the subnet tiers."
  value       = local.availability_zones
}

output "private_app_subnet_ids" {
  description = "Ordered IDs of the private application subnets."
  value       = local.private_app_subnet_ids
}

output "private_db_subnet_ids" {
  description = "Ordered IDs of the isolated database subnets."
  value       = local.private_db_subnet_ids
}

output "public_subnet_ids" {
  description = "Ordered IDs of the public subnets, or an empty list when publicly_accessible is false."
  value       = local.public_subnet_ids
}

output "private_app_route_table_ids" {
  description = "Ordered IDs of module-created application route tables; empty when application subnets are supplied."
  value       = [for az in local.availability_zones : aws_route_table.private_app[az].id if contains(keys(aws_route_table.private_app), az)]
}

output "private_db_route_table_ids" {
  description = "IDs of module-created database route tables; empty when database subnets are supplied."
  value       = aws_route_table.private_db[*].id
}

output "public_route_table_ids" {
  description = "IDs of module-created public route tables; empty when public subnets are supplied or disabled."
  value       = aws_route_table.public[*].id
}

output "internet_gateway_id" {
  description = "ID of the created or supplied Internet Gateway, or null when neither is configured."
  value       = local.internet_gateway_id
}

output "nat_gateway_id" {
  description = "ID of the regional NAT gateway, or null when it is not created."
  value       = try(aws_nat_gateway.this[0].id, null)
}

output "vpc_flow_log_id" {
  description = "ID of the VPC Flow Log, or null when it is not created."
  value       = try(aws_flow_log.this[0].id, null)
}

output "vpc_flow_log_bucket_arn" {
  description = "ARN of the VPC Flow Log destination bucket, or null when it is not created."
  value       = try(aws_s3_bucket.flow_logs[0].arn, null)
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 Gateway endpoint, or null when it is not created."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "interface_endpoint_ids" {
  description = "Map of AWS service names to customer-owned Interface endpoint IDs."
  value       = { for service, endpoint in aws_vpc_endpoint.interface : service => endpoint.id }
}

output "control_plane_privatelink_endpoint_id" {
  description = "ID of the data-plane-to-control-plane PrivateLink endpoint, or null when it is not created."
  value       = try(aws_vpc_endpoint.control_plane[0].id, null)
}

output "control_plane_private_zone_ids" {
  description = "Map of private control-plane hostnames to Route 53 hosted zone IDs."
  value       = { for hostname, zone in aws_route53_zone.control_plane : hostname => zone.zone_id }
}
