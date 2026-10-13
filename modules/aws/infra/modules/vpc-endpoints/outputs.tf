output "endpoint_ids" {
  description = "Interface endpoint IDs, keyed by service suffix"
  value       = { for service, endpoint in aws_vpc_endpoint.this : service => endpoint.id }
}

output "security_group_id" {
  description = "Security group attached to every interface endpoint"
  value       = aws_security_group.this.id
}
