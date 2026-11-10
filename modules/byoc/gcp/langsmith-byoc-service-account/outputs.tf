output "provisioner_service_account" {
  description = "Email of the provisioner service account. Share it with LangChain when creating a data plane."
  value       = google_service_account.provisioner.email
}

output "byo_iam_service_accounts" {
  description = "Emails of the data plane service accounts, keyed by account ID. Empty unless byo_iam is true."
  value       = { for name, sa in google_service_account.byo_iam : name => sa.email }
}

output "cluster_tag_value" {
  description = "Namespaced name of the tag value on the data plane GKE clusters (<project>/managed_by/langsmith). The LangSmith control plane is GKE admin only on clusters with it."
  value       = local.cluster_tag_value.namespaced_name
}

output "cluster_tag_key" {
  description = "ID of the project's managed_by tag key. Internal to LangChain: passed as cluster_tag_key to another copy of this module in a test project."
  value       = local.cluster_tag_value.parent
}
