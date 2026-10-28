# Plans the budget gate against mocked providers: no cluster, no credentials.
# Run: bash scripts/plan-tests.sh modules/baremetal

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  kube_context        = "test"
  metallb_addresses   = ["10.20.0.51-10.20.0.59"]
  envoy_gateway_lb_ip = "10.20.0.50"
  # A small reference cluster: three 6-core workers behind a tainted control plane.
  cluster_nodes = {
    control-plane = { cpu = 6, memory_gi = 23.2, disk_gi = 208, role = "control-plane" }
    worker-1      = { cpu = 6, memory_gi = 15.4, disk_gi = 208 }
    worker-2      = { cpu = 6, memory_gi = 15.3, disk_gi = 208 }
    worker-3      = { cpu = 6, memory_gi = 23.2, disk_gi = 208 }
  }
}

run "lab_fits_small_cluster" {
  command = plan

  variables {
    sizing_profile = "lab"
  }

  assert {
    condition     = output.budget.smithdb_tier == "minimal"
    error_message = "lab should use the minimal SmithDB tier."
  }

  assert {
    condition     = output.budget.requested.cpu <= output.budget.ceiling.cpu
    error_message = "lab should fit the small cluster's CPU budget."
  }
}

run "minimum_fits_small_cluster" {
  command = plan

  variables {
    sizing_profile = "minimum"
  }
}

run "dev_does_not_fit_small_cluster" {
  command = plan

  variables {
    sizing_profile = "dev"
  }

  # SmithDB small: an 8-CPU compaction-worker can't land on a 6-CPU node.
  expect_failures = [terraform_data.budget]
}

run "production_does_not_fit_small_cluster" {
  command = plan

  variables {
    sizing_profile = "production"
  }

  expect_failures = [terraform_data.budget]
}

run "production_large_fits_large_cluster" {
  command = plan

  variables {
    sizing_profile = "production-large"
    cluster_nodes = {
      for i in range(8) : "worker-${i}" => { cpu = 32, memory_gi = 128, disk_gi = 1000 }
    }
  }
}

run "lab_with_deployments_fits" {
  command = plan

  variables {
    sizing_profile             = "lab"
    enable_deployments         = true
    expected_agent_deployments = 1
  }

  assert {
    condition     = contains(output.budget.features, "deployments")
    error_message = "deployments should be listed as enabled."
  }
}

run "lab_with_all_standalone_products_does_not_fit" {
  command = plan

  variables {
    sizing_profile             = "lab"
    enable_deployments         = true
    enable_fleet               = true
    enable_standalone_insights = true
    enable_standalone_polly    = true
    expected_agent_deployments = 2
  }

  expect_failures = [terraform_data.budget]
}

run "shared_postgres_gets_one_database_per_product" {
  command = plan

  variables {
    sizing_profile          = "minimum"
    enable_standalone_polly = true
    enable_fleet            = true
  }

  assert {
    # Map iteration is in sorted key order, so products come out alphabetically.
    condition     = join(",", output.budget.postgres_databases) == "langsmith,langsmith_fleet,langsmith_polly"
    error_message = "Expected databases langsmith, langsmith_fleet, langsmith_polly on postgres-langsmith."
  }
}


run "agent_estimate_requires_deployments" {
  command = plan

  variables {
    sizing_profile             = "lab"
    expected_agent_deployments = 1
  }

  expect_failures = [var.expected_agent_deployments]
}

run "small_cluster_creates_no_smithdb_node_labels_or_taints" {
  command = plan

  variables {
    sizing_profile = "lab"
  }

  assert {
    condition     = length(kubernetes_labels.smithdb_node) == 0 && length(kubernetes_node_taint.smithdb_node) == 0
    error_message = "No smithdb roles in cluster_nodes, so no node should be labeled or tainted."
  }

  assert {
    condition     = output.budget.smithdb_pools.cache == "workers" && output.budget.smithdb_pools.compute == "workers"
    error_message = "Without dedicated nodes, SmithDB should share the workers."
  }
}

run "dev_fits_with_dedicated_smithdb_nodes" {
  command = plan

  variables {
    sizing_profile = "dev"
    cluster_nodes = {
      worker-1        = { cpu = 6, memory_gi = 15.4, disk_gi = 208 }
      worker-2        = { cpu = 6, memory_gi = 15.3, disk_gi = 208 }
      worker-3        = { cpu = 6, memory_gi = 23.2, disk_gi = 208 }
      smithdb-cache-1 = { cpu = 16, memory_gi = 64, disk_gi = 1000, role = "smithdb-cache" }
      smithdb-cache-2 = { cpu = 16, memory_gi = 64, disk_gi = 1000, role = "smithdb-cache" }
      smithdb-comp-1  = { cpu = 8, memory_gi = 32, disk_gi = 200, role = "smithdb-compute" }
    }
  }

  assert {
    condition     = output.budget.smithdb_pools.cache == "smithdb-cache" && output.budget.smithdb_pools.compute == "smithdb-compute"
    error_message = "SmithDB should be budgeted on its dedicated pools."
  }

  assert {
    condition     = length(kubernetes_node_taint.smithdb_node) == 3
    error_message = "All three dedicated nodes should get a taint."
  }
}

