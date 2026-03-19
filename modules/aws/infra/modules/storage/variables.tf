variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket"
}

variable "region" {
  type        = string
  description = "AWS region"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where your EKS cluster runs"
}

variable "langsmith_irsa_role_arn" {
  type        = string
  description = "ARN of the LangSmith IRSA role. Used to scope the S3 bucket policy to a specific principal."
  default     = null
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of a KMS CMK for S3 server-side encryption. When set, SSE-KMS is used instead of SSE-S3 (AES256)."
  default     = ""
}

variable "versioning_enabled" {
  type        = bool
  description = "Enable S3 bucket versioning. Increases storage costs as all object versions are retained."
  default     = false
}

variable "s3_ttl_enabled" {
  type        = bool
  description = "Enable lifecycle rules to automatically delete trace blobs after a set number of days."
  default     = true
}

variable "s3_ttl_short_days" {
  type        = number
  description = "Days before deleting short-lived trace blobs (ttl_s/ prefix). Default: 14."
  default     = 14
}

variable "s3_ttl_long_days" {
  type        = number
  description = "Days before deleting long-lived trace blobs (ttl_l/ prefix). Default: 400."
  default     = 400
}
