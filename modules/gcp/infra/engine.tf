# LangSmith Engine (enable_engine). Engine runs on the deployment it shares with
# standalone Insights and reuses that deployment's Cloud SQL database, Secrets, and
# Memorystore DB (main.tf). init-values.sh writes Engine's Helm values. See ENGINE.md.
#
# With engine_vertex_workload_identity, Engine runs its models on Vertex AI under a
# dedicated Google service account, bound through Workload Identity to Engine's API
# server and queue. It is dedicated rather than the shared LangSmith account: only
# those two workloads need Vertex AI, and the shared account reaches Cloud SQL and
# the traces bucket.
locals {
  engine_vertex_enabled = var.enable_engine && var.engine_vertex_workload_identity

  # The chart's service account names for Engine's API server and queue under the
  # "langsmith" release, with engineInsightsAgent.namePrefix = standalone-insights.
  engine_ksas = ["langsmith-standalone-insights-api-server", "langsmith-standalone-insights-queue"]
}

resource "google_project_service" "engine_vertex" {
  count = local.engine_vertex_enabled ? 1 : 0

  project            = var.project_id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "engine" {
  count = local.engine_vertex_enabled ? 1 : 0

  account_id   = "${local.base_name}-engine"
  display_name = "LangSmith Engine (Vertex AI)"
  project      = var.project_id
}

resource "google_project_iam_member" "engine_vertex_user" {
  count = local.engine_vertex_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.engine[0].email}"
}

resource "google_service_account_iam_member" "engine_workload_identity" {
  for_each = local.engine_vertex_enabled ? toset(local.engine_ksas) : toset([])

  service_account_id = google_service_account.engine[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.langsmith_namespace}/${each.value}]"
}
