output "host" {
  value       = aws_eip.this.public_ip
  description = "The instance's fixed public address."
}

output "instance_id" {
  value       = aws_instance.this.id
  description = "The instance, for the console and the AWS CLI."
}

output "instance_type" {
  value       = aws_instance.this.instance_type
  description = "The instance type, for the plan tests."
}

output "ssh_rules" {
  value       = keys(aws_vpc_security_group_ingress_rule.ssh)
  description = "The CIDRs ssh is open to."
}

output "web_rules" {
  value       = keys(aws_vpc_security_group_ingress_rule.web)
  description = "Each <port>-<cidr> LangSmith is open on."
}
