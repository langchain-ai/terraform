# A changed Secret rolls LangSmith's pods: the hash of its Secrets on every pod moves with the license
# key. The generated passwords are fixed here so that only the key differs between the two plans.

mock_provider "random" {
  override_during = plan
  mock_resource "random_password" {
    defaults = { result = "fixed-for-the-test" }
  }
}

variables {
  cloud                 = "baremetal"
  ssh_host              = "box.example.com"
  box                   = "m"
  langsmith_license_key = "lcl_first_key"
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.6.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
}

run "first_key" {
  command = plan
}

run "a_changed_license_key_rolls_the_pods" {
  command = plan
  variables {
    langsmith_license_key = "lcl_second_key"
  }
  assert {
    condition     = output.values.langsmith.values.commonPodAnnotations["langsmith-lite/secrets"] != run.first_key.values.langsmith.values.commonPodAnnotations["langsmith-lite/secrets"]
    error_message = "a new license key should change the pods' secrets hash, so helm rolls them."
  }
}
