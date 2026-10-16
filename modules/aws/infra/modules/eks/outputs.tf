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

output "karpenter_node_iam_role_name" {
  description = "Name of the Karpenter node IAM role (null when Karpenter is disabled). Referenced by the SmithDB EC2NodeClass role."
  value       = var.enable_karpenter ? try(module.eks_blueprints_addons.karpenter.node_iam_role_name, null) : null
}

output "karpenter_node_iam_role_arn" {
  description = "ARN of the Karpenter node IAM role (null when Karpenter is disabled)."
  value       = var.enable_karpenter ? try(module.eks_blueprints_addons.karpenter.node_iam_role_arn, null) : null
}

output "eks_managed_node_group_inputs" {
  description = "Managed node groups as passed to the upstream EKS module. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value       = local.eks_managed_node_groups
}

output "controller_tag_inputs" {
  description = "Tag settings handed to the controllers that create AWS resources outside default_tags. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value = {
    ebs_csi_configuration_values    = aws_eks_addon.ebs-csi.configuration_values
    load_balancer_controller_values = local.load_balancer_controller_values
    vpc_cni_configuration_values    = local.module_vpc_cni ? local.vpc_cni_addon.configuration_values : local.blueprints_eks_addons["vpc-cni"].configuration_values
  }
}

output "vpc_cni_inputs" {
  description = "Which module owns the vpc-cni add-on, its settings when this module owns it, and the node-group wait that follows it. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value = {
    module_managed          = local.module_vpc_cni
    blueprints_managed      = contains(keys(local.blueprints_eks_addons), "vpc-cni")
    most_recent             = local.module_vpc_cni ? try(local.vpc_cni_addon.most_recent, null) : null
    resolve_on_create       = local.module_vpc_cni ? try(local.vpc_cni_addon.resolve_conflicts_on_create, null) : null
    dataplane_wait_duration = local.dataplane_wait_duration
  }
}
