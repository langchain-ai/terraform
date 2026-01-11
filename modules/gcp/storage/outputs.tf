# Outputs for Storage Module

output "bucket_name" {
  description = "Cloud Storage bucket name"
  value       = google_storage_bucket.langsmith_traces.name
}

output "bucket_url" {
  description = "Cloud Storage bucket URL"
  value       = google_storage_bucket.langsmith_traces.url
}

output "bucket_self_link" {
  description = "Cloud Storage bucket self link"
  value       = google_storage_bucket.langsmith_traces.self_link
}