run "envoy_ip_inside_pool_fails" {
  command = plan

  variables {
    sizing_profile      = "lab"
    envoy_gateway_lb_ip = "10.20.0.55"
  }

  expect_failures = [terraform_data.envoy_lb_ip_check]
}

run "envoy_ip_outside_cidr_pool_passes" {
  command = plan

  variables {
    sizing_profile      = "lab"
    metallb_addresses   = ["10.20.0.48/29"]
    envoy_gateway_lb_ip = "10.20.0.60"
  }
}

run "metallb_announces_from_every_node_by_default" {
  command = plan

  assert {
    condition     = length(var.metallb_l2_node_selector) == 0
    error_message = "The default L2 node selector must be empty: stock kubeadm, k3s and RKE2 don't label workers, and an unmatched selector leaves the gateway IP unanswered."
  }
}

run "standalone_features_get_gcp_style_secrets_and_db_job" {
  command = plan

  variables {
    sizing_profile          = "minimum"
    enable_standalone_polly = true
    enable_fleet            = true
  }

  assert {
    condition     = length(kubernetes_secret_v1.standalone_postgres) == 2 && length(kubernetes_secret_v1.standalone_redis) == 2
    error_message = "Polly and Fleet should each get a postgres and a redis Secret."
  }

  assert {
    condition     = output.features.standalone.fleet.redis_db == 1 && output.features.standalone.polly.redis_db == 2
    error_message = "Redis DB indexes must match modules/gcp (fleet 1, polly 2, insights 3)."
  }

  assert {
    condition     = length(module.postgres_langsmith.extra_databases) == 2
    error_message = "postgres-langsmith should ensure 2 extra databases."
  }
}

run "lab_default_creates_no_feature_resources" {
  command = plan

  variables {
    sizing_profile = "lab"
  }

  assert {
    condition     = length(kubernetes_secret_v1.standalone_postgres) == 0 && length(module.postgres_langsmith.extra_databases) == 0
    error_message = "No features enabled, so no feature secrets or extra databases."
  }
}


run "blob_storage_on_by_default" {
  command = plan

  assert {
    condition     = output.langsmith_helm_values.config.blobStorage.enabled && output.langsmith_helm_values.config.blobStorage.bucketName == "langsmith-blobs" && output.langsmith_helm_values.config.blobStorage.minBlobStorageSizeKb == "20"
    error_message = "Blob storage is on by default: config.blobStorage points at the langsmith-blobs bucket with the chart's 20 KB threshold."
  }

  assert {
    condition     = output.object_store.buckets == ["smithdb", "langsmith-blobs"]
    error_message = "RustFS should create both the smithdb and langsmith-blobs buckets."
  }

  assert {
    condition     = output.features.blob_storage
    error_message = "features.blob_storage tells deploy.sh to copy the blob keys."
  }
}

run "blob_storage_off" {
  command = plan

  variables {
    enable_blob_storage = false
  }

  assert {
    condition     = !can(output.langsmith_helm_values.config.blobStorage) && !output.features.blob_storage
    error_message = "With blob storage off, the values carry no config.blobStorage."
  }

  assert {
    condition     = output.object_store.buckets == ["smithdb"]
    error_message = "With blob storage off, only the smithdb bucket is created."
  }
}

run "blob_threshold_must_be_whole_kib" {
  command = plan

  variables {
    blob_storage_min_size_kb = 2.5
  }

  expect_failures = [var.blob_storage_min_size_kb]
}

run "deployments_off_installs_no_keda" {
  command = plan

  assert {
    condition     = length(helm_release.keda) == 0 && !can(output.langsmith_helm_values.config.deployment) && !can(output.langsmith_helm_values.operator)
    error_message = "Without enable_deployments: no KEDA, no config.deployment, no Deployments sizing."
  }
}

run "deployments_on_installs_keda_and_wires_the_chart" {
  command = plan

  variables {
    sizing_profile     = "lab"
    enable_deployments = true
  }

  assert {
    condition     = length(helm_release.keda) == 1 && helm_release.keda[0].version == var.keda_chart_version
    error_message = "enable_deployments must install KEDA at the pinned chart version."
  }

  assert {
    condition     = output.langsmith_helm_values.config.deployment.enabled && !output.langsmith_helm_values.config.deployment.tlsEnabled
    error_message = "config.deployment.enabled is set, and tlsEnabled is false for an http URL."
  }

  assert {
    condition     = output.langsmith_helm_values.operator.deployment.resources.requests.cpu == "100m" && output.langsmith_helm_values.listener.deployment.resources.requests.memory == "512Mi"
    error_message = "Deployments sizing must come from the budget's feature_pod_sizes (slim on lab)."
  }
}

run "deployments_tls_follows_url_scheme" {
  command = plan

  variables {
    enable_deployments   = true
    langsmith_domain     = "langsmith.example.com"
    langsmith_url_scheme = "https"
  }

  assert {
    condition     = output.langsmith_helm_values.config.deployment.tlsEnabled
    error_message = "With an https URL, config.deployment.tlsEnabled must be true or agent deployments stay in DEPLOYING."
  }
}

