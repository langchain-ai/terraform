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
variable "retention_days" {
  description = "Number of days to retain objects (0 = no deletion)"
  type        = number
  default     = 90
}

variable "force_destroy" {
  description = "Allow bucket deletion even with objects"
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Service account email for bucket access"
  type        = string
  default     = ""
}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
variable "labels" {
  description = "Labels to apply to resources"
  type        = map(string)
  default     = {}
}
