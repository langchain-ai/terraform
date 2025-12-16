# Outputs for Cloud SQL Module

output "instance_name" {
  description = "Cloud SQL instance name"
  value       = google_sql_database_instance.postgres.name
}

output "instance_connection_name" {
  description = "Cloud SQL instance connection name"
  value       = google_sql_database_instance.postgres.connection_name
}

output "private_ip" {
  description = "Cloud SQL private IP address"
  value       = google_sql_database_instance.postgres.private_ip_address
}

output "public_ip" {
  description = "Cloud SQL public IP address"
  value       = google_sql_database_instance.postgres.public_ip_address
}

output "connection_ip" {
  description = "Cloud SQL connection IP (private or public based on configuration)"
  value       = var.use_private_ip ? google_sql_database_instance.postgres.private_ip_address : google_sql_database_instance.postgres.public_ip_address
}

output "uses_private_ip" {
  description = "Whether Cloud SQL is using private IP"
  value       = var.use_private_ip
}

output "database_name" {
  description = "Database name"
  value       = google_sql_database.langsmith.name
}

output "username" {
  description = "Database username"
  value       = google_sql_user.langsmith.name
}

output "password" {
  description = "Database password"
  value       = var.password
  sensitive   = true
}
