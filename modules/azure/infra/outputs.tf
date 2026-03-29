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

# See: https://docs.langchain.com/langsmith/self-host-blob-storage
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

output "agw_public_ip_fqdn" {
  description = "FQDN of the Application Gateway public IP. Empty when ingress_controller != 'agic' or DNS label not set."
  value       = module.aks.agw_public_ip_fqdn
}

output "agw_name" {
  description = "Name of the Application Gateway resource. Empty when ingress_controller != 'agic'."
  value       = module.aks.agw_name
}

output "langsmith_url" {
  description = "URL where LangSmith is accessible."
  value = (
    var.langsmith_domain != "" ? "https://${var.langsmith_domain}" :
    var.dns_label != ""  ? "https://${var.dns_label}.${var.location}.cloudapp.azure.com" :
    var.ingress_controller == "agic" && module.aks.agw_public_ip_fqdn != null && module.aks.agw_public_ip_fqdn != "" ? "https://${module.aks.agw_public_ip_fqdn}" :
    "No domain configured — set dns_label or langsmith_domain in terraform.tfvars"
  )
}

output "langsmith_admin_email" {
  description = "Initial LangSmith org admin email — set via setup-env.sh, used as initialOrgAdminEmail in Helm values."
  value       = var.langsmith_admin_email
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

# ── WAF ───────────────────────────────────────────────────────────────────────
output "waf_policy_id" {
  description = "WAF policy resource ID (attach to App Gateway or Front Door)"
  value       = var.create_waf ? module.waf[0].waf_policy_id : ""
}

# ── Diagnostics ───────────────────────────────────────────────────────────────
output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID"
  value       = var.create_diagnostics ? module.diagnostics[0].workspace_id : ""
}

# ── Bastion ───────────────────────────────────────────────────────────────────
output "bastion_public_ip" {
  description = "Public IP of the bastion jump VM"
  value       = var.create_bastion ? module.bastion[0].public_ip : ""
}

output "bastion_ssh_command" {
  description = "az CLI command to SSH into the bastion VM"
  value       = var.create_bastion ? module.bastion[0].ssh_command : ""
}

# ── Ingress passthrough (read by pull-infra-outputs.sh) ──────────────────────
output "dns_label" {
  description = "Azure Public IP DNS label passed through from var.dns_label"
  value       = var.dns_label
}

output "ingress_controller" {
  description = "Ingress controller type passed through from var.ingress_controller"
  value       = var.ingress_controller
}

output "tls_certificate_source" {
  description = "TLS certificate source passed through from var.tls_certificate_source"
  value       = var.tls_certificate_source
}

# ── DNS ───────────────────────────────────────────────────────────────────────
output "dns_nameservers" {
  description = "Azure nameservers for the DNS zone — configure at your registrar"
  value       = var.create_dns_zone ? module.dns[0].nameservers : []
}
