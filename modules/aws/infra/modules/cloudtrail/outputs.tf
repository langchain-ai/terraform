output "trail_arn" {
  description = "ARN of the CloudTrail trail"
  value       = aws_cloudtrail.this.arn
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket receiving CloudTrail logs"
  value       = aws_s3_bucket.cloudtrail.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket receiving CloudTrail logs"
  value       = aws_s3_bucket.cloudtrail.arn
}
