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
  value       = local.existing_roles.langsmith != null ? local.existing_roles.langsmith : one(aws_iam_role.langsmith[*].arn)
}

output "langsmith_irsa_role_name" {
  description = "Name of the IRSA role for LangSmith pods"
  value       = local.existing_roles.langsmith != null ? reverse(split("/", local.existing_roles.langsmith))[0] : one(aws_iam_role.langsmith[*].name)
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_security_group_id" {
  description = "Security group the eks module attaches to the control plane ENIs."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Primary security group ID for the EKS cluster (control plane SG, not attached to worker nodes)."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID attached to EKS worker nodes and pod ENIs. Used to grant ALB access to gateway proxy pods (target-type: ip)."
  value       = module.eks.node_security_group_id
}

output "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role (null when Karpenter is disabled). Referenced by the SmithDB EC2NodeClass role."
  value       = !var.enable_karpenter ? null : local.existing_roles.karpenter_node != null ? local.karpenter_node_role_name : try(module.eks_blueprints_addons.karpenter.node_iam_role_name, null)
}

output "karpenter_node_iam_role_arn" {
  description = "ARN of the Karpenter node IAM role (null when Karpenter is disabled)."
  value       = var.enable_karpenter ? local.karpenter_node_role_arn : null
}

output "eks_managed_node_group_inputs" {
  description = "Managed node groups as passed to the upstream EKS module. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value       = local.eks_managed_node_groups
}
