output "role_arn" {
  description = "ARN of the IAM role for LangSmith IRSA"
  value       = aws_iam_role.langsmith.arn
}

output "role_name" {
  description = "Name of the IAM role for LangSmith IRSA"
  value       = aws_iam_role.langsmith.name
}
