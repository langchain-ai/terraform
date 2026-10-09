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

output "redis_cluster_safe_mode" {
  description = "Whether LangSmith should set redis.external.clusterSafeMode (true for AMR). init-values.sh reads this."
  value       = var.redis_source == "external" ? module.redis[0].cluster_safe_mode : false
}

output "storage_account_name" {
  description = "Azure Blob Storage account name used for LangSmith traces and assets"
  value       = module.blob.storage_account_name
}

output "storage_container_name" {
  description = "Blob container name within the storage account"
  value       = module.blob.container_name
}

# See: https://docs.langchain.com/langsmith/self-host-blob-storage
output "storage_account_k8s_managed_identity_client_id" {
  description = "Client ID of the managed identity used by the LangSmith backend pod to access Blob Storage via Workload Identity"
  value       = module.blob.k8s_managed_identity_client_id
}

# ── Resource group ────────────────────────────────────────────────────────────

output "resource_group_name" {
  description = "Name of the Azure resource group containing all LangSmith resources"
  value       = local.resource_group_name
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

output "aks_private_fqdn" {
  description = "Private FQDN of the AKS API server. Reach it from a host with VNet connectivity that can resolve the private DNS zone."
  value       = module.aks.private_fqdn
}

output "kubeconfig" {
  description = "Raw kubeconfig for connecting to the AKS cluster. Run: terraform output -raw kubeconfig > ~/.kube/config"
  sensitive   = true
  value       = module.aks.kube_config_raw
}

# ── LangSmith ─────────────────────────────────────────────────────────────────

output "langsmith_url" {
  description = "URL where LangSmith is accessible."
  value       = var.langsmith_domain != "" ? "https://${var.langsmith_domain}" : "Set langsmith_domain and point your DNS at the internal ingress IP"
}

output "langsmith_admin_email" {
  description = "Initial LangSmith org admin email — set via setup-env.sh, used as initialOrgAdminEmail in Helm values."
  value       = var.langsmith_admin_email
}

output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = var.langsmith_namespace
}

# ── Bootstrap-facing outputs (consumed by the separate bootstrap/ root) ────────

output "key_vault_name" {
  description = "Name of the Key Vault — passed to the bootstrap/ root so it can read secrets via the CSI driver"
  value       = module.keyvault.vault_name
}

output "workload_identity_client_id" {
  description = "Client ID of the User-Assigned Managed Identity for LangSmith pods (Workload Identity)"
  value       = module.aks.workload_identity_client_id
}

output "get_credentials_command" {
  description = "Run this command to configure kubectl for this cluster"
  value       = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${module.aks.cluster_name} --overwrite-existing"
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

# ── Diagnostics ───────────────────────────────────────────────────────────────

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID"
  value       = module.diagnostics.workspace_id
}

# ── Bastion ───────────────────────────────────────────────────────────────────

output "bastion_public_ip" {
  description = "Public IP of the bastion jump VM"
  value       = module.bastion.public_ip
}

output "bastion_ssh_command" {
  description = "az CLI command to SSH into the bastion VM"
  value       = module.bastion.ssh_command
}

