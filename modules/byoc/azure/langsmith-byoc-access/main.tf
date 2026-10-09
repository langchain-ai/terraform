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
  # resource group. Without byo_iam, the data plane Crossplane compositions
  # create role assignments, a custom role definition scoped to the resource
  # group, and management locks, which Contributor alone cannot do. With
  # byo_iam, this module creates the identities and their role assignments, so
  # LangSmith gets no User Access Administrator. It still creates the federated
  # identity credentials, which Contributor allows, and it needs cluster admin
  # on the AKS cluster that it creates.
  langsmith_roles = merge(
    { contributor = "Contributor" },
    var.byo_iam
    ? tomap({ aks_rbac_cluster_admin = "Azure Kubernetes Service RBAC Cluster Admin" })
    : tomap({ user_access_administrator = "User Access Administrator" }),
  )

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

# ---------------------------------------------------------------------------
# Bring your own IAM (byo_iam = true)
#
# The customer creates every identity and authorization resource. The data
# plane Crossplane compositions only observe the identities by name, so the
# names below are a contract with LangSmith. The grants use the resource group
# as scope because the VNet, the cluster, the storage accounts, and the DNS
# zone do not exist yet at apply time. The resource group holds one data plane
# only.
# ---------------------------------------------------------------------------

locals {
  byo_iam_data_planes = var.byo_iam ? var.data_planes : {}

  # langsmith-postgres-setup gets no Azure role: LangSmith makes it the
  # PostgreSQL Entra admin.
  byo_iam_identity_names = [
    "langsmith-aks",
    "langsmith-cert-manager",
    "langsmith-external-secrets",
    "langsmith-workload",
    "langsmith-postgres-setup",
    "langsmith-smithdb",
  ]

  byo_iam_identities = {
    for pair in setproduct(keys(local.byo_iam_data_planes), local.byo_iam_identity_names) :
    "${pair[0]}/${pair[1]}" => {
      data_plane = pair[0]
      name       = pair[1]
    }
  }

  # Built-in role of each identity that needs one, on the resource group or on
  # the data plane Key Vault.
  byo_iam_builtin_roles = {
    "langsmith-aks"              = { role = "Network Contributor", key_vault_scope = false }
    "langsmith-cert-manager"     = { role = "DNS Zone Contributor", key_vault_scope = false }
    "langsmith-external-secrets" = { role = "Key Vault Secrets User", key_vault_scope = true }
  }

  byo_iam_builtin_role_assignments = {
    for pair in setproduct(keys(local.byo_iam_data_planes), keys(local.byo_iam_builtin_roles)) :
    "${pair[0]}/${pair[1]}" => merge(local.byo_iam_builtin_roles[pair[1]], {
      data_plane = pair[0]
    })
  }

  # Identities that read and write the trace blobs.
  byo_iam_blob_identity_names = ["langsmith-workload", "langsmith-smithdb"]

  byo_iam_blob_role_assignments = {
    for pair in setproduct(keys(local.byo_iam_data_planes), local.byo_iam_blob_identity_names) :
    "${pair[0]}/${pair[1]}" => pair[0]
  }
}

resource "azurerm_user_assigned_identity" "byo_iam" {
  for_each = local.byo_iam_identities

  name                = each.value.name
  location            = azurerm_resource_group.data_plane[each.value.data_plane].location
  resource_group_name = azurerm_resource_group.data_plane[each.value.data_plane].name
  tags                = merge(var.tags, var.data_planes[each.value.data_plane].tags)
}

# Role definition names are unique in the tenant, so the name carries the
# resource group name.
resource "azurerm_role_definition" "blob_objects" {
  for_each = local.byo_iam_data_planes

  name              = "${azurerm_resource_group.data_plane[each.key].name}-blob-objects"
  scope             = azurerm_resource_group.data_plane[each.key].id
  assignable_scopes = [azurerm_resource_group.data_plane[each.key].id]
  description       = "Read the trace containers and read, write, or delete their blobs."

  permissions {
    actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/read",
    ]
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
    ]
  }
}

# The keys match the identity keys: "<data plane>/<identity name>".
resource "azurerm_role_assignment" "byo_iam_builtin" {
  for_each = local.byo_iam_builtin_role_assignments

  scope = (
    each.value.key_vault_scope
    ? azurerm_key_vault.data_plane[each.value.data_plane].id
    : azurerm_resource_group.data_plane[each.value.data_plane].id
  )
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.byo_iam[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# The value of each key is the data plane key.
resource "azurerm_role_assignment" "byo_iam_blob_objects" {
  for_each = local.byo_iam_blob_role_assignments

  scope              = azurerm_resource_group.data_plane[each.value].id
  role_definition_id = azurerm_role_definition.blob_objects[each.value].role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.byo_iam[each.key].principal_id
  principal_type     = "ServicePrincipal"
}
