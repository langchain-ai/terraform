variable "domain_name" {
  description = "Root domain name for LangSmith (e.g. langsmith.example.com)"
  type        = string
}

variable "create_zone" {
  description = "Whether to create a new public Route 53 hosted zone exactly matching domain_name"
  type        = bool
  default     = true
}

variable "existing_zone_id" {
  description = "ID of an existing public Route 53 hosted zone for domain_name or one of its parent domains (used when create_zone = false)"
  type        = string
  default     = ""
}

variable "create_certificate" {
  description = "Whether to create an ACM certificate and DNS validation records for the domain"
  type        = bool
  default     = true
}

variable "wait_for_validation" {
  description = "Whether to block until ACM certificate validation completes. Set false to create the cert and validation records without waiting (useful for staged deploys where NS delegation hasn't happened yet)."
  type        = bool
  default     = true
}

variable "include_wildcard_san" {
  description = "Whether to include a wildcard SAN (*.<domain_name>) on the ACM certificate. Required if you want to serve subdomains (e.g. mission-control.langsmith.example.com) with HTTPS via the same cert."
  type        = bool
  default     = false
}
