output "langsmith_network_config" {
  description = "Network identifiers to provide when creating the LangSmith data plane."
  value = {
    vpc_id                 = aws_vpc.this.id
    availability_zones     = local.availability_zones
    private_app_subnet_ids = [for az in local.availability_zones : aws_subnet.private_app[az].id]
    private_db_subnet_ids  = [for az in local.availability_zones : aws_subnet.private_db[az].id]
    public_subnet_ids = var.publicly_accessible ? [
      for az in local.availability_zones : aws_subnet.public[az].id
    ] : []
  }
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the created VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Ordered availability zones used by the subnet tiers."
  value       = local.availability_zones
}

output "private_app_subnet_ids" {
  description = "Ordered IDs of the private application subnets."
  value       = [for az in local.availability_zones : aws_subnet.private_app[az].id]
}

output "private_db_subnet_ids" {
  description = "Ordered IDs of the isolated database subnets."
  value       = [for az in local.availability_zones : aws_subnet.private_db[az].id]
}

output "public_subnet_ids" {
  description = "Ordered IDs of the public subnets, or an empty list when publicly_accessible is false."
  value = var.publicly_accessible ? [
    for az in local.availability_zones : aws_subnet.public[az].id
  ] : []
}

output "private_app_route_table_ids" {
  description = "Ordered IDs of the private application route tables."
  value       = [for az in local.availability_zones : aws_route_table.private_app[az].id]
}

output "private_db_route_table_ids" {
  description = "IDs of the isolated database route tables."
  value       = [aws_route_table.private_db.id]
}

output "public_route_table_ids" {
  description = "IDs of the public route tables, or an empty list when publicly_accessible is false."
  value       = var.publicly_accessible ? [aws_route_table.public[0].id] : []
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway, or null when it is not created."
  value       = try(aws_internet_gateway.this[0].id, null)
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
