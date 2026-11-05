# storage_ttl_long_days_list: one GCS lifecycle rule per value, for the
# ttl_<N>d/ prefixes LangSmith writes for custom long-lived retention, next to
# the ttl_s/ and ttl_l/ rules.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}


variables {
  project_id = "langsmith-plan-tests"
  # postgres_source defaults to external, and both the root precondition and
  # the postgres module's own length validation require a value.
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# master_auth is a computed nested block, and a mock provider returns computed
# blocks as an empty list rather than as unknown. modules/k8s-cluster/outputs.tf
# indexes master_auth[0], so without this override every run fails on that index
# instead of on what it asserts. The cost is that the cluster module itself is
# not planned here, so its autopilot conditional needs its own test once that
# output stops hard-indexing.
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

# random_id.suffix.hex is unknown at plan time with a mock provider. The SmithDB
# network-disk StorageClass name carries the suffix, so fix it to keep
# smithdb_helm_values known.
override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "a1b2c3d4"
  }
}

run "empty_list_keeps_the_default_rules" {
  command = plan

  assert {
    condition = jsonencode(module.storage.lifecycle_rules) == jsonencode([
      { action = "Delete", prefixes = ["ttl_s/"], age = 14 },
      { action = "Delete", prefixes = ["ttl_l/"], age = 400 },
      { action = "AbortIncompleteMultipartUpload", prefixes = null, age = 7 },
    ])
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

run "list_adds_one_rule_per_value" {
  command = plan

  variables {
    storage_ttl_long_days_list = [30, 90, 365]
  }

  assert {
    condition = jsonencode(module.storage.lifecycle_rules) == jsonencode([
      { action = "Delete", prefixes = ["ttl_s/"], age = 14 },
      { action = "Delete", prefixes = ["ttl_l/"], age = 400 },
      { action = "AbortIncompleteMultipartUpload", prefixes = null, age = 7 },
      { action = "Delete", prefixes = ["ttl_30d/"], age = 30 },
      { action = "Delete", prefixes = ["ttl_90d/"], age = 90 },
      { action = "Delete", prefixes = ["ttl_365d/"], age = 365 },
    ])
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

# A workspace that saves the default retention stores the number, so LangSmith
# writes ttl_400d/ and not ttl_l/. Both rules must exist.
run "value_equal_to_the_long_default_gets_its_own_rule" {
  command = plan

  variables {
    storage_ttl_long_days_list = [400]
  }

  assert {
    condition     = jsonencode([for r in module.storage.lifecycle_rules : r.prefixes if r.action == "Delete"]) == jsonencode([["ttl_s/"], ["ttl_l/"], ["ttl_400d/"]])
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

run "max_length_list_plans" {
  command = plan

  variables {
    storage_ttl_long_days_list = [for i in range(97) : i + 1]
  }

  assert {
    condition     = length(module.storage.lifecycle_rules) == 100
    error_message = "Expected 100 rules"
  }
}

run "duplicates_are_rejected" {
  command = plan

  variables {
    storage_ttl_long_days_list = [30, 90, 30]
  }

  expect_failures = [var.storage_ttl_long_days_list]
}

run "fractional_and_zero_days_are_rejected" {
  command = plan

  variables {
    storage_ttl_long_days_list = [0, 30.5]
  }

  expect_failures = [var.storage_ttl_long_days_list]
}

run "more_than_97_values_are_rejected" {
  command = plan

  variables {
    storage_ttl_long_days_list = [for i in range(98) : i + 1]
  }

  expect_failures = [var.storage_ttl_long_days_list]
}
