# envoy_gateway_image_registry: Envoy Gateway's controller and proxy images from
# a mirror that keeps docker.io as the first path segment. The controller image
# goes into the Helm release; the proxy image and the pull Secret are outputs
# that helm/scripts/deploy.sh sets on the EnvoyProxy. Each refusal run breaks
# one input.

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
  ingress_controller      = "envoy-gateway"
  envoy_gateway_version   = "v1.2.0"
}

run "no_mirror_pulls_from_docker_hub" {
  command = plan

  variables {
    envoy_gateway_image_registry = ""
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "" && output.envoy_gateway_proxy_image == "" && output.envoy_gateway_image_pull_secret_name == ""
    error_message = "With no envoy_gateway_image_registry, no mirror image or pull Secret should be set"
  }
}

run "mirror_sets_controller_and_proxy_images" {
  command = plan

  variables {
    envoy_gateway_image_registry = "nexus.example.com"
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "nexus.example.com/docker.io/envoyproxy/gateway:v1.2.0"
    error_message = "Controller image should be <registry>/docker.io/envoyproxy/gateway:<envoy_gateway_version>, got ${module.aks.envoy_gateway_image}"
  }
  assert {
    condition     = output.envoy_gateway_proxy_image == "nexus.example.com/docker.io/envoyproxy/envoy:distroless-v1.32.1"
    error_message = "Proxy image should be the v1.2.0 default from the mirror, got ${output.envoy_gateway_proxy_image}"
  }
  assert {
    condition     = output.envoy_gateway_image_pull_secret_name == ""
    error_message = "No pull Secret was set, so none should be output"
  }
}

run "mirror_with_port_path_and_pull_secret" {
  command = plan

  variables {
    envoy_gateway_image_registry         = "nexus.example.com:8443/mirror"
    envoy_gateway_image_pull_secret_name = "nexus-pull"
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "nexus.example.com:8443/mirror/docker.io/envoyproxy/gateway:v1.2.0"
    error_message = "A registry with a port and path should prefix the controller image as given"
  }
  assert {
    condition     = output.envoy_gateway_image_pull_secret_name == "nexus-pull"
    error_message = "The pull Secret name should reach deploy.sh through the output"
  }
}

run "other_ingress_controllers_output_nothing" {
  command = plan

  variables {
    ingress_controller           = "nginx"
    envoy_gateway_image_registry = "nexus.example.com"
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "" && output.envoy_gateway_proxy_image == ""
    error_message = "Without Envoy Gateway, no Envoy image should be output"
  }
}

run "refuses_a_scheme" {
  command = plan

  variables {
    envoy_gateway_image_registry = "https://nexus.example.com"
  }

  expect_failures = [var.envoy_gateway_image_registry]
}

run "refuses_a_trailing_slash" {
  command = plan

  variables {
    envoy_gateway_image_registry = "nexus.example.com/"
  }

  expect_failures = [var.envoy_gateway_image_registry]
}

run "refuses_an_uppercase_path" {
  command = plan

  variables {
    envoy_gateway_image_registry = "nexus.example.com/Mirror"
  }

  expect_failures = [var.envoy_gateway_image_registry]
}

run "refuses_a_pull_secret_without_a_mirror" {
  command = plan

  variables {
    envoy_gateway_image_registry         = ""
    envoy_gateway_image_pull_secret_name = "nexus-pull"
  }

  expect_failures = [var.envoy_gateway_image_pull_secret_name]
}

run "refuses_a_version_without_a_known_proxy_image" {
  command = plan

  variables {
    envoy_gateway_version        = "v1.3.0"
    envoy_gateway_image_registry = "nexus.example.com"
  }

  expect_failures = [var.envoy_gateway_image_registry]
}
