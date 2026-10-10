output "provisioner_service_account" {
  description = "Email of the provisioner service account. Share it with LangChain when creating a data plane."
  value       = google_service_account.provisioner.email
}
