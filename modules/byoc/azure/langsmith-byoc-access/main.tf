data "azurerm_client_config" "current" {}

# The consent step: the service principal of the LangSmith multi-tenant app
# in this tenant. It has no Microsoft Graph permissions. Its only access is
# the role assignments in data_planes.tf. use_existing uses a service
# principal from an earlier admin consent.
resource "azuread_service_principal" "langsmith" {
  client_id    = var.langsmith_app_client_id
  use_existing = true
}
