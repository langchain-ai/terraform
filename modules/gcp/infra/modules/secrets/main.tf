# GCP Secrets module
# Stores LangSmith credentials in GCP Secret Manager.

resource "random_password" "langsmith_secret_key" {
  length  = 64
  special = false
}

resource "google_secret_manager_secret" "langsmith" {
  secret_id = "${var.project}-${var.environment}-langsmith"
  project   = var.gcp_project

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "langsmith" {
  secret = google_secret_manager_secret.langsmith.id
  secret_data = jsonencode({
    langsmith_secret_key = random_password.langsmith_secret_key.result
    postgres_password    = var.postgres_password
    redis_password       = var.redis_password
  })
}
