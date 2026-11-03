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
    condition     = toset(keys(kubernetes_node_taint.sandbox_host)) == toset(["worker-2", "worker-3"]) && toset(keys(kubernetes_labels.sandbox_host)) == toset(["worker-2", "worker-3"]) && alltrue([for t in values(kubernetes_node_taint.sandbox_host) : t.force])
    error_message = "Each sandbox host is labelled and tainted, and no other node."
  }

  assert {
    condition     = alltrue([for k, l in kubernetes_labels.sandbox_host : l.field_manager != kubernetes_node_taint.sandbox_host[k].field_manager])
    error_message = "The label and the taint have their own field managers: one owner drops the other's field on every apply."
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

  # Tainted for sandbox-host alone, a sandbox node gives the app pods nothing.
  assert {
    condition     = output.budget.pools.sandbox.nodes == 2 && output.budget.pools.workers.nodes == 1 && length([for p in output.pods : p if p.name == "sandboxes/sandbox-host" && p.pool == "sandbox"]) == 1
    error_message = "Sandbox nodes are their own pool: sandbox-host counts there, and the workers lose their capacity."
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

run "engine_gateway_needs_https" {
  command = plan

  variables {
    enable_sandboxes               = true
    sandbox_hosts                  = ["worker-2"]
    sandbox_source_cidrs           = ["192.0.2.0/24"]
    enable_engine                  = true
    langsmith_url_scheme           = "https"
    langsmith_domain               = "langsmith.example.com"
    engine_gateway_openai_base_url = "http://gateway.example.com/openai/v1"
  }

  expect_failures = [terraform_data.sandboxes]
}

run "engine_through_a_gateway" {
  command = plan

  variables {
    enable_sandboxes               = true
    sandbox_hosts                  = ["worker-2"]
    sandbox_source_cidrs           = ["192.0.2.0/24"]
    enable_engine                  = true
    langsmith_url_scheme           = "https"
    langsmith_domain               = "langsmith.example.com"
    enable_usage_telemetry         = true
    engine_gateway_openai_base_url = "https://gateway.example.com/openai/v1"
  }

  assert {
    condition     = output.features.engine_gateway && contains(output.langsmith_helm_values.commonEnv, { name = "ENGINE_GATEWAY_APIS", value = "[\"openai\"]" })
    error_message = "LangSmith is told which APIs the gateway serves, on every component."
  }

  assert {
    condition     = length(output.langsmith_helm_values.commonEnv) == 2
    error_message = "The gateway's env and the telemetry flag share one commonEnv list; Helm would keep only one of two."
  }

  assert {
    condition = alltrue([for w in ["apiServer", "queue"] : (
      contains([for e in output.langsmith_helm_values.engineInsightsAgent[w].deployment.extraEnv : e.name], "ENGINE_GATEWAY_OPENAI_BASE_URL")
      && output.langsmith_helm_values.engineInsightsAgent[w].deployment.volumes[0].secret.secretName == "engine-model-gateway"
      && can(output.langsmith_helm_values.engineInsightsAgent[w].deployment.resources)
    )])
    error_message = "Both Engine workloads get the gateway URL and its key, keeping their resources."
  }
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

  assert {
    condition     = !output.features.engine_gateway && !can(output.langsmith_helm_values.commonEnv) && !can(output.langsmith_helm_values.engineInsightsAgent.apiServer.deployment.extraEnv)
    error_message = "Without a gateway URL, Engine gets no gateway settings."
  }

  assert {
    condition     = contains(output.budget.features, "insights")
    error_message = "The budget counts and sizes the Insights pods Engine brings."
  }
}
