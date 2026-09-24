output "role_names" {
  description = "Static role names, keyed by role purpose, for the Crossplane customer-managed IAM contract."
  value       = { for key, role in aws_iam_role.this : key => role.name }
}

output "role_arns" {
  description = "Shared role ARNs for auditing and provisioning-role read/PassRole allowlists."
  value       = { for key, role in aws_iam_role.this : key => role.arn }
}

output "karpenter_instance_profile_name" {
  description = "Static instance profile to observe and use in every Karpenter EC2NodeClass."
  value       = aws_iam_instance_profile.karpenter.name
}

output "karpenter_controller_policy_arn" {
  description = "Customer-owned Karpenter policy ARN."
  value       = aws_iam_policy.karpenter.arn
}
