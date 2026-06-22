output "crossplane_role_arn" {
  description = "ARN of the IAM role assumed by the LangSmith control plane to manage the infrastructure in the target account."
  value       = aws_iam_role.langchain_byoc.arn
}

output "break_glass_role_arn" {
  description = "ARN of the customer-side LangSmith BYOC break-glass role."
  value       = aws_iam_role.break_glass.arn
}
