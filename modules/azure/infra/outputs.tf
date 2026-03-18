output "postgres_connection_url" {
  description = "PostgreSQL connection URL. Empty when postgres_source = 'in-cluster'."
  sensitive   = true
  value       = var.postgres_source == "external" ? module.postgres[0].connection_url : ""
}

output "redis_connection_url" {
  description = "Redis connection URL. Empty when redis_source = 'in-cluster'."
  sensitive   = true
  value       = var.redis_source == "external" ? module.redis[0].connection_url : ""
}

output "storage_account_name" {
  description = "Azure Blob Storage account name used for LangSmith traces and assets"
  value       = module.blob.storage_account_name
}

output "storage_container_name" {
  description = "Blob container name within the storage account"
  value       = module.blob.container_name
}

# See: https://docs.smith.langchain.com/self_hosting/configuration/blob_storage#azure-blob-storage
output "storage_account_k8s_managed_identity_client_id" {
  description = "Client ID of the managed identity used by the LangSmith backend pod to access Blob Storage via Workload Identity"
  value       = module.blob.k8s_managed_identity_client_id
}

# ── Resource group ────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the Azure resource group containing all LangSmith resources"
  value       = azurerm_resource_group.resource_group.name
}

# ── AKS cluster ───────────────────────────────────────────────────────────────

output "aks_cluster_name" {
  description = "Name of the AKS cluster"
  value       = module.aks.cluster_name
}

output "aks_cluster_id" {
  description = "Resource ID of the AKS cluster"
  value       = module.aks.cluster_id
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster (used for Workload Identity federation)"
  value       = module.aks.oidc_issuer_url
}

output "kubeconfig" {
  description = "Raw kubeconfig for connecting to the AKS cluster. Run: terraform output -raw kubeconfig > ~/.kube/config"
  sensitive   = true
  value       = module.aks.kube_config_raw
}

# ── LangSmith ─────────────────────────────────────────────────────────────────

output "langsmith_url" {
  description = "URL where LangSmith is accessible (requires DNS to be configured)"
  value       = var.langsmith_domain != "" ? "https://${var.langsmith_domain}" : "Domain not set — configure var.langsmith_domain in terraform.tfvars"
}

output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = module.k8s_bootstrap.langsmith_namespace
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl for this cluster"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.resource_group.name} --name ${module.aks.cluster_name} --overwrite-existing"
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

output "keyvault_name" {
  description = "Name of the Key Vault holding all LangSmith secrets. Pass to setup-env.sh via LANGSMITH_KEYVAULT_NAME."
  value       = module.keyvault.vault_name
}

output "keyvault_uri" {
  description = "URI of the Key Vault (https://<name>.vault.azure.net/)"
  value       = module.keyvault.vault_uri
}
