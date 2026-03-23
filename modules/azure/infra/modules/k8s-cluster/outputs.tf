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

output "host" {
  description = "The Kubernetes API server endpoint"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].host
  sensitive   = true
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the AKS cluster"
  value       = azurerm_kubernetes_cluster.main.kube_config_raw
  sensitive   = true
}

output "client_certificate" {
  description = "Base64-encoded client certificate for Kubernetes provider auth"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client key for Kubernetes provider auth"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate for Kubernetes provider auth"
  value       = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
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

output "cert_manager_identity_client_id" {
  description = "Client ID of the cert-manager Managed Identity — annotated on the cert-manager service account for DNS-01 Workload Identity auth"
  value       = azurerm_user_assigned_identity.cert_manager.client_id
}

output "cert_manager_identity_principal_id" {
  description = "Principal ID of the cert-manager Managed Identity — granted DNS Zone Contributor by the dns module"
  value       = azurerm_user_assigned_identity.cert_manager.principal_id
}
