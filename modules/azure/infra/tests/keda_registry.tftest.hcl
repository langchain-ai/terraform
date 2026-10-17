# keda_image_registry: KEDA's three images from a mirror, laid out with ghcr.io
# as the first path segment (the default) or without it
# (keda_image_registry_keeps_source_host = false). The mirror goes to the chart
# as global.image.registry, the host-dropping layout as the three repositories,
# and the pull Secret as imagePullSecrets; keda_helm_sets is that map, and
# keda_images the paths the chart composes from it (the tag is the chart
# version, which KEDA keeps equal to its appVersion). Each refusal run breaks
# one input. The map outputs are compared with tomap() literals, because a
# bare { } is an object and == never treats the two as equal; empties use
# length().

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

run "no_mirror_pulls_from_ghcr" {
  command = plan

  assert {
    condition     = output.keda_images == tomap({ "keda" = "ghcr.io/kedacore/keda:2.14.0", "keda-metrics-apiserver" = "ghcr.io/kedacore/keda-metrics-apiserver:2.14.0", "keda-admission-webhooks" = "ghcr.io/kedacore/keda-admission-webhooks:2.14.0" })
    error_message = "Without a mirror the images should be the chart's ghcr.io defaults, got ${jsonencode(output.keda_images)}"
  }
  assert {
    condition     = length(module.k8s_bootstrap.keda_helm_sets) == 0 && output.keda_image_pull_secret_name == ""
    error_message = "Without a mirror nothing should be set on the release"
  }
}

run "mirror_keeps_the_source_host" {
  command = plan

  variables {
    keda_image_registry = "nexus.example.com"
  }

  assert {
    condition     = output.keda_images["keda"] == "nexus.example.com/ghcr.io/kedacore/keda:2.14.0" && output.keda_images["keda-metrics-apiserver"] == "nexus.example.com/ghcr.io/kedacore/keda-metrics-apiserver:2.14.0" && output.keda_images["keda-admission-webhooks"] == "nexus.example.com/ghcr.io/kedacore/keda-admission-webhooks:2.14.0"
    error_message = "Images should be <registry>/ghcr.io/kedacore/<name>:2.14.0, got ${jsonencode(output.keda_images)}"
  }
  assert {
    condition     = module.k8s_bootstrap.keda_helm_sets == tomap({ "global.image.registry" = "nexus.example.com" })
    error_message = "A mirror that keeps the host should set only global.image.registry, got ${jsonencode(module.k8s_bootstrap.keda_helm_sets)}"
  }
}

run "mirror_with_port_path_and_pull_secret" {
  command = plan

  variables {
    keda_image_registry         = "nexus.example.com:8443/mirror"
    keda_image_pull_secret_name = "nexus-pull"
  }

  assert {
    condition     = output.keda_images["keda"] == "nexus.example.com:8443/mirror/ghcr.io/kedacore/keda:2.14.0"
    error_message = "A port and path should carry through, got ${output.keda_images["keda"]}"
  }
  assert {
    condition     = module.k8s_bootstrap.keda_helm_sets["imagePullSecrets[0].name"] == "nexus-pull" && output.keda_image_pull_secret_name == "nexus-pull"
    error_message = "The pull Secret should reach the release and the output"
  }
}

run "mirror_without_source_host" {
  command = plan

  variables {
    keda_image_registry                   = "nexus.example.com"
    keda_image_registry_keeps_source_host = false
  }

  assert {
    condition     = output.keda_images["keda"] == "nexus.example.com/kedacore/keda:2.14.0" && output.keda_images["keda-admission-webhooks"] == "nexus.example.com/kedacore/keda-admission-webhooks:2.14.0"
    error_message = "Without the source host the images should be <registry>/kedacore/<name>:2.14.0, got ${jsonencode(output.keda_images)}"
  }
  assert {
    condition     = module.k8s_bootstrap.keda_helm_sets == tomap({ "global.image.registry" = "nexus.example.com", "image.keda.repository" = "kedacore/keda", "image.metricsApiServer.repository" = "kedacore/keda-metrics-apiserver", "image.webhooks.repository" = "kedacore/keda-admission-webhooks" })
    error_message = "Dropping the host should set the three repositories beside the registry, got ${jsonencode(module.k8s_bootstrap.keda_helm_sets)}"
  }
}

run "layout_without_a_mirror_changes_nothing" {
  command = plan

  variables {
    keda_image_registry_keeps_source_host = false
  }

  assert {
    condition     = output.keda_images["keda"] == "ghcr.io/kedacore/keda:2.14.0" && length(module.k8s_bootstrap.keda_helm_sets) == 0
    error_message = "The layout setting alone should change nothing"
  }
}

run "keda_off_outputs_nothing" {
  command = plan

  variables {
    install_keda        = false
    keda_image_registry = "nexus.example.com"
  }

  assert {
    condition     = length(output.keda_images) == 0 && length(module.k8s_bootstrap.keda_helm_sets) == 0 && output.keda_image_pull_secret_name == ""
    error_message = "With install_keda = false the mirror settings should produce nothing"
  }
}

run "refuses_a_scheme" {
  command = plan

  variables {
    keda_image_registry = "https://nexus.example.com"
  }

  expect_failures = [var.keda_image_registry]
}

run "refuses_a_trailing_slash" {
  command = plan

  variables {
    keda_image_registry = "nexus.example.com/"
  }

  expect_failures = [var.keda_image_registry]
}

run "refuses_an_uppercase_path" {
  command = plan

  variables {
    keda_image_registry = "nexus.example.com/Mirror"
  }

  expect_failures = [var.keda_image_registry]
}

run "refuses_a_pull_secret_without_a_mirror" {
  command = plan

  variables {
    keda_image_registry         = ""
    keda_image_pull_secret_name = "nexus-pull"
  }

  expect_failures = [var.keda_image_pull_secret_name]
}

run "refuses_a_chart_repository_without_a_scheme" {
  command = plan

  variables {
    keda_chart_repository = "nexus.example.com/repository/helm-kedacore"
  }

  expect_failures = [var.keda_chart_repository]
}

run "chart_repository_login_reaches_the_release" {
  command = plan

  variables {
    keda_chart_repository          = "https://nexus.example.com/repository/helm-kedacore"
    keda_chart_repository_username = "helm-reader"
    keda_chart_repository_password = "fixture-not-a-real-secret"
  }

  assert {
    condition     = module.k8s_bootstrap.keda_chart_repository_authenticated
    error_message = "A username and password for the chart mirror should reach the KEDA release"
  }
}

run "no_login_keeps_the_chart_fetch_anonymous" {
  command = plan

  variables {
    keda_chart_repository = "https://nexus.example.com/repository/helm-kedacore"
  }

  assert {
    condition     = !module.k8s_bootstrap.keda_chart_repository_authenticated
    error_message = "Without a username the chart fetch should stay anonymous"
  }
}

run "refuses_a_chart_repository_username_without_its_password" {
  command = plan

  variables {
    keda_chart_repository_username = "helm-reader"
  }

  expect_failures = [var.keda_chart_repository_username]
}
