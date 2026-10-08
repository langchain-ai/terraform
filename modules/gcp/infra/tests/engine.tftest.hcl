# LangSmith Engine in the GCP root: the shared Insights database and Secrets, the
# Vertex AI identity, and the input checks. mock_provider means no cloud
# credentials, state, or API calls.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id        = "langsmith-plan-tests"
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# See tests/wiring.tftest.hcl for why the cluster module is overridden.
override_module {
  target = module.gke_cluster
  outputs = {
    cluster_name   = "langsmith-plan-tests-gke"
    cluster_id     = "projects/langsmith-plan-tests/locations/us-central1/clusters/langsmith-plan-tests-gke"
    endpoint       = "10.0.0.1"
    ca_certificate = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
    location       = "us-central1"
  }
}

run "engine_off_by_default" {
  command = plan

  assert {
    condition = (
      length(google_service_account.engine) == 0 &&
      length(google_project_service.engine_vertex) == 0 &&
      length(google_sql_database.insights) == 0 &&
      length(kubernetes_secret.standalone_insights_postgres) == 0 &&
      output.engine_service_account_email == ""
    )
    error_message = "Engine and the Insights stores must not be planned by default"
  }
}

# Engine runs on the deployment it shares with standalone Insights, so it needs
# that deployment's database and Secrets even with enable_standalone_insights off.
run "engine_creates_the_shared_insights_stores" {
  command = plan

  variables {
    enable_sandboxes = true
    enable_engine    = true
  }

  assert {
    condition = (
      length(google_sql_database.insights) == 1 &&
      length(kubernetes_secret.standalone_insights_postgres) == 1 &&
      length(kubernetes_secret.standalone_insights_redis) == 1
    )
    error_message = "enable_engine should create the Insights database and both Secrets"
  }
  assert {
    condition     = length(google_service_account.engine) == 0 && length(google_project_service.engine_vertex) == 0
    error_message = "Engine without Vertex AI (provider API keys) needs no Google service account or Vertex AI API"
  }
}

run "engine_vertex_identity_binds_both_engine_service_accounts" {
  command = plan

  variables {
    name_prefix                     = "acme"
    environment                     = "dev"
    enable_sandboxes                = true
    enable_engine                   = true
    engine_vertex_workload_identity = true
  }

  assert {
    condition     = google_service_account.engine[0].account_id == "acme-dev-engine"
    error_message = "The Engine service account should be <name_prefix>-<environment>-engine"
  }
  assert {
    condition     = google_project_iam_member.engine_vertex_user[0].role == "roles/aiplatform.user"
    error_message = "The Engine service account should get roles/aiplatform.user for Vertex AI inference"
  }
  assert {
    condition     = google_project_service.engine_vertex[0].service == "aiplatform.googleapis.com" && !google_project_service.engine_vertex[0].disable_on_destroy
    error_message = "Vertex AI should be enabled for Engine and stay enabled on destroy"
  }
  assert {
    condition = (
      toset(keys(google_service_account_iam_member.engine_workload_identity)) == toset(["langsmith-standalone-insights-api-server", "langsmith-standalone-insights-queue"]) &&
      google_service_account_iam_member.engine_workload_identity["langsmith-standalone-insights-queue"].member == "serviceAccount:langsmith-plan-tests.svc.id.goog[langsmith/langsmith-standalone-insights-queue]"
    )
    error_message = "Workload Identity should bind Engine's API server and queue service accounts in the LangSmith namespace"
  }
}

run "engine_requires_sandboxes" {
  command = plan

  variables {
    enable_sandboxes = false
    enable_engine    = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "engine_inputs_reject_malformed_values" {
  command = plan

  variables {
    engine_sandbox_tenant_id              = "Workspace 2"
    engine_intelligence_base_url          = "http://beacon.example.com/intelligence"
    langsmith_engine_usage_signing_secret = "too-short"
  }

  expect_failures = [
    var.engine_sandbox_tenant_id,
    var.engine_intelligence_base_url,
    var.langsmith_engine_usage_signing_secret,
  ]
}
