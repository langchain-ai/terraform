variable "trail_name" {
  type        = string
  description = "Name for the CloudTrail trail"
}

variable "bucket_name" {
  type        = string
  description = "Name for the S3 bucket that receives CloudTrail logs"
}

variable "is_multi_region_trail" {
  type        = bool
  description = "Record API calls across all regions (recommended). Single-region trails miss global service events from other regions."
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "Days to retain CloudTrail logs in S3. Set 0 to disable expiry (keep indefinitely)."
  default     = 365
}

variable "force_destroy" {
  type        = bool
  description = "Allow terraform destroy to delete the CloudTrail S3 bucket even when it contains audit logs."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources"
  default     = {}
}
