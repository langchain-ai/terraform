output "crossplane_role_arn" {
  description = "ARN of the IAM role assumed by the LangSmith control plane to manage the infrastructure in the target account."
  value       = aws_iam_role.langchain_byoc.arn
}

# For the roles below, the trust policy ships with default-Deny on the LangChain break-glass principal. Flip it to allow access during incidents

output "readonly_access_role_arn" {
  description = "ARN of the LangChain break-glass read-only EKS access role."
  value       = aws_iam_role.readonly_access.arn
}

output "cluster_admin_access_role_arn" {
  description = "ARN of the LangChain break-glass cluster-admin (no data access) EKS access role."
  value       = aws_iam_role.cluster_admin_access.arn
}

output "data_access_role_arn" {
  description = "ARN of the LangChain break-glass full-admin EKS access role."
  value       = aws_iam_role.data_access.arn
}
