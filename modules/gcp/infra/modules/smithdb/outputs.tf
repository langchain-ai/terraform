output "metastore_host" {
  description = "Private IP or hostname of the SmithDB metastore Postgres instance."
  value       = local.metastore_host
}

output "metastore_port" {
  description = "Port of the SmithDB metastore Postgres instance."
  value       = local.metastore_port
}

output "metastore_database" {
  description = "Database name on the SmithDB metastore."
  value       = local.metastore_database
}

output "metastore_username" {
  description = "Master username for the SmithDB metastore."
  value       = local.metastore_username
}

output "metastore_password" {
  description = "Master password for the SmithDB metastore."
  value       = local.metastore_password
  sensitive   = true
}

output "taskdb_password" {
  description = "Password for the in-chart taskdb Postgres used by the ClickHouse-to-SmithDB migration."
  value       = random_password.taskdb.result
  sensitive   = true
}

output "metastore_instance_name" {
  description = "Cloud SQL instance name for the metastore, or null when using an external metastore."
  value       = local.create_metastore ? google_sql_database_instance.metastore[0].name : null
}

output "object_store_bucket_name" {
  description = "Name of the SmithDB object-store GCS bucket."
  value       = google_storage_bucket.object_store.name
}

output "object_store_bucket_url" {
  description = "gs:// URL of the SmithDB object-store bucket."
  value       = google_storage_bucket.object_store.url
}

output "gsa_email" {
  description = "GCP service account email for the SmithDB pods. Set as the iam.gke.io/gcp-service-account annotation on the SmithDB Kubernetes service account."
  value       = local.gsa_email
}

output "ksa_name" {
  description = "Kubernetes service account name the chart creates for SmithDB, which the Workload Identity binding is scoped to."
  value       = local.ksa_name
}
