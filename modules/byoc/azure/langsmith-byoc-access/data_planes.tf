# Everything in this file exists once per entry in var.data_planes. Add an
# entry to prepare a new data plane; remove it after you delete the data plane
# in LangSmith.

# One dedicated resource group per data plane. LangSmith deploys the data
# plane into it. When you delete the data plane, LangSmith keeps the resource
# group, the Key Vault, and the Blob storage accounts with trace and SmithDB
# data.
resource "azurerm_resource_group" "data_plane" {
  for_each = var.data_planes

  name     = "langsmith-byoc-${each.key}"
  location = each.value.location
  tags     = merge(var.tags, each.value.tags)
}

# Key Vault names are global and at most 24 characters. Custom role names are
# unique in the tenant, so the roles use the same suffix.
resource "random_string" "key_vault_suffix" {
  for_each = var.data_planes

  length  = 6
  upper   = false
  special = false
}

# Holds the secret that the LangSmith control plane writes through ARM. The
# data plane reads it through a private endpoint that LangSmith creates, so
# the vault takes no public traffic and no trusted service bypass.
resource "azurerm_key_vault" "data_plane" {
  for_each = var.data_planes

  # ls-<first 14 characters of the key>-<suffix>: at most 24 characters. The
  # key has no consecutive hyphens, so only a trailing one needs removal.
  name                = "ls-${trimsuffix(substr(each.key, 0, 14), "-")}-${random_string.key_vault_suffix[each.key].result}"
  location            = azurerm_resource_group.data_plane[each.key].location
  resource_group_name = azurerm_resource_group.data_plane[each.key].name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90

  network_acls {
    default_action = "Deny"
    bypass         = "None"
  }

  tags = merge(var.tags, each.value.tags)
}

# The LangSmith custom role of each data plane. Its scope is the data plane
# resource group, so it cannot apply anywhere else. reduced_access changes the
# actions in place; the role and its assignment stay. See roles.tf.
resource "azurerm_role_definition" "langsmith_byoc" {
  for_each = var.data_planes

  name              = "langsmith-byoc-${each.key}-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "LangSmith BYOC: manage the data plane in this resource group."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    # Keep the list order. setsubtract sorts it.
    actions = concat(
      [
        for action in(each.value.reduced_access ? local.langsmith_byoc_reduced_actions : local.langsmith_byoc_actions) : action
        if !(each.value.byo_iam && contains(local.langsmith_byoiam_removed_actions, action))
      ],
      each.value.deployment_observability ? (
        each.value.reduced_access ? local.langsmith_byoc_observability_reduced_actions : local.langsmith_byoc_observability_actions
      ) : [],
    )
  }
}

# Scoped to the data plane resource group only, never to the subscription.
# LangSmith reads the description to verify that the owner of this
# subscription is the LangSmith organization with this external ID.
resource "azurerm_role_assignment" "langsmith_byoc" {
  for_each = var.data_planes

  scope              = azurerm_resource_group.data_plane[each.key].id
  role_definition_id = azurerm_role_definition.langsmith_byoc[each.key].role_definition_resource_id
  principal_id       = local.langsmith_service_principal_object_id
  principal_type     = "ServicePrincipal"
  description        = var.external_id
}

# LangSmith creates role assignments only at creation and teardown.
# reduced_access deletes this assignment. byo_iam never creates it.
#
# The condition keeps LangSmith from granting itself data access:
# - No principal can get Owner, Contributor, User Access Administrator, or
#   Role Based Access Control Administrator through this assignment, and
#   LangSmith cannot delete such an assignment.
# - The LangSmith service principal can assign itself only AKS RBAC Cluster
#   Admin, which it uses to deploy into the cluster. It cannot assign itself a
#   storage, Key Vault, or custom role.
resource "azurerm_role_assignment" "langsmith_user_access_administrator" {
  for_each = { for key, data_plane in var.data_planes : key => data_plane if !data_plane.reduced_access && !data_plane.byo_iam }

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "User Access Administrator"
  principal_id         = local.langsmith_service_principal_object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
  condition            = local.langsmith_user_access_administrator_condition
  condition_version    = "2.0"
}

locals {
  # Owner, Contributor, User Access Administrator, Role Based Access Control
  # Administrator.
  langsmith_blocked_role_ids = join(", ", [
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
    "b24988ac-6180-42a0-ab88-20f7382dd24c",
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168",
  ])
  # Azure Kubernetes Service RBAC Cluster Admin.
  langsmith_self_assignable_role_id = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"

  langsmith_user_access_administrator_condition = <<-EOT
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      )
      OR
      (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.langsmith_blocked_role_ids}}
        AND
        (
          @Request[Microsoft.Authorization/roleAssignments:PrincipalId] ForAnyOfAllValues:GuidNotEquals {${local.langsmith_service_principal_object_id}}
          OR
          @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.langsmith_self_assignable_role_id}}
        )
      )
    )
    AND
    (
      (
        !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
      )
      OR
      (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.langsmith_blocked_role_ids}}
      )
    )
  EOT
}
