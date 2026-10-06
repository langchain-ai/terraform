# GCP IAM module
# Creates a GCP Service Account and Workload Identity binding for LangSmith pods.

resource "google_service_account" "langsmith" {
  account_id   = "${var.project}-langsmith"
  display_name = "LangSmith Service Account"
  project      = var.gcp_project
}

locals {
  # Keep backward compatibility with legacy single-SA input while allowing
  # chart components to run under separate service accounts.
  workload_identity_ksa_names = distinct(concat(
    var.workload_identity_service_accounts,
    [var.service_account_name]
  ))
}

data "google_project" "current" {
  project_id = var.gcp_project
}

resource "google_storage_bucket_iam_member" "langsmith_gcs" {
  bucket = var.gcs_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.langsmith.email}"
}

# No module component reads Secret Manager at runtime. The scripts read it with
# the operator's credentials. The grant covers every secret in the project, so it
# is opt-in, for a workload that an operator adds.
resource "google_project_iam_member" "langsmith_secret_accessor" {
  count = var.grant_project_secret_accessor ? 1 : 0

  project = var.gcp_project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.langsmith.email}"
}

# With the grant on, keep the existing binding instead of a destroy and a create.
moved {
  from = google_project_iam_member.langsmith_secret_accessor
  to   = google_project_iam_member.langsmith_secret_accessor[0]
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = toset(local.workload_identity_ksa_names)

  service_account_id = google_service_account.langsmith.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project}.svc.id.goog[${var.namespace}/${each.value}]"
}

resource "google_service_account_iam_member" "workload_identity_principal" {
  for_each = toset(local.workload_identity_ksa_names)

  service_account_id = google_service_account.langsmith.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.gcp_project}.svc.id.goog/subject/ns/${var.namespace}/sa/${each.value}"
}
