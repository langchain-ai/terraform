output "firewall_arn" {
  description = "ARN of the AWS Network Firewall"
  value       = aws_networkfirewall_firewall.this.arn
}

output "firewall_endpoint_id" {
  description = "VPC endpoint ID of the firewall. Private route tables send 0.0.0.0/0 here."
  value       = local.firewall_endpoint_id
}

output "firewall_subnet_id" {
  description = "ID of the firewall subnet"
  value       = aws_subnet.firewall.id
}

output "firewall_policy_arn" {
  description = "ARN of the firewall policy"
  value       = aws_networkfirewall_firewall_policy.this.arn
}

output "rule_group_arn" {
  description = "ARN of the egress allowlist rule group"
  value       = aws_networkfirewall_rule_group.egress_allow.arn
}
