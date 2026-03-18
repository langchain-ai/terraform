output "zone_name" {
  description = "Name of the Cloud DNS managed zone"
  value       = local.zone_name
}

output "name_servers" {
  description = "Name servers for the Cloud DNS zone (only populated when create_zone = true)"
  value       = var.create_zone ? google_dns_managed_zone.langsmith[0].name_servers : []
}

output "certificate_name" {
  description = "Name of the Google-managed SSL certificate (empty string if create_certificate = false)"
  value       = var.create_certificate ? google_compute_managed_ssl_certificate.langsmith[0].name : ""
}
