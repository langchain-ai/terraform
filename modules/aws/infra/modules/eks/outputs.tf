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

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_primary_security_group_id" {
  description = "Primary security group ID for the EKS cluster (control plane SG, not attached to worker nodes)."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes and pod ENIs. Used to grant ALB access to gateway proxy pods (target-type: ip)."
  value       = module.eks.node_security_group_id
}
