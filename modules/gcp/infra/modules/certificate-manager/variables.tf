# Variables for Certificate Manager Module

variable "project_id" {
  description = "GCP project ID that holds the certificate, its map, and the DNS authorization."
  type        = string
}

variable "name" {
  description = "Base name for the certificate. The map, map entry, and DNS authorization add a suffix to it."
  type        = string
}

variable "domain" {
  description = "Domain the certificate covers. Must be the domain the Gateway listener serves (langsmith_domain)."
  type        = string

  validation {
    condition     = var.domain != ""
    error_message = "A Google-managed certificate needs a domain. Set langsmith_domain."
  }
}

variable "include_wildcard" {
  description = "Also cover *.<domain>. The DNS authorization for the domain covers its wildcard, so no extra record is needed."
  type        = bool
  default     = false
}

variable "issuance_config" {
  description = "Certificate Manager issuance config ID, to issue from a Certificate Authority Service pool instead of a public CA. Empty uses a public Google-managed certificate with a DNS authorization."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Cloud DNS managed zone for the DNS authorization CNAME record. Empty creates no record: add it from the dns_authorization_record output."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels for the Certificate Manager resources."
  type        = map(string)
  default     = {}
}
