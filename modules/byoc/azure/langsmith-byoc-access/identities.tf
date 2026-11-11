# One set for each data plane with byo_iam = true. LangSmith creates only the
# federated identity credentials, because they need the AKS OIDC issuer.

locals {
  byo_iam_data_planes = { for key, dp in var.data_planes : key => dp if dp.byo_iam }

  # LangSmith expects the name langsmith-<short>-identity.
  byo_iam_identity_shorts = ["aks", "kubelet", "cert-manager", "external-secrets", "workload", "postgres-setup", "smithdb", "sandbox", "deployment-metrics-collector", "deployment-builds"]

  byo_iam_identities = merge([
    for key, dp in local.byo_iam_data_planes : {
      for short in local.byo_iam_identity_shorts : "${key}/${short}" => {
        data_plane = key
        short      = short
        tags       = dp.tags
      }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "data_plane" {
  for_each = local.byo_iam_identities

  name                = "langsmith-${each.value.short}-identity"
  resource_group_name = azurerm_resource_group.data_plane[each.value.data_plane].name
  location            = azurerm_resource_group.data_plane[each.value.data_plane].location
  tags                = merge(var.tags, each.value.tags)
}

# A condition on each assignment limits this role to some containers.
resource "azurerm_role_definition" "blob_objects" {
  for_each = local.byo_iam_data_planes

  name              = "langsmith-byoc-${each.key}-blob-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "Read the LangSmith containers and read, write, or delete their blobs."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = ["Microsoft.Storage/storageAccounts/blobServices/containers/read"]
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
    ]
  }
}

# The VNet does not exist yet, so the scope is the resource group.
resource "azurerm_role_assignment" "aks_network" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}

# AKS gives the kubelet identity to the nodes. The scope is only that identity.
resource "azurerm_role_assignment" "aks_kubelet_operator" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_user_assigned_identity.data_plane["${each.key}/kubelet"].id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}

# cert-manager writes the DNS records for certificate challenges.
resource "azurerm_role_assignment" "cert_manager_dns" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/cert-manager"].principal_id
  principal_type       = "ServicePrincipal"
}

# external-secrets reads the control plane secret.
resource "azurerm_role_assignment" "external_secrets_key_vault" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_key_vault.data_plane[each.key].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/external-secrets"].principal_id
  principal_type       = "ServicePrincipal"
}

# Blob access for each identity. The storage accounts do not exist yet, so the
# scope is the resource group. A condition sets the containers.
locals {
  byo_iam_blob_access = {
    workload = { read = ["langsmith"], write = ["langsmith"] }
    smithdb  = { read = ["langsmith", "smithdb"], write = ["smithdb"] }
    sandbox  = { read = ["sandboxes"], write = ["sandboxes"] }
  }

  byo_iam_blob_conditions = {
    for short, access in local.byo_iam_blob_access : short => <<-EOT
      (
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})
        OR
        (${join(" OR ", [for container in access.read : "@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '${container}'"])})
      )
      AND
      (
        (
          !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
          AND
          !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})
        )
        OR
        (${join(" OR ", [for container in access.write : "@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals '${container}'"])})
      )
    EOT
  }
}

resource "azurerm_role_assignment" "blob_objects" {
  for_each = merge([
    for key, dp in local.byo_iam_data_planes : {
      for short in keys(local.byo_iam_blob_access) : "${key}/${short}" => { data_plane = key, short = short }
    }
  ]...)

  scope              = azurerm_resource_group.data_plane[each.value.data_plane].id
  role_definition_id = azurerm_role_definition.blob_objects[each.value.data_plane].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.data_plane[each.key].principal_id
  principal_type     = "ServicePrincipal"
  condition          = local.byo_iam_blob_conditions[each.value.short]
  condition_version  = "2.0"
}

# The workload identity reads the data store metrics.
resource "azurerm_role_assignment" "workload_monitoring" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/workload"].principal_id
  principal_type       = "ServicePrincipal"
}

# Deployment observability. host-backend reads logs and metrics as the workload
# identity. The collector writes metrics as its own identity. The workspaces
# do not exist yet, so the scope is the resource group.
resource "azurerm_role_assignment" "workload_observability" {
  for_each = merge([
    for key, dp in local.byo_iam_data_planes : {
      for role in ["Log Analytics Reader", "Monitoring Data Reader"] : "${key}/${role}" => { data_plane = key, role = role }
    }
  ]...)

  scope                = azurerm_resource_group.data_plane[each.value.data_plane].id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.value.data_plane}/workload"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "metrics_collector_publisher" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/deployment-metrics-collector"].principal_id
  principal_type       = "ServicePrincipal"
}

# Deployment builds. Build Jobs push images as the deployment builds identity.
# The nodes pull them as the kubelet identity. The registry does not exist yet,
# so the scope is the resource group.
resource "azurerm_role_assignment" "deployment_builds_push" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/deployment-builds"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "kubelet_pull" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/kubelet"].principal_id
  principal_type       = "ServicePrincipal"
}

# LangSmith runs the cluster workloads. The cluster does not exist yet, so the
# scope is the resource group.
resource "azurerm_role_assignment" "langsmith_aks_rbac_cluster_admin" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_service_principal.langsmith.object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
}
