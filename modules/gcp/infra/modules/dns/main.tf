# GCP DNS module
# Provisions a Cloud DNS managed zone and Google-managed SSL certificate for LangSmith.

resource "google_dns_managed_zone" "langsmith" {
  count       = var.create_zone ? 1 : 0
  name        = "${var.project}-${var.environment}-langsmith"
  dns_name    = "${var.domain_name}."
  description = "LangSmith managed zone"
  project     = var.gcp_project
}

locals {
  zone_name = var.create_zone ? google_dns_managed_zone.langsmith[0].name : var.existing_zone_name
}

resource "google_compute_managed_ssl_certificate" "langsmith" {
  count   = var.create_certificate ? 1 : 0
  name    = "${var.project}-${var.environment}-langsmith"
  project = var.gcp_project

  managed {
    domains = [var.domain_name, "*.${var.domain_name}"]
  }
}
