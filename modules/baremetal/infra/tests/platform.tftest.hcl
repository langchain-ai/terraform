# Plans the add-on toggles against mocked providers: no cluster, no credentials.
# Run: bash agents/plan-tests.sh modules/baremetal
#
# Defaults must install all four add-ons as before; a cluster that has its own
# gets none of ours, its StorageClass and Gateway are used instead, and the
# budget stops counting what we no longer install.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  kube_context        = "test"
  metallb_addresses   = ["10.20.0.51-10.20.0.59"]
  envoy_gateway_lb_ip = "10.20.0.50"
  sizing_profile      = "lab"
  cluster_nodes = {
    control-plane = { cpu = 6, memory_gi = 23.2, disk_gi = 208, role = "control-plane" }
    worker-1      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
    worker-2      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
    worker-3      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
  }
}

run "defaults_install_every_add_on" {
  command = plan

  assert {
    condition     = length(module.metrics_server) == 1 && length(module.local_path) == 1 && length(module.metallb) == 1 && length(module.envoy_gateway) == 1
    error_message = "By default all four add-ons are installed, as before."
  }

  assert {
    condition     = length([for p in output.pods : p if startswith(p.name, "addon/metallb")]) == 2
    error_message = "By default the budget counts MetalLB's controller and speaker."
  }
}

run "existing_cluster_gets_none_of_ours" {
  command = plan

  variables {
    install_metrics_server = false
    install_local_path     = false
    install_metallb        = false
    install_envoy_gateway  = false
    storage_class          = "ocs-storagecluster-ceph-rbd"
    existing_gateway       = { name = "corp-gateway", namespace = "gateways" }
    envoy_gateway_lb_ip    = ""
    clickhouse_source      = "in-cluster"
  }

  assert {
    condition     = length(module.metrics_server) == 0 && length(module.local_path) == 0 && length(module.metallb) == 0 && length(module.envoy_gateway) == 0
    error_message = "A cluster with its own add-ons gets none of ours."
  }

  assert {
    condition     = output.langsmith_helm_values.gateway.name == "corp-gateway" && output.langsmith_helm_values.gateway.namespace == "gateways"
    error_message = "LangSmith's HTTPRoutes attach to the cluster's own Gateway."
  }

  assert {
    condition     = output.storage_classes.retain == "ocs-storagecluster-ceph-rbd" && output.langsmith_helm_values.clickhouse.statefulSet.persistence.storageClassName == "ocs-storagecluster-ceph-rbd"
    error_message = "Every volume, ClickHouse's included, uses the cluster's StorageClass."
  }

  assert {
    condition     = length([for p in output.pods : p if startswith(p.name, "addon/")]) == 0
    error_message = "The budget stops counting add-ons we no longer install."
  }
}

run "local_path_off_needs_a_storage_class" {
  command = plan

  variables {
    install_local_path = false
  }

  expect_failures = [terraform_data.platform]
}

run "envoy_off_needs_a_gateway" {
  command = plan

  variables {
    install_envoy_gateway = false
  }

  expect_failures = [terraform_data.platform]
}

run "our_metallb_and_envoy_need_the_gateway_ip" {
  command = plan

  variables {
    envoy_gateway_lb_ip = ""
  }

  expect_failures = [terraform_data.platform]
}

run "gateway_tls_plans_with_a_domain_and_https" {
  command = plan

  variables {
    gateway_tls_secret   = "langsmith-tls"
    langsmith_domain     = "langsmith.example.com"
    langsmith_url_scheme = "https"
  }

  assert {
    condition     = output.langsmith_helm_values.config.hostname == "https://langsmith.example.com"
    error_message = "With TLS at the gateway, LangSmith's URL is the https domain."
  }
}

run "gateway_tls_needs_https_and_a_domain" {
  command = plan

  variables {
    gateway_tls_secret = "langsmith-tls"
  }

  expect_failures = [terraform_data.platform]
}

run "gateway_tls_is_only_for_our_gateway" {
  command = plan

  variables {
    gateway_tls_secret    = "langsmith-tls"
    langsmith_domain      = "langsmith.example.com"
    langsmith_url_scheme  = "https"
    install_envoy_gateway = false
    existing_gateway      = { name = "corp-gateway", namespace = "gateways" }
  }

  expect_failures = [terraform_data.platform]
}
