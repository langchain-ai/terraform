output "waf_policy_id" {
  description = "Resource ID of the WAF policy — attach to Application Gateway or Azure Front Door"
  value       = azurerm_web_application_firewall_policy.waf.id
}

output "waf_policy_name" {
  description = "Name of the WAF policy"
  value       = azurerm_web_application_firewall_policy.waf.name
}
