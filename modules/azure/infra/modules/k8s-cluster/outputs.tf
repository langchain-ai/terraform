output "cluster_id" {
  description = "The ID of the AKS cluster"
  value       = local.cluster_id
}

output "cluster_name" {
  description = "The name of the AKS cluster"
  value       = local.cluster_name_actual
}

output "oidc_issuer_url" {
  description = "The OIDC issuer URL of the AKS cluster, used for workload identity federation"
  value       = local.cluster_oidc_issuer_url
}

output "host" {
  description = "The Kubernetes API server endpoint"
  value       = local.cluster_kube_config[0].host
  sensitive   = true
}

output "kube_config_raw" {
  description = "Raw kubeconfig for the AKS cluster"
  value       = local.cluster_kube_config_raw
  sensitive   = true
}

output "client_certificate" {
  description = "Base64-encoded client certificate for Kubernetes provider auth"
  value       = local.cluster_kube_config[0].client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client key for Kubernetes provider auth"
  value       = local.cluster_kube_config[0].client_key
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate for Kubernetes provider auth"
  value       = local.cluster_kube_config[0].cluster_ca_certificate
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

output "agw_public_ip_address" {
  description = "Public IP address of the Application Gateway (empty when ingress_controller != 'agic', or when attaching to a cluster whose gateway the customer owns)"
  value       = local.agic_managed ? azurerm_public_ip.agw[0].ip_address : ""
}

output "agw_public_ip_fqdn" {
  description = "FQDN of the Application Gateway public IP (<dns-label>.<region>.cloudapp.azure.com). Empty when ingress_controller != 'agic', no DNS label is set, or the gateway belongs to a pre-existing cluster."
  value       = local.agic_managed ? azurerm_public_ip.agw[0].fqdn : ""
}

output "agw_name" {
  description = "Name of the Application Gateway resource (empty when ingress_controller != 'agic', or when attaching to a cluster whose gateway the customer owns)"
  value       = local.agic_managed ? azurerm_application_gateway.agw[0].name : ""
}

# Read through one() rather than repeating the condition its siblings use, so this
# keeps returning null whatever ends up gating the gateway's count.
output "agw_id" {
  description = "Resource ID of the Application Gateway, for the diagnostics module to attach a setting to. Null when no gateway is created."
  value       = one(azurerm_application_gateway.agw[*].id)
}

output "live_network_profile" {
  description = "The network profile Azure reports for the cluster at plan time: mode (node-subnet or overlay), data plane, policy engine (none when no engine is installed) and pod range (null in node-subnet mode). null until the cluster exists, and when create_cluster = false."
  value = local.live_cluster == null ? null : {
    mode      = coalesce(try(local.live_cluster.mode, null), "node-subnet")
    dataplane = coalesce(try(local.live_cluster.dataplane, null), "azure")
    policy    = coalesce(try(local.live_cluster.policy, null), "none")
    pod_cidr  = try(local.live_cluster.pod_cidr, null)
  }
}

output "network_profile" {
  description = "The network profile the cluster is planned or created with: plugin mode (null is node-subnet), pod_cidr, data plane and policy engine. null when create_cluster = false."
  # Keyed off the flag rather than the resource object: a comparison against the
  # whole object would carry its sensitive kube-config marks into this output.
  value = !var.create_cluster ? null : {
    network_plugin_mode = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_plugin_mode)
    pod_cidr            = one(azurerm_kubernetes_cluster.main[*].network_profile[0].pod_cidr)
    network_data_plane  = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_data_plane)
    network_policy      = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_policy)
  }
}

output "sku_tier" {
  description = "The AKS tier the cluster is planned or created with. null when create_cluster = false."
  value       = one(azurerm_kubernetes_cluster.main[*].sku_tier)
}

output "support_plan" {
  description = "The AKS support plan the cluster is planned or created with. null when create_cluster = false."
  value       = one(azurerm_kubernetes_cluster.main[*].support_plan)
}
