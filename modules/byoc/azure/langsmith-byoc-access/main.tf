data "azurerm_client_config" "current" {}

# Consent step: the service principal of the LangSmith multi-tenant app in
# this tenant. The app needs no Microsoft Graph permissions; its only access is
# the role assignments in data_planes.tf. use_existing adopts a service
# principal that a previous admin consent already created.
resource "azuread_service_principal" "langsmith" {
  client_id    = var.langsmith_app_client_id
  use_existing = true
}
