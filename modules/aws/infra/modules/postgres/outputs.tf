output "connection_url" {
  value     = "postgres://${aws_db_instance.this.username}:${coalesce(aws_db_instance.this.password, "IMPORTED")}@${aws_db_instance.this.endpoint}/${aws_db_instance.this.db_name}"
  sensitive = true
}

output "iam_connection_url" {
  description = "Connection URL for IAM authentication (no password). Use as POSTGRES_IAM_CONNECTION_URI"
  value       = var.iam_database_user != null ? "postgresql://${var.iam_database_user}@${aws_db_instance.this.endpoint}/${aws_db_instance.this.db_name}" : null
}

output "address" {
  description = "RDS instance hostname (no port). Used to build per-feature connection URLs for standalone agent features."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "RDS instance port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the default (admin) database created on the instance."
  value       = aws_db_instance.this.db_name
}
