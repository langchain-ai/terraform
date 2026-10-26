# IAM grants that a plan can check. A root plan cannot read the attributes of a
# resource inside a child module, so each run plans modules/iam on its own.
# mock_provider means no cloud credentials, no state, and no API calls.

mock_provider "google" {}

# ── Project-wide Secret Manager access (modules/iam) ─────────────────────────

run "project_secret_accessor_is_off_by_default" {
  command = plan

  module {
    source = "./modules/iam"
  }

  variables {
    gcp_project     = "langsmith-plan-tests"
    project         = "langsmith-plan-tests"
    environment     = "dev"
    gcs_bucket_name = "langsmith-plan-tests-traces"
  }

  assert {
    condition     = length(google_project_iam_member.langsmith_secret_accessor) == 0
    error_message = "The LangSmith service account gets project-wide Secret Manager access by default"
  }
}

run "project_secret_accessor_is_opt_in" {
  command = plan

  module {
    source = "./modules/iam"
  }

  variables {
    gcp_project                   = "langsmith-plan-tests"
    project                       = "langsmith-plan-tests"
    environment                   = "dev"
    gcs_bucket_name               = "langsmith-plan-tests-traces"
    grant_project_secret_accessor = true
  }

  assert {
    condition = (
      length(google_project_iam_member.langsmith_secret_accessor) == 1
      && google_project_iam_member.langsmith_secret_accessor[0].role == "roles/secretmanager.secretAccessor"
    )
    error_message = "grant_project_secret_accessor = true does not plan the project-wide secretAccessor grant"
  }
}
