# blob_ttl_long_days_list: one rule per value in the storage account's lifecycle
# policy, for the ttl_<N>d/ prefixes LangSmith writes for custom long-lived
# retention, next to the ttl_s and ttl_l rules.

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# Both azapi lists (clusters here, storage accounts in the root) take this
# default unless a run overrides one.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [], accounts = [] }
    }
  }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "null" {}
mock_provider "time" {}

variables {
  subscription_id         = "00000000-0000-0000-0000-000000000000"
  postgres_admin_password = "fixture-not-a-real-secret-Aa1"
  name_prefix             = "test"
  unique_resource_names   = false
}

run "empty_list_keeps_the_two_default_rules" {
  command = plan

  assert {
    condition = jsonencode(module.blob.lifecycle_rules) == jsonencode([
      { base_days = 14, name = "base", prefixes = ["langsmith-blob-test-container/ttl_s"], snapshot_days = 14, version_days = 14 },
      { base_days = 400, name = "extended", prefixes = ["langsmith-blob-test-container/ttl_l"], snapshot_days = 400, version_days = 400 },
    ])
    error_message = "Unexpected rules: ${jsonencode(module.blob.lifecycle_rules)}"
  }
}

run "list_adds_one_rule_per_value" {
  command = plan

  variables {
    blob_ttl_long_days_list = [30, 90, 365]
  }

  assert {
    condition = jsonencode(module.blob.lifecycle_rules) == jsonencode([
      { base_days = 14, name = "base", prefixes = ["langsmith-blob-test-container/ttl_s"], snapshot_days = 14, version_days = 14 },
      { base_days = 400, name = "extended", prefixes = ["langsmith-blob-test-container/ttl_l"], snapshot_days = 400, version_days = 400 },
      { base_days = 30, name = "ttl30d", prefixes = ["langsmith-blob-test-container/ttl_30d/"], snapshot_days = 30, version_days = 30 },
      { base_days = 90, name = "ttl90d", prefixes = ["langsmith-blob-test-container/ttl_90d/"], snapshot_days = 90, version_days = 90 },
      { base_days = 365, name = "ttl365d", prefixes = ["langsmith-blob-test-container/ttl_365d/"], snapshot_days = 365, version_days = 365 },
    ])
    error_message = "Unexpected rules: ${jsonencode(module.blob.lifecycle_rules)}"
  }
}

# A workspace that saves the default retention stores the number, so LangSmith
# writes ttl_400d/ and not ttl_l/. Both rules must exist.
run "value_equal_to_the_long_default_gets_its_own_rule" {
  command = plan

  variables {
    blob_ttl_long_days_list = [400]
  }

  assert {
    condition     = jsonencode(module.blob.lifecycle_rules[*].prefixes) == jsonencode([["langsmith-blob-test-container/ttl_s"], ["langsmith-blob-test-container/ttl_l"], ["langsmith-blob-test-container/ttl_400d/"]])
    error_message = "Unexpected rules: ${jsonencode(module.blob.lifecycle_rules)}"
  }
}

run "ttl_disabled_drops_the_list_rules_too" {
  command = plan

  variables {
    blob_ttl_enabled        = false
    blob_ttl_long_days_list = [30]
  }

  assert {
    condition     = length(module.blob.lifecycle_rules) == 0
    error_message = "blob_ttl_enabled = false still planned a lifecycle policy"
  }
}

run "max_length_list_plans" {
  command = plan

  variables {
    blob_ttl_long_days_list = [for i in range(97) : i + 1]
  }

  assert {
    condition     = length(module.blob.lifecycle_rules) == 99
    error_message = "Expected 99 rules"
  }
}

run "duplicates_are_rejected" {
  command = plan

  variables {
    blob_ttl_long_days_list = [30, 90, 30]
  }

  expect_failures = [var.blob_ttl_long_days_list]
}

run "fractional_and_zero_days_are_rejected" {
  command = plan

  variables {
    blob_ttl_long_days_list = [0, 30.5]
  }

  expect_failures = [var.blob_ttl_long_days_list]
}

run "more_than_97_values_are_rejected" {
  command = plan

  variables {
    blob_ttl_long_days_list = [for i in range(98) : i + 1]
  }

  expect_failures = [var.blob_ttl_long_days_list]
}
