# Plans Sandboxes and Engine against mocked providers: no cluster, no credentials.
# Run: bash scripts/plan-tests.sh modules/baremetal
#
# Off by default. On, the module adds the
# JuiceFS Redis and bucket, the JuiceFS Secret, the sandbox nodes' label and
# taint, the chart values and the budget's pods, and refuses the combinations
# the chart or the product would reject later.

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

run "off_by_default" {
  command = plan

  assert {
    condition     = length(module.redis_juicefs) == 0 && length(kubernetes_secret_v1.sandbox_juicefs) == 0 && length(kubernetes_node_taint.sandbox_host) == 0
    error_message = "With Sandboxes off nothing of theirs is created."
  }

  assert {
    condition     = !can(output.langsmith_helm_values.sandboxes) && !can(output.langsmith_helm_values.engine)
    error_message = "With Sandboxes and Engine off the chart gets none of their values."
  }
}

run "sandboxes_on" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_hosts        = ["worker-2", "worker-3"]
    sandbox_source_cidrs = ["192.0.2.0/24", "10.42.0.0/16"]
  }

  assert {
    condition     = length(module.redis_juicefs) == 1 && length(kubernetes_secret_v1.sandbox_juicefs) == 1
    error_message = "Sandboxes get their own JuiceFS Redis and Secret."
  }

  assert {
    condition     = toset(keys(kubernetes_node_taint.sandbox_host)) == toset(["worker-2", "worker-3"]) && toset(keys(kubernetes_labels.sandbox_host)) == toset(["worker-2", "worker-3"])
    error_message = "Each sandbox host is labelled and tainted, and no other node."
  }

  assert {
    condition     = output.langsmith_helm_values.sandboxes.enabled && output.langsmith_helm_values.sandboxes.sandboxHost.deployment.replicas == 2 && output.langsmith_helm_values.sandboxes.sandboxHost.deployment.nodeSelector["sandbox.langsmith.com/host"] == "true"
    error_message = "One sandbox-host per sandbox node, pinned by the label the chart requires."
  }

  assert {
    condition     = output.langsmith_helm_values.sandboxes.juicefs.existingSecretName == "langsmith-sandbox-juicefs"
    error_message = "The chart reads JuiceFS from the module's Secret, not from values."
  }

  assert {
    condition     = length([for p in output.pods : p if p.name == "sandboxes/sandbox-host" && p.replicas == 2 && p.disk_gi == 50]) == 1 && length([for p in output.pods : p if p.name == "datastore/redis_juicefs"]) == 1
    error_message = "The budget counts each sandbox-host with its JuiceFS cache, and the JuiceFS Redis."
  }

  assert {
    condition     = kubernetes_namespace_v1.langsmith.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "privileged"
    error_message = "The langsmith namespace admits the privileged sandbox-host."
  }

  assert {
    condition     = output.features.sandboxes && !output.features.engine
    error_message = "deploy.sh reads the features output to add the callback signing key."
  }
}

run "sandboxes_need_hosts" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_source_cidrs = ["192.0.2.0/24"]
  }

  expect_failures = [terraform_data.sandboxes]
}

run "sandbox_hosts_must_be_cluster_nodes" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_hosts        = ["worker-9"]
    sandbox_source_cidrs = ["192.0.2.0/24"]
  }

  expect_failures = [terraform_data.sandboxes]
}

run "sandboxes_need_source_cidrs" {
  command = plan

  variables {
    enable_sandboxes = true
    sandbox_hosts    = ["worker-2"]
  }

  expect_failures = [terraform_data.sandboxes]
}

run "engine_needs_sandboxes" {
  command = plan

  variables {
    enable_engine        = true
    langsmith_url_scheme = "https"
    langsmith_domain     = "langsmith.example.com"
  }

  expect_failures = [terraform_data.sandboxes]
}

run "engine_needs_https" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_hosts        = ["worker-2"]
    sandbox_source_cidrs = ["192.0.2.0/24"]
    enable_engine        = true
  }

  expect_failures = [terraform_data.sandboxes]
}

run "engine_on" {
  command = plan

  variables {
    enable_sandboxes     = true
    sandbox_hosts        = ["worker-2"]
    sandbox_source_cidrs = ["192.0.2.0/24"]
    enable_engine        = true
    langsmith_url_scheme = "https"
    langsmith_domain     = "langsmith.example.com"
  }

  assert {
    condition     = output.langsmith_helm_values.engine.enabled && output.langsmith_helm_values.engine.intelligenceBaseUrl == "https://beacon.langchain.com/intelligence"
    error_message = "Engine is on, with the default intelligence endpoint."
  }

  assert {
    condition     = output.features.engine && contains(keys(output.features.standalone), "insights")
    error_message = "Engine brings the Insights deployment it runs on."
  }
}
