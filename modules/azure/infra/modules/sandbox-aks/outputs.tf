output "cluster_id" {
  description = "The ID of the sandbox cluster"
  value       = azurerm_kubernetes_cluster.sandbox.id
}

output "cluster_name" {
  description = "The name of the sandbox cluster"
  value       = azurerm_kubernetes_cluster.sandbox.name
}

output "oidc_issuer_url" {
  description = "The sandbox cluster's OIDC issuer, which the sandbox-host federated credential trusts"
  value       = azurerm_kubernetes_cluster.sandbox.oidc_issuer_url
}

output "host" {
  description = "The Kubernetes API server endpoint: the public FQDN on a private cluster with no private DNS zone, the kubeconfig's server otherwise"
  value       = local.cluster_host
  sensitive   = true
}

output "client_certificate" {
  description = "Base64-encoded client certificate for Kubernetes provider auth. Empty with Entra integration."
  value       = azurerm_kubernetes_cluster.sandbox.kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client key for Kubernetes provider auth. Empty with Entra integration."
  value       = azurerm_kubernetes_cluster.sandbox.kube_config[0].client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate for Kubernetes provider auth"
  value       = azurerm_kubernetes_cluster.sandbox.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "kube_auth" {
  description = "How the root's sandbox Kubernetes provider signs in: 'entra' (kubelogin with the caller's az session) or 'certificate'."
  value       = local.kube_auth
}

output "api_server_public_fqdn" {
  description = "True when az aks get-credentials needs --public-fqdn for this cluster."
  value       = local.api_server_public_fqdn
}

output "node_resource_group" {
  description = "The resource group AKS created for the sandbox cluster's nodes"
  value       = azurerm_kubernetes_cluster.sandbox.node_resource_group
}
