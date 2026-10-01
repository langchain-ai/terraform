output "tenant_id" {
  description = "Microsoft Entra tenant ID. Enter it in the LangSmith data plane form."
  value       = data.azurerm_subscription.current.tenant_id
}

output "subscription_id" {
  description = "Subscription ID of the data plane. Enter it in the LangSmith data plane form."
  value       = data.azurerm_subscription.current.subscription_id
}

output "managed_identity_client_id" {
  description = "Client ID of the managed identity that LangSmith signs in as. Enter it in the LangSmith data plane form."
  value       = azurerm_user_assigned_identity.langsmith.client_id
}

output "managed_identity_principal_id" {
  description = "Object ID of the managed identity, for your audit queries."
  value       = azurerm_user_assigned_identity.langsmith.principal_id
}

output "blob_objects_role_name" {
  description = "Name of the custom blob role that the LangSmith compositions assign."
  value       = azurerm_role_definition.blob_objects.name
}
