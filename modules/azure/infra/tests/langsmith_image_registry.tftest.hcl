# langsmith_image_registry: the mirror LangSmith's images come from, read by the
# scripts and validated here. The shape is the Envoy and KEDA one: a host with
# an optional port and a lowercase path, no scheme, no trailing slash. The
# keeps-source-host flag has no validation of its own (it is ignored without a
# registry, as Envoy's is).

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000000"
      client_id       = "00000000-0000-0000-0000-000000000000"
      object_id       = "00000000-0000-0000-0000-000000000000"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}
# The cluster module lists the subscription's AKS clusters to read the one it
# manages; the generated mock has no such shape, so give it an empty list.
mock_provider "azapi" {
  mock_data "azapi_resource_list" {
    defaults = {
      output = { clusters = [] }
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
}

run "accepts_a_host_with_port_and_path" {
  command = plan

  variables {
    langsmith_image_registry                   = "nexus.example.com:8443/mirror"
    langsmith_image_registry_keeps_source_host = false
  }

  assert {
    condition     = var.langsmith_image_registry == "nexus.example.com:8443/mirror"
    error_message = "A host with a port and a path should be accepted"
  }
}

run "refuses_a_registry_with_a_scheme" {
  command = plan

  variables {
    langsmith_image_registry = "https://nexus.example.com"
  }

  expect_failures = [var.langsmith_image_registry]
}

run "refuses_a_trailing_slash" {
  command = plan

  variables {
    langsmith_image_registry = "nexus.example.com/"
  }

  expect_failures = [var.langsmith_image_registry]
}

run "refuses_a_dotless_host" {
  command = plan

  variables {
    langsmith_image_registry = "nexus"
  }

  expect_failures = [var.langsmith_image_registry]
}

run "accepts_a_dotless_host_with_a_port" {
  command = plan

  variables {
    langsmith_image_registry = "nexus:5000"
  }

  assert {
    condition     = var.langsmith_image_registry == "nexus:5000"
    error_message = "A bare name with a port is a registry host and should be accepted"
  }
}

run "accepts_localhost" {
  command = plan

  variables {
    langsmith_image_registry = "localhost"
  }

  assert {
    condition     = var.langsmith_image_registry == "localhost"
    error_message = "localhost is a registry host and should be accepted"
  }
}
