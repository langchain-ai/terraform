output "cluster_id" {
  description = "The ID of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "The name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  description = "The OIDC issuer URL of the AKS cluster, used for workload identity federation"
  value       = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "workload_identity_client_id" {
  description = "Client ID of the User-Assigned Managed Identity for LangSmith pods (Workload Identity)"
  value       = azurerm_user_assigned_identity.k8s_app.client_id
}

output "workload_identity_principal_id" {
  description = "Principal (Object) ID of the Managed Identity — used by keyvault and storage modules for RBAC role assignments"
  value       = azurerm_user_assigned_identity.k8s_app.principal_id
}

output "private_fqdn" {
  description = "Private FQDN of the AKS API server (empty/null when the cluster is public)"
  value       = azurerm_kubernetes_cluster.main.private_fqdn
}
