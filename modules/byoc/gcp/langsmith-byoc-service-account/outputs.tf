output "provisioner_service_account" {
  description = "Email of the provisioner service account. Share it with LangChain when creating a data plane."
  value       = google_service_account.provisioner.email
}

output "byo_iam_service_accounts" {
  description = "Emails of the data plane service accounts, keyed by account ID. Empty unless byo_iam is true."
  value       = { for name, sa in google_service_account.byo_iam : name => sa.email }
}

output "cluster_tag_value" {
  description = "Namespaced name of the tag value that marks the data plane GKE clusters. The LangSmith control plane is GKE admin only on clusters with this tag."
  value       = google_tags_tag_value.cluster.namespaced_name
}
