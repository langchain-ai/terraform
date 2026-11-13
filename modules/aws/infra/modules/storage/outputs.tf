# Outputs for AWS Storage Module

output "bucket_arn" {
  description = "ARN of the LangSmith blob storage S3 bucket"
  value       = aws_s3_bucket.bucket.arn
}

output "bucket_name" {
  description = "Name of the LangSmith blob storage S3 bucket"
  value       = aws_s3_bucket.bucket.id
}

output "s3_vpc_endpoint_id" {
  description = "ID of the S3 Gateway VPC endpoint used by private subnets"
  value       = aws_vpc_endpoint.s3.id
}

output "lifecycle_rule_ids" {
  description = "IDs of the bucket lifecycle rules in force."
  value       = [for r in aws_s3_bucket_lifecycle_configuration.ttl.rule : r.id]
}
