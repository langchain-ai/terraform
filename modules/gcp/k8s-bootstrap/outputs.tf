# Outputs for K8s Bootstrap Module

output "namespace" {
  description = "LangSmith namespace"
  value       = kubernetes_namespace.langsmith.metadata[0].name
}

output "service_account_name" {
  description = "Kubernetes service account name"
  value       = kubernetes_service_account.langsmith.metadata[0].name
}

output "postgres_secret_name" {
  description = "PostgreSQL credentials secret name"
  value       = kubernetes_secret.postgres_credentials.metadata[0].name
}

output "redis_secret_name" {
  description = "Redis credentials secret name (null if using in-cluster Redis)"
  value       = var.use_managed_redis ? kubernetes_secret.redis_credentials[0].metadata[0].name : null
}

output "use_managed_redis" {
  description = "Whether using managed Redis (Memorystore)"
  value       = var.use_managed_redis
}

output "keda_installed" {
  description = "Whether KEDA is installed (required for LangSmith Deployment)"
  value       = var.install_keda
}

output "keda_namespace" {
  description = "Namespace where KEDA is installed"
  value       = var.install_keda ? "keda" : null
}

output "cert_manager_installed" {
  description = "Whether cert-manager is installed for TLS"
  value       = var.install_cert_manager
}

output "cert_manager_namespace" {
  description = "Namespace where cert-manager is installed"
  value       = var.install_cert_manager ? "cert-manager" : null
}

output "letsencrypt_issuer_name" {
  description = "Name of the Let's Encrypt ClusterIssuer"
  value       = var.install_cert_manager && var.letsencrypt_email != "" ? "letsencrypt-prod" : null
}

output "tls_certificate_source" {
  description = "TLS certificate source: none, letsencrypt, or existing"
  value       = var.tls_certificate_source
}

output "tls_secret_name" {
  description = "Name of the TLS secret in Kubernetes"
  value       = var.tls_certificate_source == "existing" ? var.tls_secret_name : (var.tls_certificate_source == "letsencrypt" ? var.tls_secret_name : null)
}

output "tls_configured" {
  description = "Whether TLS is configured"
  value       = var.tls_certificate_source != "none"
}

#------------------------------------------------------------------------------
# ClickHouse Outputs
#------------------------------------------------------------------------------
output "clickhouse_source" {
  description = "ClickHouse deployment type"
  value       = var.clickhouse_source
}

output "clickhouse_secret_name" {
  description = "ClickHouse credentials secret name (null if in-cluster)"
  value       = var.clickhouse_source != "in-cluster" && var.clickhouse_host != "" ? "langsmith-clickhouse-credentials" : null
}

output "clickhouse_ca_secret_name" {
  description = "ClickHouse CA certificate secret name (null if not configured)"
  value       = var.clickhouse_source != "in-cluster" && var.clickhouse_ca_cert != "" ? "langsmith-clickhouse-ca" : null
}

output "uses_external_clickhouse" {
  description = "Whether using external ClickHouse (managed or self-hosted)"
  value       = var.clickhouse_source != "in-cluster"
}
