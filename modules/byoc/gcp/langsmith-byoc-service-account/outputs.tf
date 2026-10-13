output "provisioner_service_account" {
  description = "Email of the provisioner service account. Share it with LangChain when creating a data plane."
  value       = google_service_account.provisioner.email
}

output "byo_iam_service_accounts" {
  description = "Emails of the data plane service accounts, keyed by account ID. Empty unless byo_iam is true."
  value       = { for name, sa in google_service_account.byo_iam : name => sa.email }
}
