# One set of these resources for each entry in var.data_planes. Add the entry
# before you create the data plane. Remove it after you delete the data plane.

# The data plane resource group. LangSmith keeps it, the Key Vault, and the
# trace and SmithDB storage accounts when you delete the data plane.
resource "azurerm_resource_group" "data_plane" {
  for_each = var.data_planes

  name     = "langsmith-byoc-${each.key}"
  location = each.value.location
  tags     = merge(var.tags, each.value.tags)
}

# Key Vault names are global, with a maximum of 24 characters. Custom role
# names are unique in the tenant, so the roles use the same suffix.
resource "random_string" "key_vault_suffix" {
  for_each = var.data_planes

  length  = 6
  upper   = false
  special = false
}

# The control plane writes the data plane secret here through ARM. The data
# plane reads it through a private endpoint. No public access, no bypass.
resource "azurerm_key_vault" "data_plane" {
  for_each = var.data_planes

  # ls-<first 14 characters of the key>-<suffix>: a maximum of 24 characters.
  # The key has no consecutive hyphens, so only a trailing hyphen can occur.
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

# The LangSmith custom role. Its scope is the data plane resource group.
# reduced_access changes the actions in place. See roles.tf.
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

# The scope is the data plane resource group only. LangSmith reads the
# description to verify the external ID of the subscription owner.
resource "azurerm_role_assignment" "langsmith_byoc" {
  for_each = var.data_planes

  scope              = azurerm_resource_group.data_plane[each.key].id
  role_definition_id = azurerm_role_definition.langsmith_byoc[each.key].role_definition_resource_id
  principal_id       = azuread_service_principal.langsmith.object_id
  principal_type     = "ServicePrincipal"
  description        = var.external_id
}

# LangSmith creates role assignments only at creation and teardown.
# reduced_access removes this assignment. byo_iam never creates it.
resource "azurerm_role_assignment" "langsmith_user_access_administrator" {
  for_each = { for key, data_plane in var.data_planes : key => data_plane if !data_plane.reduced_access && !data_plane.byo_iam }

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.langsmith.object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
}
