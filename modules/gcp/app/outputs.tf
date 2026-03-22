output "langsmith_url" {
  description = "LangSmith application URL"
  value       = "${local.protocol}://${local.hostname}"
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.langsmith.name
}

output "release_status" {
  description = "Helm release status"
  value       = helm_release.langsmith.status
}

output "chart_version" {
  description = "Deployed Helm chart version"
  value       = helm_release.langsmith.version
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = local.namespace
}
