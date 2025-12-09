output "connection_url" {
  value     = "postgres://${aws_db_instance.this.username}:${aws_db_instance.this.password}@${aws_db_instance.this.endpoint}/${aws_db_instance.this.db_name}"
  sensitive = true
}

output "iam_connection_url" {
  description = "Connection URL for IAM authentication (no password). Use as POSTGRES_IAM_CONNECTION_URI"
  value       = var.iam_database_user != null ? "postgresql://${var.iam_database_user}@${aws_db_instance.this.endpoint}/${aws_db_instance.this.db_name}" : null
}
