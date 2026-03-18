output "secret_id" {
  description = "Full resource name of the Secret Manager secret"
  value       = google_secret_manager_secret.langsmith.id
}

output "secret_name" {
  description = "Short name of the Secret Manager secret"
  value       = google_secret_manager_secret.langsmith.secret_id
}
