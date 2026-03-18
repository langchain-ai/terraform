variable "domain_name" {
  description = "Root domain name for LangSmith (e.g. langsmith.example.com)"
  type        = string
}

variable "create_zone" {
  description = "Whether to create a new Route 53 hosted zone"
  type        = bool
  default     = true
}

variable "existing_zone_id" {
  description = "ID of an existing Route 53 hosted zone (used when create_zone = false)"
  type        = string
  default     = ""
}

variable "create_certificate" {
  description = "Whether to create and validate an ACM certificate for the domain"
  type        = bool
  default     = true
}
