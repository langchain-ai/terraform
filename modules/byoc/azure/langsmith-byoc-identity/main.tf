data "azurerm_subscription" "current" {}

locals {
  subscription_scope = data.azurerm_subscription.current.id
  # The federated credential accepts only this audience. LangSmith requests it from the
  # organization of the caller, so another organization cannot use this identity.
  audience = "api://AzureADTokenExchange/${var.langsmith_external_id}"

  # The roles that the LangSmith compositions assign to the data plane identities. The
  # Role Based Access Control Administrator condition allows only these.
  assignable_built_in_roles = [
    "Network Contributor",
    "Key Vault Secrets User",
    "DNS Zone Contributor",
    "Storage Blob Data Reader",
  ]
  assignable_role_ids = concat(
    [for role in data.azurerm_role_definition.assignable : role.role_definition_id],
    [azurerm_role_definition.blob_objects.role_definition_id],
  )
  assignable_role_list = join(", ", local.assignable_role_ids)

  # Writes and deletes of role assignments are allowed only for the roles above and
  # only for service principals, which include managed identities. So the identity
  # cannot give itself or a person Owner, User Access Administrator, or any other role.
  role_assignment_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_role_list}}
      AND
      @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_role_list}}
      AND
      @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
     )
    )
  EOT

  # Contributor creates the data plane. Locks Contributor sets the delete locks on the
  # databases. AKS RBAC Cluster Admin lets the control plane install the data plane
  # charts, so LangSmith never grants itself cluster administrator access.
  subscription_roles = toset([
    "Contributor",
    "Locks Contributor",
    "Azure Kubernetes Service RBAC Cluster Admin",
  ])
}

data "azurerm_role_definition" "assignable" {
  for_each = toset(local.assignable_built_in_roles)

  name  = each.value
  scope = local.subscription_scope
}

resource "azurerm_resource_group" "identity" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "langsmith" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.identity.name
  location            = azurerm_resource_group.identity.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "langsmith" {
  for_each = toset(var.control_plane_issuers)

  name                      = "langsmith-${substr(sha256(each.value), 0, 12)}"
  user_assigned_identity_id = azurerm_user_assigned_identity.langsmith.id
  issuer                    = each.value
  subject                   = var.control_plane_subject
  audience                  = [local.audience]
}

# One blob role for every data plane in the subscription. The LangSmith compositions find
# it by name, so keep the name in step with BlobObjectsRoleName in smith-go.
resource "azurerm_role_definition" "blob_objects" {
  name        = "LangSmith BYOC Blob Objects (${data.azurerm_subscription.current.subscription_id})"
  scope       = local.subscription_scope
  description = "Read a LangSmith container and read, write, or delete its blobs."

  permissions {
    actions = ["Microsoft.Storage/storageAccounts/blobServices/containers/read"]
    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
    ]
  }

  assignable_scopes = [local.subscription_scope]
}

resource "azurerm_role_assignment" "subscription" {
  for_each = local.subscription_roles

  scope                            = local.subscription_scope
  role_definition_name             = each.value
  principal_id                     = azurerm_user_assigned_identity.langsmith.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "role_assignments" {
  scope                            = local.subscription_scope
  role_definition_name             = "Role Based Access Control Administrator"
  principal_id                     = azurerm_user_assigned_identity.langsmith.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  condition_version                = "2.0"
  condition                        = local.role_assignment_condition
}
