output "instance_id" {
  description = "EC2 instance ID of the bastion host"
  value       = aws_instance.bastion.id
}

output "public_ip" {
  description = "Public IP of the bastion host (null if associate_public_ip = false)"
  value       = aws_instance.bastion.public_ip
}

output "security_group_id" {
  description = "Security group ID attached to the bastion"
  value       = aws_security_group.bastion.id
}

output "iam_role_arn" {
  description = "IAM role ARN of the bastion instance profile"
  value       = aws_iam_role.bastion.arn
}

output "ssm_start_session_command" {
  description = "AWS CLI command to start an SSM session to the bastion"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}
