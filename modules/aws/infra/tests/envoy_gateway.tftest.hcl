# Envoy Gateway install in the k8s-bootstrap module, asserted in both directions:
# the chart is pinned to v1.9.2, the chart skips its own CRDs, and the two CRD
# steps (Gateway API, then Envoy Gateway) carry the URLs that make them run again
# when a version changes. The run swaps in the child module, so the resources are
# reachable. mock_provider means no cloud credentials, no state, and no API calls.

mock_provider "aws" {
  source = "./tests/mocks/aws"
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  postgres_connection_url = "postgresql://fixture:fixture@db.example.internal:5432/langsmith"
  redis_connection_url    = "redis://fixture@cache.example.internal:6379"
  eso_irsa_role_arn       = "arn:aws:iam::123456789012:role/fixture-eso"
}

run "envoy_gateway_is_pinned_and_applies_its_crds" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    enable_envoy_gateway = true
  }

  assert {
    condition     = helm_release.envoy_gateway[0].version == "v1.9.2"
    error_message = "The Envoy Gateway chart is not pinned to v1.9.2"
  }

  # Helm does not upgrade CRDs, so the module applies them and the chart skips its copy.
  assert {
    condition     = anytrue([for s in helm_release.envoy_gateway[0].set : s.name == "crds.enabled" && s.value == "false"])
    error_message = "The Envoy Gateway chart installs its own CRDs"
  }

  assert {
    condition     = anytrue([for s in helm_release.envoy_gateway[0].set : s.name == "topologyInjector.enabled" && s.value == "false"])
    error_message = "The Envoy Gateway chart installs the topology injector"
  }

  # The URL triggers run the CRD steps again on an existing cluster after a version change.
  assert {
    condition     = strcontains(terraform_data.gateway_api_crds[0].triggers_replace[0], "/v1.6.1/standard-install.yaml")
    error_message = "The Gateway API CRD step does not pin v1.6.1"
  }

  assert {
    condition     = strcontains(terraform_data.envoy_gateway_crds[0].triggers_replace[0], "/v1.9.2/envoy-gateway-crds.yaml")
    error_message = "The Envoy Gateway CRD step does not pin the v1.9.2 CRDs"
  }
}

run "envoy_gateway_and_its_crd_steps_are_absent_when_disabled" {
  command = plan

  module {
    source = "./modules/k8s-bootstrap"
  }

  variables {
    enable_envoy_gateway = false
  }

  assert {
    condition     = length(helm_release.envoy_gateway) == 0
    error_message = "enable_envoy_gateway = false should not install Envoy Gateway"
  }

  assert {
    condition     = length(terraform_data.gateway_api_crds) == 0 && length(terraform_data.envoy_gateway_crds) == 0
    error_message = "enable_envoy_gateway = false should not apply the Gateway API or Envoy Gateway CRDs"
  }
}
