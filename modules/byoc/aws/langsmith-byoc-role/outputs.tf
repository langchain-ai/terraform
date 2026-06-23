output "crossplane_role_arn" {
  description = "ARN of the higher-privilege IAM role assumed by the LangSmith control plane for initial provisioning and explicit maintenance operations."
  value       = aws_iam_role.langchain_byoc.arn
}

output "management_role_arn" {
  description = "ARN of the lower-privilege IAM role assumed by the LangSmith control plane for day 1 management operations after initial provisioning."
  value       = aws_iam_role.langchain_byoc_management.arn
}

output "break_glass_role_arn" {
  description = "ARN of the customer-side LangSmith BYOC break-glass role."
  value       = aws_iam_role.break_glass.arn
}
