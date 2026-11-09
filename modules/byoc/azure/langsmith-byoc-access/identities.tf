# Everything in this file exists once per data plane with byo_iam = true. You
# create the data plane identities and their role assignments here, so
# LangSmith needs no User Access Administrator assignment. LangSmith still
# creates the federated identity credentials on the identities: the AKS OIDC
# issuer URL exists only after the cluster exists.

locals {
  byo_iam_data_planes = { for key, dp in var.data_planes : key => dp if dp.byo_iam }

  # The identities that a data plane needs. LangSmith expects the exact name
  # langsmith-<short> for each of them, the same name that it uses when it
  # creates them.
  byo_iam_identity_shorts = ["aks", "cert-manager", "external-secrets", "workload", "postgres-setup", "smithdb", "sandbox"]

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

  name                = "langsmith-${each.value.short}"
  resource_group_name = azurerm_resource_group.data_plane[each.value.data_plane].name
  location            = azurerm_resource_group.data_plane[each.value.data_plane].location
  tags                = merge(var.tags, each.value.tags)
}

# The custom blob role of the data plane. The blob_objects assignments limit it
# to the containers of each identity.
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

# The AKS identity manages the network of the cluster. The VNet does not exist
# yet, so the assignment is at resource group scope. The resource group holds
# one data plane only.
resource "azurerm_role_assignment" "aks_network" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/aks"].principal_id
  principal_type       = "ServicePrincipal"
}

# cert-manager writes DNS records for its certificate challenges.
resource "azurerm_role_assignment" "cert_manager_dns" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/cert-manager"].principal_id
  principal_type       = "ServicePrincipal"
}

# external-secrets reads the secret that the control plane writes.
resource "azurerm_role_assignment" "external_secrets_key_vault" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_key_vault.data_plane[each.key].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/external-secrets"].principal_id
  principal_type       = "ServicePrincipal"
}

# Blob access per identity, by container. The container names are fixed:
# langsmith holds the traces, smithdb the SmithDB files, and sandboxes the
# sandbox data. Each storage account exists only after the data plane does, so
# the assignments use the resource group as scope, and a condition limits each
# identity to its containers.
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

# The workload identity reads the PostgreSQL, Redis, and sandbox storage
# metrics.
resource "azurerm_role_assignment" "workload_monitoring" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/workload"].principal_id
  principal_type       = "ServicePrincipal"
}

# LangSmith operates the workloads in the cluster. The cluster does not exist
# yet; an assignment at resource group scope applies to it.
resource "azurerm_role_assignment" "langsmith_aks_rbac_cluster_admin" {
  for_each = local.byo_iam_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_service_principal.langsmith.object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
}
