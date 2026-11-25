# langsmith_custom_ca_secret_name / langsmith_custom_ca_secret_key: the CA bundle
# Secret for endpoints a private CA signed. The scripts read both values from
# terraform.tfvars; Terraform only validates them, so a typo fails at plan time
# instead of at deploy. Checked on and off, and with values Kubernetes would refuse.
# mock_provider means no cloud credentials, no state, and no API calls.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  name_prefix       = "plantest"
  postgres_password = "fixture-not-a-real-secret-Aa1"
  redis_auth_token  = "fixture-not-a-real-token-0123456789"

  # tls_certificate_source defaults to acm, which requires a certificate ARN or a domain.
  acm_certificate_arn = "arn:aws:acm:us-east-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "custom_ca_is_off_by_default" {
  command = plan

  assert {
    condition     = var.langsmith_custom_ca_secret_name == ""
    error_message = "No custom CA Secret should be set by default"
  }

  assert {
    condition     = var.langsmith_custom_ca_secret_key == "ca.crt"
    error_message = "The custom CA key should default to ca.crt"
  }
}

run "custom_ca_secret_and_key_are_accepted" {
  command = plan

  variables {
    langsmith_custom_ca_secret_name = "langsmith-ca"
    langsmith_custom_ca_secret_key  = "bundle.pem"
  }

  assert {
    condition     = var.langsmith_custom_ca_secret_name == "langsmith-ca" && var.langsmith_custom_ca_secret_key == "bundle.pem"
    error_message = "A valid custom CA Secret name and key should plan"
  }
}

run "custom_ca_secret_name_must_be_a_kubernetes_name" {
  command = plan

  variables {
    langsmith_custom_ca_secret_name = "Corp_CA"
  }

  expect_failures = [var.langsmith_custom_ca_secret_name]
}

run "custom_ca_key_must_be_a_secret_key" {
  command = plan

  variables {
    langsmith_custom_ca_secret_name = "langsmith-ca"
    langsmith_custom_ca_secret_key  = "ca bundle.pem"
  }

  expect_failures = [var.langsmith_custom_ca_secret_key]
}
