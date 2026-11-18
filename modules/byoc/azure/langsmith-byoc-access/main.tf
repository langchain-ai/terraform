data "azurerm_client_config" "current" {}

# The LangSmith identity: a user-assigned managed identity in your
# subscription. LangSmith signs in as it with a token from its OIDC issuer.
# The federated credential accepts only tokens with the subject
# byoc:<external_id>, so no other LangSmith organization can use it. Creating
# it needs Azure RBAC on the subscription only, no Entra ID role.
#
# It lives in its own resource group, not in a data plane resource group,
# because LangSmith can delete resources in the data plane resource groups.
resource "azurerm_resource_group" "langsmith_identity" {
  name     = "langsmith-byoc-identity"
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "langsmith" {
  name                = "langsmith-byoc"
  location            = azurerm_resource_group.langsmith_identity.location
  resource_group_name = azurerm_resource_group.langsmith_identity.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "langsmith" {
  name                = "langsmith-byoc"
  resource_group_name = azurerm_resource_group.langsmith_identity.name
  parent_id           = azurerm_user_assigned_identity.langsmith.id
  issuer              = var.langsmith_issuer
  subject             = "byoc:${var.external_id}"
  audience            = ["api://AzureADTokenExchange"]
}

locals {
  langsmith_principal_id = azurerm_user_assigned_identity.langsmith.principal_id
}
