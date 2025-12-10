# IAM Module - Service Accounts and Permissions

#------------------------------------------------------------------------------
# Service Account for LangSmith
#------------------------------------------------------------------------------
resource "google_service_account" "langsmith" {
  account_id   = var.service_account_id
  project      = var.project_id
  display_name = var.service_account_name
  description  = "Service account for LangSmith workloads (${var.environment})"
}

#------------------------------------------------------------------------------
# IAM Roles for Service Account
#------------------------------------------------------------------------------
resource "google_project_iam_member" "cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "redis_editor" {
  project = var.project_id
  role    = "roles/redis.editor"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

#------------------------------------------------------------------------------
# Workload Identity Binding
#------------------------------------------------------------------------------
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.langsmith.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_identity_pool}[${var.gke_namespace}/langsmith-ksa]"
}

#------------------------------------------------------------------------------
# Storage Bucket IAM
#------------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "langsmith_bucket_access" {
  bucket = var.bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.langsmith.email}"
}
