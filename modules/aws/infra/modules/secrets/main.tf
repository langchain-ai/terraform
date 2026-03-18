# AWS Secrets module
# Stores LangSmith credentials in AWS Secrets Manager.

resource "random_password" "langsmith_secret_key" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "langsmith" {
  name                    = "${var.project}-${var.environment}-langsmith"
  description             = "LangSmith application credentials"
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "langsmith" {
  secret_id = aws_secretsmanager_secret.langsmith.id
  secret_string = jsonencode({
    langsmith_secret_key = random_password.langsmith_secret_key.result
    postgres_password    = var.postgres_password
    redis_auth_token     = var.redis_auth_token
  })
}
