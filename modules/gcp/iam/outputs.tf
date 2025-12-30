# Outputs for IAM Module

output "service_account_email" {
  description = "Service account email"
  value       = google_service_account.langsmith.email
}

output "service_account_name" {
  description = "Service account name"
  value       = google_service_account.langsmith.name
}

output "service_account_id" {
  description = "Service account ID"
  value       = google_service_account.langsmith.id
}

