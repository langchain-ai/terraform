output "cluster_name" {
  description = "Dedicated sandbox EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Dedicated sandbox EKS API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded dedicated sandbox EKS CA data"
  value       = module.eks.cluster_certificate_authority_data
}

output "oidc_provider" {
  description = "Dedicated sandbox EKS OIDC provider URL without the scheme"
  value       = module.eks.oidc_provider
}

output "oidc_provider_arn" {
  description = "Dedicated sandbox EKS OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  description = "Security group attached to sandbox worker nodes and pod ENIs"
  value       = module.eks.node_security_group_id
}

output "managed_node_group_input" {
  description = "The sandbox-host node group as passed to the upstream EKS module. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value       = local.sandbox_host_node_group
}
