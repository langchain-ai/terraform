# Workload Identity for the SmithDB pods. A dedicated service account rather
# than the shared LangSmith one: SmithDB only needs objects in its own bucket,
# and the shared account additionally carries project-wide
# roles/secretmanager.secretAccessor plus objectAdmin on the traces bucket.
#
# No HMAC keys anywhere — the chart's GCS object-store path takes no credential
# fields and authenticates purely through the pod's ambient identity.

resource "google_service_account" "smithdb" {
  count = var.service_account_email == null ? 1 : 0

  account_id   = "${var.name}-sa"
  display_name = "LangSmith SmithDB Service Account"
  project      = var.project_id

  lifecycle {
    precondition {
      condition     = length("${var.name}-sa") <= 30
      error_message = "The derived SmithDB service account ID '${var.name}-sa' exceeds the 30-character GCP limit. Shorten name_prefix or environment, or pass smithdb_service_account_email to reuse an existing account."
    }
  }
}

# Scoped to this bucket only — never a project-level storage role.
resource "google_storage_bucket_iam_member" "smithdb_object_admin" {
  bucket = google_storage_bucket.object_store.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.gsa_email}"
}

# Both member forms, matching modules/iam: the legacy serviceAccount: form and
# the principal:// form used by newer GKE Workload Identity paths.
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${local.ksa_name}]"
}

resource "google_service_account_iam_member" "workload_identity_principal" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.gsa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${local.ksa_name}"
}

data "google_project" "current" {
  project_id = var.project_id
}
