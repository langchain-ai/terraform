# Deployment builds and CLI builds on a data plane with byo_iam = true.
# LangSmith creates the registry, the CLI build source storage account, and
# the federated identity credentials; the build identity's trusts only the
# langsmith/lsd-build service account. The module creates the identities, the
# roles, and the grants, which LangSmith cannot.

locals {
  deployment_builds_data_planes = { for key, dp in local.byo_iam_data_planes : key => dp if dp.deployment_builds }
  cli_builds_data_planes        = { for key, dp in local.byo_iam_data_planes : key => dp if dp.cli_builds }
}

# AKS creates the kubelet identity with the cluster, so the data plane must be
# active before deployment_builds is set.
data "azurerm_resources" "deployment_builds_cluster" {
  for_each = local.deployment_builds_data_planes

  resource_group_name = "langsmith-byoc-${each.key}"
  type                = "Microsoft.ContainerService/managedClusters"

  lifecycle {
    postcondition {
      condition     = length(self.resources) == 1
      error_message = "deployment_builds needs the AKS cluster of data plane ${each.key}. Set it after the data plane is active."
    }
  }
}

data "azurerm_kubernetes_cluster" "deployment_builds" {
  for_each = data.azurerm_resources.deployment_builds_cluster

  name                = each.value.resources[0].name
  resource_group_name = each.value.resource_group_name
}

# LangSmith creates the registry and the source storage account when builds
# turn on, so the grants are on the resource group. The deployment builds
# registry is the only registry in it.
resource "azurerm_role_assignment" "deployment_builds_push" {
  for_each = local.deployment_builds_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/deployment-builds"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deployment_builds_kubelet_pull" {
  for_each = data.azurerm_kubernetes_cluster.deployment_builds

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "AcrPull"
  principal_id         = each.value.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"
}

# host-backend mints each CLI deployment's repository-scoped push token in the
# registry, and deletes its images with the deployment.
resource "azurerm_role_definition" "cli_builds_registry" {
  for_each = local.cli_builds_data_planes

  name              = "langsmith-byoc-${each.key}-cli-builds-acr-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "Manage repository-scoped push tokens and scope maps in the deployment builds registry."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = [
      "Microsoft.ContainerRegistry/registries/scopeMaps/read",
      "Microsoft.ContainerRegistry/registries/scopeMaps/write",
      "Microsoft.ContainerRegistry/registries/scopeMaps/delete",
      "Microsoft.ContainerRegistry/registries/tokens/read",
      "Microsoft.ContainerRegistry/registries/tokens/write",
      "Microsoft.ContainerRegistry/registries/tokens/delete",
      "Microsoft.ContainerRegistry/registries/generateCredentials/action",
      "Microsoft.ContainerRegistry/registries/operationStatuses/read",
    ]
  }
}

resource "azurerm_role_assignment" "cli_builds_registry" {
  for_each = azurerm_role_definition.cli_builds_registry

  scope              = azurerm_resource_group.data_plane[each.key].id
  role_definition_id = each.value.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.data_plane["${each.key}/host-backend"].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "cli_builds_image_delete" {
  for_each = local.cli_builds_data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "AcrDelete"
  principal_id         = azurerm_user_assigned_identity.data_plane["${each.key}/host-backend"].principal_id
  principal_type       = "ServicePrincipal"
}

# host-backend signs user delegation URLs for the CLI's source uploads and the
# build Job's downloads. A signed URL never grants more than its signer.
resource "azurerm_role_definition" "cli_builds_sources" {
  for_each = local.cli_builds_data_planes

  name              = "langsmith-byoc-${each.key}-cli-builds-source-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "Sign user delegation URLs for deployment source uploads and build downloads."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = ["Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"]
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]
  }
}

# The condition keeps the blob actions to the source container, away from the
# trace, SmithDB, and sandbox containers in the resource group.
resource "azurerm_role_assignment" "cli_builds_sources" {
  for_each = azurerm_role_definition.cli_builds_sources

  scope              = azurerm_resource_group.data_plane[each.key].id
  role_definition_id = each.value.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.data_plane["${each.key}/host-backend"].principal_id
  principal_type     = "ServicePrincipal"
  condition          = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})
        AND
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
        AND
        !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'})
      )
      OR
      @Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals 'source'
    )
  EOT
  condition_version  = "2.0"
}
