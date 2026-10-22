# envoy_gateway_image_registry: Envoy Gateway's controller and proxy images from
# a mirror, laid out with docker.io as the first path segment (the default) or
# without it (envoy_gateway_image_registry_keeps_source_host = false). The
# controller image goes into the Helm release; the proxy image and the pull
# Secret are outputs that helm/scripts/deploy.sh sets on the EnvoyProxy. Each
# refusal run breaks one input.

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

run "mirror_without_source_host" {
  command = plan

  variables {
    envoy_gateway_image_registry                   = "nexus.example.com"
    envoy_gateway_image_registry_keeps_source_host = false
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "nexus.example.com/envoyproxy/gateway:v1.2.0"
    error_message = "Without the source host, the controller image should be <registry>/envoyproxy/gateway:<envoy_gateway_version>, got ${module.aks.envoy_gateway_image}"
  }
  assert {
    condition     = output.envoy_gateway_proxy_image == "nexus.example.com/envoyproxy/envoy:distroless-v1.32.1"
    error_message = "Without the source host, the proxy image should be <registry>/envoyproxy/envoy:<tag>, got ${output.envoy_gateway_proxy_image}"
  }
}

run "mirror_without_source_host_with_port_path_and_pull_secret" {
  command = plan

  variables {
    envoy_gateway_image_registry                   = "nexus.example.com:8443/docker-group"
    envoy_gateway_image_registry_keeps_source_host = false
    envoy_gateway_image_pull_secret_name           = "nexus-pull"
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "nexus.example.com:8443/docker-group/envoyproxy/gateway:v1.2.0"
    error_message = "A registry with a port and path should prefix the controller image as given, with no docker.io segment"
  }
  assert {
    condition     = output.envoy_gateway_proxy_image == "nexus.example.com:8443/docker-group/envoyproxy/envoy:distroless-v1.32.1"
    error_message = "The proxy image should follow the same layout as the controller image"
  }
  assert {
    condition     = output.envoy_gateway_image_pull_secret_name == "nexus-pull"
    error_message = "The pull Secret name should reach deploy.sh through the output"
  }
}

run "layout_without_a_mirror_changes_nothing" {
  command = plan

  variables {
    envoy_gateway_image_registry                   = ""
    envoy_gateway_image_registry_keeps_source_host = false
  }

  assert {
    condition     = module.aks.envoy_gateway_image == "" && output.envoy_gateway_proxy_image == ""
    error_message = "The layout setting should do nothing without envoy_gateway_image_registry"
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

run "refuses_a_dotless_host" {
  command = plan

  variables {
    envoy_gateway_image_registry = "nexus"
  }

  expect_failures = [var.envoy_gateway_image_registry]
}

# envoy_gateway_chart_repository: where the machine running Terraform fetches
# the gateway-helm chart. The default keeps the reference the release always
# used, so an existing install plans no change. An OCI mirror carries the chart
# in the reference, and an https Helm proxy names it. A login is optional and
# comes as a pair.
run "default_chart_source_is_docker_hub_oci" {
  command = plan

  assert {
    condition     = module.aks.envoy_gateway_chart_source.chart == "oci://docker.io/envoyproxy/gateway-helm" && module.aks.envoy_gateway_chart_source.repository == null && !module.aks.envoy_gateway_chart_source.authenticated
    error_message = "The default should fetch oci://docker.io/envoyproxy/gateway-helm with no repository and no login, got ${jsonencode(module.aks.envoy_gateway_chart_source)}"
  }
}

run "oci_mirror_carries_the_chart_in_the_reference" {
  command = plan

  variables {
    envoy_gateway_chart_repository = "oci://nexus.example.com/helm-envoy"
  }

  assert {
    condition     = module.aks.envoy_gateway_chart_source.chart == "oci://nexus.example.com/helm-envoy/gateway-helm" && module.aks.envoy_gateway_chart_source.repository == null
    error_message = "An OCI mirror should give chart oci://nexus.example.com/helm-envoy/gateway-helm and no repository, got ${jsonencode(module.aks.envoy_gateway_chart_source)}"
  }
}

run "https_mirror_names_the_chart_with_a_login" {
  command = plan

  variables {
    envoy_gateway_chart_repository          = "https://nexus.example.com/repository/helm-envoy"
    envoy_gateway_chart_repository_username = "helm-reader"
    envoy_gateway_chart_repository_password = "fixture-not-a-real-secret"
  }

  assert {
    condition     = module.aks.envoy_gateway_chart_source.repository == "https://nexus.example.com/repository/helm-envoy" && module.aks.envoy_gateway_chart_source.chart == "gateway-helm" && module.aks.envoy_gateway_chart_source.authenticated
    error_message = "An https mirror should set the repository, name the chart gateway-helm and send the login, got ${jsonencode(module.aks.envoy_gateway_chart_source)}"
  }
}

run "refuses_a_chart_repository_with_a_trailing_slash" {
  command = plan

  variables {
    envoy_gateway_chart_repository = "oci://nexus.example.com/helm-envoy/"
  }

  expect_failures = [var.envoy_gateway_chart_repository]
}

run "refuses_a_chart_username_without_its_password" {
  command = plan

  variables {
    envoy_gateway_chart_repository          = "https://nexus.example.com/repository/helm-envoy"
    envoy_gateway_chart_repository_username = "helm-reader"
  }

  expect_failures = [var.envoy_gateway_chart_repository_username]
}
