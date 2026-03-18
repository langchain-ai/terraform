# GCP IAM module
# Creates a GCP Service Account and Workload Identity binding for LangSmith pods.

resource "google_service_account" "langsmith" {
  account_id   = "${var.project}-langsmith"
  display_name = "LangSmith Service Account"
  project      = var.gcp_project
}

resource "google_storage_bucket_iam_member" "langsmith_gcs" {
  bucket = var.gcs_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_project_iam_member" "langsmith_secret_accessor" {
  project = var.gcp_project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.langsmith.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project}.svc.id.goog[${var.namespace}/${var.service_account_name}]"
}
