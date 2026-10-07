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

output "workload_identity_service_accounts" {
  description = "Service accounts federated with the LangSmith workload identity."
  value       = local.service_accounts_for_workload_identity
}

output "live_network_profile" {
  description = "The network profile Azure reports for the cluster at plan time: mode (node-subnet or overlay), data plane, policy engine (none when no engine is installed), pod range (null in node-subnet mode) and outbound type (null when the read does not carry one). null until the cluster exists, and when create_cluster = false."
  value = local.live_cluster == null ? null : {
    mode      = coalesce(try(local.live_cluster.mode, null), "node-subnet")
    dataplane = coalesce(try(local.live_cluster.dataplane, null), "azure")
    policy    = coalesce(try(local.live_cluster.policy, null), "none")
    pod_cidr  = try(local.live_cluster.pod_cidr, null)
    outbound  = try(local.live_cluster.outbound, null)
  }
}

output "live_access_profile" {
  description = "API server access Azure reports for the cluster at plan time: whether it is private, its private DNS zone (\"system\", \"none\", a zone ID, or null on a public cluster), whether Entra integration is on, and the control-plane identity (\"system\" or \"user\", null when Azure reports none) with its lowercased user-assigned identity IDs. null until the cluster exists, and when create_cluster = false."
  value = local.live_cluster == null ? null : {
    private          = try(local.live_cluster.private, null) == true
    private_dns_zone = try(local.live_cluster.private_dns_zone, null)
    entra            = try(local.live_cluster.entra, null) == true
    identity         = lookup({ systemassigned = "system", userassigned = "user" }, lower(coalesce(try(local.live_cluster.identity, null), "none")), null)
    identity_ids     = [for id in keys(coalesce(try(local.live_cluster.identity_ids, null), {})) : lower(id)]
  }
}

output "control_plane_identity" {
  description = "The control-plane identity requested: \"system\" or \"user\", with the user-assigned identity's resource ID (built from its name when the module creates it, so known at plan). null when create_cluster = false."
  value = !var.create_cluster ? null : {
    type = local.control_plane_user ? "user" : "system"
    id   = local.control_plane_identity_id
  }
}

output "control_plane_principal_id" {
  description = "Principal ID of the user-assigned control-plane identity, for the network owner's grants. null with a system-assigned identity, and when create_cluster = false."
  value       = local.control_plane_principal_id
}

output "network_profile" {
  description = "The network profile the cluster is planned or created with: plugin mode (null is node-subnet), pod_cidr, data plane, policy engine and outbound type. null when create_cluster = false."
  # Keyed off the flag rather than the resource object: a comparison against the
  # whole object would carry its sensitive kube-config marks into this output.
  value = !var.create_cluster ? null : {
    network_plugin_mode = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_plugin_mode)
    pod_cidr            = one(azurerm_kubernetes_cluster.main[*].network_profile[0].pod_cidr)
    network_data_plane  = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_data_plane)
    network_policy      = one(azurerm_kubernetes_cluster.main[*].network_profile[0].network_policy)
    outbound_type       = one(azurerm_kubernetes_cluster.main[*].network_profile[0].outbound_type)
  }
}

output "access_profile" {
  description = "API server access and identity the cluster is planned or created with: private endpoint and DNS zone (null on a public cluster), local accounts, Entra with Azure RBAC, and the control-plane identity. null when create_cluster = false."
  value = !var.create_cluster ? null : {
    private_cluster_enabled = one(azurerm_kubernetes_cluster.main[*].private_cluster_enabled)
    private_dns_zone_id     = var.private_cluster_enabled ? one(azurerm_kubernetes_cluster.main[*].private_dns_zone_id) : null
    local_account_disabled  = one(azurerm_kubernetes_cluster.main[*].local_account_disabled)
    azure_rbac_enabled      = try(one(azurerm_kubernetes_cluster.main[*].azure_active_directory_role_based_access_control)[0].azure_rbac_enabled, false)
    admin_group_object_ids  = try(one(azurerm_kubernetes_cluster.main[*].azure_active_directory_role_based_access_control)[0].admin_group_object_ids, [])
    identity_type           = one(azurerm_kubernetes_cluster.main[*].identity[0].type)
    identity_ids            = one(azurerm_kubernetes_cluster.main[*].identity[0].identity_ids)
  }
}

output "sku_tier" {
  description = "The AKS tier the cluster is planned or created with. null when create_cluster = false."
  value       = one(azurerm_kubernetes_cluster.main[*].sku_tier)
}

output "default_node_pool_os_sku" {
  description = "OS SKU the default node pool is planned or created with. null when create_cluster = false."
  value       = one(azurerm_kubernetes_cluster.main[*].default_node_pool[0].os_sku)
}

output "node_pool_os_skus" {
  description = "OS SKU of each additional node pool, keyed by pool name."
  value       = { for name, pool in azurerm_kubernetes_cluster_node_pool.node_pool : name => pool.os_sku }
}

output "support_plan" {
  description = "The AKS support plan the cluster is planned or created with. null when create_cluster = false."
  value       = one(azurerm_kubernetes_cluster.main[*].support_plan)
}

output "envoy_gateway_version" {
  description = "Version of the Envoy Gateway release, empty when ingress_controller is not 'envoy-gateway'. k8s-bootstrap reads it to install cert-manager after the Gateway API CRDs this release ships."
  value       = join("", helm_release.envoy_gateway[*].version)
}

output "node_subnet_ids" {
  description = "Distinct subnets the cluster's node pools run in, lowercased. A created cluster runs in subnet_id alone."
  value       = var.create_cluster ? [var.subnet_id] : distinct([for id in compact(data.azurerm_kubernetes_cluster.existing[0].agent_pool_profile[*].vnet_subnet_id) : lower(id)])
}

output "control_plane_grants" {
  description = "The role assignments the module makes for the user-assigned control-plane identity, as role and scope. Empty with a system-assigned identity, and when the grants are left to the network's owner."
  value = [
    for r in concat(azurerm_role_assignment.control_plane_network_contributor, azurerm_role_assignment.control_plane_dns_zone_contributor) :
    { role = r.role_definition_name, scope = r.scope }
  ]
}

output "kube_auth" {
  description = "How the module's Kubernetes and Helm providers sign in to the cluster: 'entra' (kubelogin with the caller's az session) or 'certificate' (kube_config client certificate)."
  value       = local.kube_auth
}
