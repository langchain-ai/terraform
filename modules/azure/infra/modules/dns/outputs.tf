output "zone_id" {
  description = "Resource ID of the Azure DNS zone"
  value       = azurerm_dns_zone.main.id
}

output "zone_name" {
  description = "Name of the DNS zone (same as the domain)"
  value       = azurerm_dns_zone.main.name
}

output "nameservers" {
  description = "Azure nameservers for this zone — configure these as NS records at your domain registrar to delegate the zone"
  value       = azurerm_dns_zone.main.name_servers
}

output "a_record_fqdn" {
  description = "Fully qualified domain name of the A record"
  value       = azurerm_dns_a_record.langsmith.fqdn
}
