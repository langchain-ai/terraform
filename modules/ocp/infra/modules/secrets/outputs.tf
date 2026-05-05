output "secret_name" {
  description = "Name of the Kubernetes secret"
  value       = kubernetes_secret.langsmith.metadata[0].name
}
