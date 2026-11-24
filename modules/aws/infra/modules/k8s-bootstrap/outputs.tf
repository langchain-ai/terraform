output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = kubernetes_namespace.langsmith.metadata[0].name
}

output "keda_release_name" {
  description = "Name of the KEDA Helm release. Plan tests assert on this because test assertions cannot reach resources inside nested modules."
  value       = helm_release.keda.name
}
