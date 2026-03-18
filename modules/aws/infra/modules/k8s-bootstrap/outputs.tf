output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = kubernetes_namespace.langsmith.metadata[0].name
}
