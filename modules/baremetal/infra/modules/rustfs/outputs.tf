#------------------------------------------------------------------------------
# What RustFS (S3-compatible object storage) exposes to the root module:
# the in-cluster S3 endpoint, bucket names and the access keys (sensitive).
#------------------------------------------------------------------------------

output "endpoint" {
  description = "In-cluster S3 endpoint (http, path-style)."
  value       = local.endpoint
}

output "bucket" {
  description = "Bucket created by the init Job."
  value       = var.bucket
}

output "buckets" {
  description = "Every bucket the init Jobs create."
  value       = concat([var.bucket], var.extra_buckets)
}

output "access_key" {
  description = "S3 access key."
  value       = random_password.access_key.result
  sensitive   = true
}

output "secret_key" {
  description = "S3 secret key."
  value       = random_password.secret_key.result
  sensitive   = true
}
