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
