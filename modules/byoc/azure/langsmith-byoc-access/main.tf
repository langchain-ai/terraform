data "azurerm_client_config" "current" {}

# Consent step: the service principal of the LangSmith multi-tenant app in
# this tenant. The app needs no Microsoft Graph permissions; its only access is
# the role assignments in data_planes.tf and identities.tf.
#
# create_service_principal = true: the module creates the service principal.
# use_existing adopts one that a previous admin consent already created, but
# still writes to it, so the caller needs an Entra ID role either way.
resource "azuread_service_principal" "langsmith" {
  count = var.create_service_principal ? 1 : 0

  client_id    = var.langsmith_app_client_id
  use_existing = true
}

# create_service_principal = false: an Entra admin created the service
# principal with `az ad sp create`. The module only reads it, so the caller
# needs no Entra ID role.
data "azuread_service_principal" "langsmith" {
  count = var.create_service_principal ? 0 : 1

  client_id = var.langsmith_app_client_id
}

moved {
  from = azuread_service_principal.langsmith
  to   = azuread_service_principal.langsmith[0]
}

locals {
  langsmith_service_principal_object_id = (
    var.create_service_principal
    ? azuread_service_principal.langsmith[0].object_id
    : data.azuread_service_principal.langsmith[0].object_id
  )
}
