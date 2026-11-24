# Azure Policy guardrails on each data plane resource group. A deny policy
# applies to every ARM write, also the writes of the LangSmith service
# principal, so these hold even when the LangSmith role has the action.
#
# - Storage accounts must keep shared key access off. With full access the
#   LangSmith role can list storage keys, but a key is of no use while shared
#   key access is off.
# - Federated identity credentials must trust an AKS OIDC issuer in this
#   tenant. LangSmith cannot federate a managed identity to an issuer outside
#   the tenant and then use that identity from outside the data plane.
#
# The definitions live in the subscription; the assignments apply to the data
# plane resource groups only.

locals {
  langsmith_fic_issuer_field = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/issuer"
  # Guarded by if(): Azure Policy evaluates only the branch that applies, so a
  # short issuer cannot make the index fail.
  langsmith_fic_issuer_part = {
    for index in [2, 3] : index => "[if(greaterOrEquals(length(split(field('${local.langsmith_fic_issuer_field}'), '/')), 5), toLower(split(field('${local.langsmith_fic_issuer_field}'), '/')[${index}]), '')]"
  }
}

resource "azurerm_policy_definition" "storage_shared_key_off" {
  count = length(var.data_planes) > 0 ? 1 : 0

  name         = "langsmith-byoc-storage-shared-key-off"
  display_name = "LangSmith BYOC: storage accounts keep shared key access off"
  description  = "Denies a storage account in a LangSmith BYOC data plane resource group unless allowSharedKeyAccess is false."
  policy_type  = "Custom"
  mode         = "Indexed"

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        { field = "Microsoft.Storage/storageAccounts/allowSharedKeyAccess", notEquals = false },
      ]
    }
    then = { effect = "deny" }
  })
}

resource "azurerm_policy_definition" "federated_credential_issuer" {
  count = length(var.data_planes) > 0 ? 1 : 0

  name         = "langsmith-byoc-federated-credential-issuer"
  display_name = "LangSmith BYOC: federated identity credentials trust an AKS issuer in this tenant"
  description  = "Denies a federated identity credential in a LangSmith BYOC data plane resource group unless its issuer is https://<region>.oic.prod-aks.azure.com/<this tenant>/..."
  policy_type  = "Custom"
  mode         = "All"

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials" },
        {
          anyOf = [
            { field = local.langsmith_fic_issuer_field, notLike = "https://*" },
            { value = local.langsmith_fic_issuer_part[2], notLike = "*.oic.prod-aks.azure.com" },
            { value = local.langsmith_fic_issuer_part[3], notEquals = lower(data.azurerm_client_config.current.tenant_id) },
          ]
        },
      ]
    }
    then = { effect = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "storage_shared_key_off" {
  for_each = var.data_planes

  name                 = "langsmith-byoc-storage-shared-key-off"
  display_name         = "LangSmith BYOC: storage accounts keep shared key access off"
  resource_group_id    = azurerm_resource_group.data_plane[each.key].id
  policy_definition_id = azurerm_policy_definition.storage_shared_key_off[0].id
}

resource "azurerm_resource_group_policy_assignment" "federated_credential_issuer" {
  for_each = var.data_planes

  name                 = "langsmith-byoc-federated-credential-issuer"
  display_name         = "LangSmith BYOC: federated identity credentials trust an AKS issuer in this tenant"
  resource_group_id    = azurerm_resource_group.data_plane[each.key].id
  policy_definition_id = azurerm_policy_definition.federated_credential_issuer[0].id
}
