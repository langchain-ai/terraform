#------------------------------------------------------------------------------
# What one Postgres instance exposes to the root module:
# connection details for the root module to build Secrets: host, port,
# database, username, password (sensitive), namespace, extra databases.
#------------------------------------------------------------------------------

output "host" {
  description = "In-cluster DNS name of the instance."
  value       = "${kubernetes_service_v1.this.metadata[0].name}.${kubernetes_namespace_v1.this.metadata[0].name}.svc.cluster.local"
}

output "port" {
  description = "Postgres port."
  value       = 5432
}

output "database" {
  description = "Database name."
  value       = var.database
}

output "username" {
  description = "Owner role."
  value       = var.username
}

output "password" {
  description = "Generated password."
  value       = random_password.this.result
  sensitive   = true
}

output "namespace" {
  description = "Instance namespace."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "extra_databases" {
  description = "Extra databases ensured on this instance."
  value       = local.extra_databases_sorted
}
