data "azurerm_client_config" "current" {}

# Consent step: the service principal of the LangSmith multi-tenant app in
# this tenant. The app needs no Microsoft Graph permissions; its only access is
# the role assignments below. use_existing adopts a service principal that a
# previous admin consent already created.
resource "azuread_service_principal" "langsmith" {
  client_id    = var.langsmith_app_client_id
  use_existing = true
}

# One dedicated resource group per data plane. LangSmith deploys the data
# plane into it and deletes the whole resource group with the data plane.
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

# The two LangSmith custom roles of each data plane. Their scope is the data
# plane resource group, so they cannot apply anywhere else. See roles.tf.
resource "azurerm_role_definition" "langsmith_byoc" {
  for_each = var.data_planes

  name              = "langsmith-byoc-${each.key}-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "LangSmith BYOC: create, update, and delete the data plane in this resource group."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = local.langsmith_byoc_actions
  }
}

resource "azurerm_role_definition" "langsmith_byoc_reduced" {
  for_each = var.data_planes

  name              = "langsmith-byoc-reduced-${each.key}-${random_string.key_vault_suffix[each.key].result}"
  scope             = azurerm_resource_group.data_plane[each.key].id
  description       = "LangSmith BYOC: keep the running data plane in this resource group up to date."
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]

  permissions {
    actions = local.langsmith_byoc_reduced_actions
  }
}

# Scoped to the data plane resource group only, never to the subscription.
# LangSmith reads the description to verify that the owner of this
# subscription is the LangSmith organization with this external ID.
#
# reduced_access switches the assignment between the two custom roles. The new
# assignment comes before the old one goes, so LangSmith keeps access.
resource "azurerm_role_assignment" "langsmith_byoc" {
  for_each = var.data_planes

  scope = azurerm_resource_group.data_plane[each.key].id
  role_definition_id = (
    each.value.reduced_access
    ? azurerm_role_definition.langsmith_byoc_reduced[each.key].role_definition_resource_id
    : azurerm_role_definition.langsmith_byoc[each.key].role_definition_resource_id
  )
  principal_id   = azuread_service_principal.langsmith.object_id
  principal_type = "ServicePrincipal"
  description    = var.external_id

  lifecycle {
    create_before_destroy = true
  }
}

# The data plane creates role assignments for its workload identities, the
# custom blob role of the data plane, and delete locks for PostgreSQL and
# Redis.
resource "azurerm_role_assignment" "langsmith_user_access_administrator" {
  for_each = var.data_planes

  scope                = azurerm_resource_group.data_plane[each.key].id
  role_definition_name = "User Access Administrator"
  principal_id         = azuread_service_principal.langsmith.object_id
  principal_type       = "ServicePrincipal"
  description          = var.external_id
}
