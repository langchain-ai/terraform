# Outputs for Certificate Manager Module

output "certificate_name" {
  description = "Name of the Google-managed certificate"
  value       = google_certificate_manager_certificate.langsmith.name
}

output "certificate_map_name" {
  description = "Name of the certificate map, for the networking.gke.io/certmap Gateway annotation"
  value       = google_certificate_manager_certificate_map.langsmith.name
}

output "dns_authorization_record" {
  description = "CNAME record that proves control of the domain (name, type, data). Null when the certificate uses an issuance config."
  value = local.use_dns_authorization ? {
    name = google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].name
    type = google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].type
    data = google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].data
  } : null
}

output "dns_authorization_record_managed" {
  description = "Whether Terraform created the DNS authorization record in Cloud DNS"
  value       = length(google_dns_record_set.dns_authorization) > 0
}
