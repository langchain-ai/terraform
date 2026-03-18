output "service_account_email" {
  description = "Email of the GCP service account for LangSmith"
  value       = google_service_account.langsmith.email
}

output "workload_identity_annotation" {
  description = "Value for the iam.gke.io/gcp-service-account annotation on the Kubernetes service account"
  value       = google_service_account.langsmith.email
}
