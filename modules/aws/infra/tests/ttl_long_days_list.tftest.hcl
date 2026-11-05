# s3_ttl_long_days_list: one S3 lifecycle rule per value, for the ttl_<N>d/
# prefixes LangSmith writes for custom long-lived retention, next to the
# ttl_s/ and ttl_l/ rules.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  name_prefix         = "plantest"
  postgres_password   = "fixture-not-a-real-secret-Aa1"
  redis_auth_token    = "fixture-not-a-real-token-0123456789"
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "empty_list_keeps_the_two_default_rules" {
  command = plan

  assert {
    condition = module.storage.lifecycle_rules == [
      { id = "base", status = "Enabled", prefix = "ttl_s/", days = 14 },
      { id = "extended", status = "Enabled", prefix = "ttl_l/", days = 400 },
    ]
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

run "list_adds_one_rule_per_value" {
  command = plan

  variables {
    s3_ttl_long_days_list = [30, 90, 365]
  }

  assert {
    condition = module.storage.lifecycle_rules == [
      { id = "base", status = "Enabled", prefix = "ttl_s/", days = 14 },
      { id = "extended", status = "Enabled", prefix = "ttl_l/", days = 400 },
      { id = "ttl_30d", status = "Enabled", prefix = "ttl_30d/", days = 30 },
      { id = "ttl_90d", status = "Enabled", prefix = "ttl_90d/", days = 90 },
      { id = "ttl_365d", status = "Enabled", prefix = "ttl_365d/", days = 365 },
    ]
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

# A workspace that saves the default retention stores the number, so LangSmith
# writes ttl_400d/ and not ttl_l/. Both rules must exist.
run "value_equal_to_the_long_default_gets_its_own_rule" {
  command = plan

  variables {
    s3_ttl_long_days_list = [400]
  }

  assert {
    condition     = module.storage.lifecycle_rules[*].prefix == ["ttl_s/", "ttl_l/", "ttl_400d/"]
    error_message = "Unexpected rules: ${jsonencode(module.storage.lifecycle_rules)}"
  }
}

run "ttl_disabled_drops_the_list_rules_too" {
  command = plan

  variables {
    s3_ttl_enabled        = false
    s3_ttl_long_days_list = [30]
  }

  assert {
    condition     = module.storage.lifecycle_rules == []
    error_message = "s3_ttl_enabled = false still planned a lifecycle configuration"
  }
}

run "max_length_list_plans" {
  command = plan

  variables {
    s3_ttl_long_days_list = [for i in range(97) : i + 1]
  }

  assert {
    condition     = length(module.storage.lifecycle_rules) == 99
    error_message = "Expected 99 rules"
  }
}

run "duplicates_are_rejected" {
  command = plan

  variables {
    s3_ttl_long_days_list = [30, 90, 30]
  }

  expect_failures = [var.s3_ttl_long_days_list]
}

run "fractional_and_zero_days_are_rejected" {
  command = plan

  variables {
    s3_ttl_long_days_list = [0, 30.5]
  }

  expect_failures = [var.s3_ttl_long_days_list]
}

run "more_than_97_values_are_rejected" {
  command = plan

  variables {
    s3_ttl_long_days_list = [for i in range(98) : i + 1]
  }

  expect_failures = [var.s3_ttl_long_days_list]
}
