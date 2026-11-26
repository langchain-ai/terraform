# Certificate Manager Module - Google-managed TLS certificate for the GKE Gateway
#
# Used when tls_certificate_source = "google-managed". The certificate is served
# by the Google Cloud load balancer that a global GKE Gateway class creates, so
# nothing in the cluster holds the private key, and there is no cert-manager.
#
# Domain control is proven with a DNS authorization: one CNAME record, created
# here when the module is given a Cloud DNS zone, or added by the operator from
# the dns_authorization_record output. Unlike an HTTP challenge, it needs no
# inbound port 80 and works before the domain points at the load balancer, so a
# first deploy can be HTTPS in one pass.
#
# With issuance_config set, the certificate is issued by the operator's own
# Certificate Authority Service pool instead of a public CA, and no DNS
# authorization is needed.

locals {
  use_dns_authorization = var.issuance_config == ""

  domains = var.include_wildcard ? [var.domain, "*.${var.domain}"] : [var.domain]
}

resource "google_certificate_manager_dns_authorization" "langsmith" {
  count = local.use_dns_authorization ? 1 : 0

  project     = var.project_id
  name        = "${var.name}-dnsauth"
  description = "Proves control of ${var.domain} for the LangSmith certificate"
  domain      = var.domain
  labels      = var.labels
}

# The authorization record never changes for the life of the authorization, so
# it is safe to manage alongside the zone. An operator who runs DNS elsewhere
# leaves dns_zone_name empty and adds the record from the module output.
resource "google_dns_record_set" "dns_authorization" {
  count = local.use_dns_authorization && var.dns_zone_name != "" ? 1 : 0

  project      = var.project_id
  managed_zone = var.dns_zone_name
  name         = google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.langsmith[0].dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "langsmith" {
  project     = var.project_id
  name        = var.name
  description = "LangSmith TLS certificate for ${var.domain}"
  labels      = var.labels

  managed {
    domains            = local.domains
    dns_authorizations = local.use_dns_authorization ? [google_certificate_manager_dns_authorization.langsmith[0].id] : null
    issuance_config    = local.use_dns_authorization ? null : var.issuance_config
  }
}

# A global GKE Gateway reads its certificates from a certificate map, named in
# the networking.gke.io/certmap annotation. PRIMARY serves this certificate for
# every hostname, including clients that send no SNI.
resource "google_certificate_manager_certificate_map" "langsmith" {
  project     = var.project_id
  name        = "${var.name}-map"
  description = "Certificate map for the LangSmith GKE Gateway"
  labels      = var.labels
}

resource "google_certificate_manager_certificate_map_entry" "primary" {
  project      = var.project_id
  name         = "${var.name}-primary"
  description  = "Serves the LangSmith certificate for every hostname"
  map          = google_certificate_manager_certificate_map.langsmith.name
  certificates = [google_certificate_manager_certificate.langsmith.id]
  matcher      = "PRIMARY"
  labels       = var.labels
}