run "products_get_budget_sizing" {
  command = plan

  variables {
    sizing_profile             = "minimum"
    enable_fleet               = true
    enable_standalone_polly    = true
    enable_standalone_insights = true
  }

  assert {
    condition     = output.langsmith_helm_values.polly.apiServer.deployment.resources.requests.cpu == "500m" && output.langsmith_helm_values.engineInsightsAgent.queue.deployment.resources.requests.cpu == "250m" && output.langsmith_helm_values.fleet.apiServer.deployment.resources.requests.memory == "512Mi"
    error_message = "Fleet, Polly and Insights must get the budget's slim sizes on minimum and lab, not the chart or example defaults."
  }

  assert {
    condition     = output.langsmith_helm_values.fleetToolServer.deployment.resources.limits.cpu == "2000m"
    error_message = "fleet-tool-server needs a CPU limit of at least 2 (it crash-loops on startup under 1 CPU)."
  }

  assert {
    condition     = output.langsmith_helm_values.engineInsightsAgent.queue.deployment.resources.limits.memory == "4096Mi" && output.langsmith_helm_values.polly.apiServer.deployment.resources.limits.memory == "8192Mi"
    error_message = "Limits come from the full-tier sizes even on slim profiles (insights-queue OOMed at a 1Gi limit)."
  }
}

run "no_products_no_product_sizing" {
  command = plan

  assert {
    condition     = !can(output.langsmith_helm_values.polly) && !can(output.langsmith_helm_values.fleet) && !can(output.langsmith_helm_values.engineInsightsAgent)
    error_message = "Without the product flags, the values carry no product sizing."
  }
}

run "telemetry_off_by_default" {
  command = plan

  assert {
    condition     = !can(output.langsmith_helm_values.commonEnv)
    error_message = "Usage telemetry is off by default, so the values set no commonEnv."
  }
}

run "telemetry_on_sets_phone_home_env" {
  command = plan

  variables {
    enable_usage_telemetry = true
  }

  assert {
    condition     = output.langsmith_helm_values.commonEnv[0].name == "PHONE_HOME_USAGE_REPORTING_ENABLED" && output.langsmith_helm_values.commonEnv[0].value == "true"
    error_message = "enable_usage_telemetry should set PHONE_HOME_USAGE_REPORTING_ENABLED=true in commonEnv."
  }
}

run "url_defaults_to_http_on_gateway_ip" {
  command = plan

  assert {
    condition     = output.langsmith_url == "http://10.20.0.50"
    error_message = "With no domain, LangSmith should be served on http://<envoy_gateway_lb_ip>."
  }
}

run "url_https_with_domain" {
  command = plan

  variables {
    langsmith_domain     = "langsmith-lab.example.com"
    langsmith_url_scheme = "https"
  }

  assert {
    condition     = output.langsmith_helm_values.config.hostname == "https://langsmith-lab.example.com"
    error_message = "config.hostname should carry the https scheme when TLS terminates in front of the gateway."
  }
}

run "https_without_domain_is_rejected" {
  command = plan

  variables {
    langsmith_url_scheme = "https"
  }

  expect_failures = [var.langsmith_url_scheme]
}

run "tunnel_off_by_default" {
  command = plan

  assert {
    condition     = length(module.cloudflared) == 0 && !output.cloudflare_tunnel.enabled
    error_message = "The Cloudflare Tunnel connector should be off by default."
  }

  # Envoy Gateway's Service name: envoy-<ns>-<gateway>-<sha256("ns/gateway")[:8]>,
  # checked against a live Envoy Gateway Service.
  assert {
    condition     = output.cloudflare_tunnel.origin_service_url == "http://envoy-langsmith-langsmith-gateway-7e32c34c.envoy-gateway-system.svc.cluster.local:80"
    error_message = "origin_service_url should match the Service Envoy Gateway creates for langsmith/langsmith-gateway."
  }
}

run "tunnel_requires_token" {
  command = plan

  variables {
    enable_cloudflare_tunnel = true
  }

  expect_failures = [var.cloudflare_tunnel_token]
}

run "tunnel_on_with_token" {
  command = plan

  variables {
    sizing_profile           = "lab"
    enable_cloudflare_tunnel = true
    cloudflare_tunnel_token  = "test-token"
  }

  assert {
    condition     = length(module.cloudflared) == 1 && output.cloudflare_tunnel.namespace == "cloudflared"
    error_message = "enable_cloudflare_tunnel should create the connector in namespace cloudflared."
  }

  assert {
    condition     = output.budget.requested.cpu <= output.budget.ceiling.cpu
    error_message = "lab plus the tunnel connector should still fit the small cluster's CPU budget."
  }
}

run "lan_route_follows_domain" {
  command = plan

  variables {
    langsmith_domain = "langsmith-lab.example.com"
  }

  assert {
    condition     = output.cloudflare_tunnel.lan_route
    error_message = "With a domain, the LAN catch-all route should be on so the gateway IP keeps serving LangSmith."
  }
}
