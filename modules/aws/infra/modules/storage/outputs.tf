# Outputs for AWS Storage Module

output "bucket_arn" {
  description = "ARN of the LangSmith blob storage S3 bucket"
  value       = aws_s3_bucket.bucket.arn
}

output "bucket_name" {
  description = "Name of the LangSmith blob storage S3 bucket"
  value       = aws_s3_bucket.bucket.id
}
