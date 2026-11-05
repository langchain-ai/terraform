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

output "lifecycle_rules" {
  description = "Lifecycle rules as planned or created: id, prefix and expiration days. Empty when s3_ttl_enabled is false."
  value = flatten([for c in aws_s3_bucket_lifecycle_configuration.ttl : [
    for r in c.rule : { id = r.id, status = r.status, prefix = one(r.filter).prefix, days = one(r.expiration).days }
  ]])
}
