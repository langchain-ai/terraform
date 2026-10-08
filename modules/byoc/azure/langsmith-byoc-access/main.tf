data "azurerm_client_config" "current" {}

# Consent step: the service principal of the LangSmith multi-tenant app in
# this tenant. The app needs no Microsoft Graph permissions; its only access is
# the role assignments below. use_existing adopts a service principal that a
# previous admin consent already created.
resource "azuread_service_principal" "langsmith" {
  client_id    = var.langsmith_app_client_id
  use_existing = true
}

locals {
  # Built-in roles for the LangSmith service principal on each data plane
  # resource group. The data plane Crossplane compositions create role
  # assignments, a custom role definition scoped to the resource group, and
  # management locks, which Contributor alone cannot do.
  langsmith_roles = {
    contributor               = "Contributor"
    user_access_administrator = "User Access Administrator"
  }

  role_assignments = {
    for pair in setproduct(keys(var.data_planes), keys(local.langsmith_roles)) :
    "${pair[0]}/${pair[1]}" => {
      data_plane = pair[0]
      role       = local.langsmith_roles[pair[1]]
    }
  }
}

# One dedicated resource group per data plane. LangSmith deploys the data
# plane into it and deletes the whole resource group with the data plane.
resource "azurerm_resource_group" "data_plane" {
  for_each = var.data_planes

  name     = "langsmith-byoc-${each.key}"
  location = each.value.location
  tags     = merge(var.tags, each.value.tags)
}

# Key Vault names are global and at most 24 characters.
resource "random_string" "key_vault_suffix" {
  for_each = var.data_planes

  length  = 6
  upper   = false
  special = false
}

# Holds the 2 secrets that the LangSmith control plane writes through ARM. The
# data plane reads them through a private endpoint that LangSmith creates, so
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
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = 90

  network_acls {
    default_action = "Deny"
    bypass         = "None"
  }

  tags = merge(var.tags, each.value.tags)
}

# Scoped to the data plane resource group only, never to the subscription.
# LangSmith reads the description to verify that the owner of this
# subscription is the LangSmith organization with this external ID.
resource "azurerm_role_assignment" "langsmith" {
  for_each = local.role_assignments

  scope                = azurerm_resource_group.data_plane[each.value.data_plane].id
  role_definition_name = each.value.role
  principal_id         = azuread_service_principal.langsmith.object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
}
