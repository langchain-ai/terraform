output "metastore_host" {
  description = "Hostname of the SmithDB metastore Postgres instance."
  value       = local.metastore_host
}

output "metastore_port" {
  description = "Port of the SmithDB metastore Postgres instance."
  value       = local.metastore_port
}

output "metastore_database" {
  description = "Database name on the SmithDB metastore."
  value       = local.metastore_database
}

output "metastore_username" {
  description = "Master username for the SmithDB metastore."
  value       = local.metastore_username
}

output "metastore_password" {
  description = "Master password for the SmithDB metastore."
  value       = local.metastore_password
  sensitive   = true
}

output "object_store_bucket_name" {
  description = "Name of the SmithDB object-store S3 bucket."
  value       = aws_s3_bucket.object_store.id
}

output "object_store_bucket_arn" {
  description = "ARN of the SmithDB object-store S3 bucket."
  value       = aws_s3_bucket.object_store.arn
}

output "irsa_role_arn" {
  description = "IAM role ARN for the SmithDB service account (IRSA)."
  value       = local.irsa_role_arn
}
