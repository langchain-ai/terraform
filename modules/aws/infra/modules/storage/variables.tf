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

variable "create_vpc_endpoint" {
  type        = bool
  description = "Create the S3 gateway endpoint on every route table in the VPC. False uses existing_vpc_endpoint_id."
  default     = true
}

variable "existing_vpc_endpoint_id" {
  type        = string
  description = "The VPC's existing S3 endpoint, admitted by the bucket policy when create_vpc_endpoint = false"
  default     = ""
}

variable "langsmith_irsa_role_arn" {
  type        = string
  description = "ARN of the LangSmith IRSA role. Used to scope the S3 bucket policy to a specific principal."
  default     = null
}

variable "create_bucket_policy" {
  type        = bool
  description = "Whether to create the S3 bucket policy. Use this instead of checking langsmith_irsa_role_arn for count, since the ARN is not known until apply."
  default     = false
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
