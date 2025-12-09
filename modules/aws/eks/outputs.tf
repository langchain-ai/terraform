output "cluster_name" {
  value = module.eks.cluster_name
}

output "oidc_provider" {
  description = "OIDC provider URL for IRSA"
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.oidc_provider_arn
}

output "langsmith_irsa_role_arn" {
  description = "ARN of the IRSA role for LangSmith pods"
  value       = var.create_langsmith_irsa_role ? aws_iam_role.langsmith[0].arn : null
}

output "langsmith_irsa_role_name" {
  description = "Name of the IRSA role for LangSmith pods"
  value       = var.create_langsmith_irsa_role ? aws_iam_role.langsmith[0].name : null
}
