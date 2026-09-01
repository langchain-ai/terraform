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

# The historical backfill is the one SmithDB workload that reads outside its own
# bucket: it pulls the run inputs, outputs and errors that LangSmith offloaded to
# the traces bucket, then rewrites them into .vortex segments. Without this grant
# the Job starts, plans its tasks, and then fails every task on a 403 from the
# traces bucket - and because the failures are recorded as non-retryable in the
# taskdb, progress simply stops at 0% with the Job still reporting Running.
#
# objectViewer, not objectAdmin: the backfill only reads that bucket. It writes
# exclusively to the SmithDB bucket above.
#
# Only created with the migration gate, so the steady-state install keeps a
# service account that can reach nothing but its own bucket.
#
# Gated on migration_enabled alone. The root module passes traces_bucket_name
# from module.storage, so once the traces bucket leaves state that value is
# unknown at plan time - and a count that compares it to "" is then unplannable,
# which fails destroy with "Invalid count argument". The precondition below
# carries the empty-name case instead, so an apply still cannot produce a
# binding against an invalid bucket.
resource "google_storage_bucket_iam_member" "smithdb_traces_object_viewer" {
  count = var.migration_enabled ? 1 : 0

  bucket = var.traces_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.gsa_email}"

  lifecycle {
    precondition {
      condition     = !var.migration_enabled || var.traces_bucket_name != ""
      error_message = "smithdb_migration_enabled is true but no traces bucket name reached the SmithDB module, so the backfill would fail every task on a 403 reading run payloads. This is wired by the root module; if you call modules/smithdb directly, pass traces_bucket_name."
    }
  }
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

# The Cloud SQL Auth Proxy authenticates to the Cloud SQL Admin API as the pod's
# Workload Identity principal, so the proxy path needs this role on top of the
# bucket grant above. Cloud SQL has no per-instance IAM binding - roles/cloudsql
# .client is only grantable at the project level - so this is the tightest
# scope available. It confers connection rights, not data access: the database
# password in the smithdb-metastore secret is still what authenticates the
# session.
resource "google_project_iam_member" "smithdb_cloudsql_client" {
  count = var.metastore_use_auth_proxy ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${local.gsa_email}"
}
