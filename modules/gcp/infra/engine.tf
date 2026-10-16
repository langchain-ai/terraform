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

  # The chart's fullname is the release name when it contains "langsmith", and
  # "<release>-langsmith" otherwise (the same rule as modules/smithdb). Engine's
  # service accounts are <fullname>-<engineInsightsAgent.namePrefix>-<component>,
  # and langsmith-values-engine.yaml keeps namePrefix = "standalone-insights".
  # The chart cuts each of these names to 63 characters and then removes one
  # trailing "-". A long release name reaches that limit, so do the same here.
  engine_release_fullname = trimsuffix(substr(strcontains(var.langsmith_release_name, "langsmith") ? var.langsmith_release_name : "${var.langsmith_release_name}-langsmith", 0, 63), "-")
  engine_agent_fullname   = trimsuffix(substr("${local.engine_release_fullname}-standalone-insights", 0, 63), "-")
  engine_ksas = [
    for component in ["api-server", "queue"] : trimsuffix(substr("${local.engine_agent_fullname}-${component}", 0, 63), "-")
  ]
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
