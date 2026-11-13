# GCP DNS module
# Provisions a Cloud DNS managed zone for LangSmith.

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

# This module used to create a classic Google-managed SSL certificate here.
# Nothing ever attached it: Envoy Gateway terminates TLS in the cluster, behind a
# passthrough load balancer that cannot use one. The GKE Gateway path now uses a
# Certificate Manager certificate (modules/certificate-manager) instead. The
# removed block drops the old certificate from state without deleting it, so a
# certificate that someone attached outside Terraform keeps working. Delete it
# with gcloud once nothing uses it:
#   gcloud compute ssl-certificates delete <name-prefix>-<environment>-langsmith
removed {
  from = google_compute_managed_ssl_certificate.langsmith

  lifecycle {
    destroy = false
  }
}
