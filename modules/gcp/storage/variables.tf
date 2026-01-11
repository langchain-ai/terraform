# Variables for Storage Module

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

#------------------------------------------------------------------------------
# Resource Names
#------------------------------------------------------------------------------
variable "bucket_name" {
  description = "Cloud Storage bucket name"
  type        = string
}

#------------------------------------------------------------------------------
# Bucket Configuration
#------------------------------------------------------------------------------
variable "ttl_short_days" {
  description = "Short term TTL in days (for ttl_s/ prefix, default: 14 days per LangSmith docs)"
  type        = number
  default     = 14
}

variable "ttl_long_days" {
  description = "Long term TTL in days (for ttl_l/ prefix, default: 400 days per LangSmith docs)"
  type        = number
  default     = 400
}

variable "force_destroy" {
  description = "Allow bucket deletion even with objects"
  type        = bool
  default     = false
}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
