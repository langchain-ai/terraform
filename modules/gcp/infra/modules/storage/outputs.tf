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

output "lifecycle_rules" {
  description = "Lifecycle rules as planned or created: action, prefixes and age in days."
  value = [for r in google_storage_bucket.langsmith_traces.lifecycle_rule : {
    action   = one(r.action).type
    prefixes = one(r.condition).matches_prefix
    age      = one(r.condition).age
  }]
}
