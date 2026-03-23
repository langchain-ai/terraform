output "profile_id" {
  description = "Resource ID of the Front Door profile"
  value       = azurerm_cdn_frontdoor_profile.fd.id
}

output "endpoint_hostname" {
  description = <<-EOT
    Default Front Door endpoint hostname (e.g. langsmith-fd-prod-abc123.z01.azurefd.net).
    Add a CNAME record at your registrar: custom_domain → this value.
    LangSmith is reachable at https://<endpoint_hostname> before custom domain is configured.
  EOT
  value = azurerm_cdn_frontdoor_endpoint.endpoint.host_name
}

output "custom_domain_validation_token" {
  description = <<-EOT
    DNS TXT validation token for the custom domain.
    Add at your registrar: _dnsauth.<custom_domain>  TXT  <this value>
    Required once so Azure can issue the managed TLS certificate.
    After validation, the certificate is renewed automatically — no further action needed.
  EOT
  value = length(azurerm_cdn_frontdoor_custom_domain.domain) > 0 ? azurerm_cdn_frontdoor_custom_domain.domain[0].validation_token : ""
}

output "custom_domain_certificate_status" {
  description = "Provisioning state of the managed TLS certificate for the custom domain"
  value       = length(azurerm_cdn_frontdoor_custom_domain.domain) > 0 ? azurerm_cdn_frontdoor_custom_domain.domain[0].expiration_date : "no custom domain configured"
}
