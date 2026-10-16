output "peering_connection_id" {
  description = "ID of the peering request. Give it to LangChain so the data plane accepts it."
  value       = aws_vpc_peering_connection.data_plane.id
}

output "self_hosted_vpc_cidr_block" {
  description = "IPv4 CIDR block of the self-hosted VPC. Give it to LangChain so the data plane allows traffic from it."
  value       = data.aws_vpc.self_hosted.cidr_block
}

output "peering_status" {
  description = "Acceptance status of the peering connection as last read by Terraform."
  value       = aws_vpc_peering_connection.data_plane.accept_status
}
