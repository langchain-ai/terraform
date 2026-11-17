# In-cluster deployment builds on a data plane with byo_iam = true. LangSmith
# creates the registry and the federated identity credential that binds the
# build identity to the langsmith/lsd-build service account. The module
# creates the identity and the grants, which LangSmith cannot.

locals {
  deployment_builds_data_planes = { for key, dp in local.byo_iam_data_planes : key => dp if dp.deployment_builds }
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

# LangSmith creates the registry when builds turn on, so the scope is the
# resource group. The deployment builds registry is the only one in it.
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
