# What reaches the charts: tracing only on one SmithDB pod; one TTL pair everywhere; the stores reserved,
# at their priority, on the storage classes given, labelled with the instance; each access mode's ingress;
# the versions the plan resolved; and a cluster of one's own (cloud = cluster), which make export serves.

variables {
  cloud                 = "baremetal"
  ssh_host              = "box.example.com"
  box                   = "m"
  langsmith_license_key = "test"
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.6.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
}

run "tracing_only_on_unified_smithdb" {
  command = plan
  assert {
    condition = (
      output.values.langsmith.values.smithdb.topology == "unified" &&
      !output.values.langsmith.values.clickhouse.enabled &&
      !output.values.langsmith.values.insights.enabled &&
      !output.values.langsmith.values.polly.enabled &&
      !output.values.langsmith.values.operator.enabled
    )
    error_message = "Lite runs tracing on one unified SmithDB pod with every other product off."
  }
}

run "one_ttl_pair_drives_langsmith_smithdb_and_the_bucket" {
  command = plan
  variables {
    short_ttl_days = 7
    long_ttl_days  = 90
  }
  assert {
    condition     = output.values.langsmith.values.config.ttl.ttl_period_seconds.shortlived == "604800" && output.values.langsmith.values.config.ttl.ttl_period_seconds.longlived == "7776000"
    error_message = "LangSmith's TTLs are not 7 and 90 days."
  }
  assert {
    condition     = output.values.datastores.values.rustfs.ttlDays.short == 7 && output.values.datastores.values.rustfs.ttlDays.long == 90
    error_message = "the blob bucket's expiry rules are not 7 and 90 days."
  }
}

run "a_long_ttl_under_the_charts_minimum_is_refused" {
  command = plan
  variables { long_ttl_days = 7 }
  expect_failures = [var.long_ttl_days]
}

run "the_stores_run_at_their_priority_and_carry_the_instance" {
  command = plan
  assert {
    condition = (
      output.values.datastores.values.priorityClassName == "langsmith-lite-stores" &&
      output.values.langsmith.values.smithdb.unified.deployment.priorityClassName == "langsmith-lite-stores" &&
      output.values.datastores.values.datastoreLabel["langsmith-lite/instance"] == "langsmith-lite"
    )
    error_message = "the stores and SmithDB should run at the stores' priority, labelled with the instance."
  }
  assert {
    condition     = output.values.datastores.values.postgres.instances.langsmith.databases == ["smithdb_metastore"] && output.values.datastores.values.postgres.instances.langsmith.maxConnections == 200
    error_message = "one Postgres should hold the metastore, with the derived max_connections."
  }
}

run "payload_and_redis_knobs_reach_the_chart" {
  command = plan
  variables {
    max_payload_mb          = 50
    redis_runs_expiry_hours = 2
    blob_min_kb             = 64
  }
  assert {
    condition = (
      output.values.langsmith.values.frontend.maxBodySize == "50M" &&
      output.values.langsmith.values.config.settings.redisRunsExpirySeconds == "7200" &&
      output.values.langsmith.values.config.blobStorage.minBlobStorageSizeKb == "64"
    )
    error_message = "the payload and Redis settings should reach the chart."
  }
}

run "observability_and_mission_control_follow_their_switches" {
  command = plan
  variables {
    observability   = false
    mission_control = false
  }
  assert {
    condition     = output.plan.releases == ["datastores", "langsmith"] && !contains(keys(output.plan.pods), "grafana")
    error_message = "with both off, only the stores and LangSmith should install."
  }
}

run "localhost_exposes_nothing_but_ssh" {
  command = plan
  variables { access = "localhost" }
  assert {
    condition     = output.url == "http://localhost:8080" && output.values.langsmith.values.ingress.annotations["traefik.ingress.kubernetes.io/router.entrypoints"] == "web"
    error_message = "localhost should be served on Traefik's plain HTTP entrypoint, which ssh carries."
  }
}

run "dns_serves_https_with_lets_encrypt" {
  command = plan
  variables {
    access     = "dns"
    domain     = "langsmith.example.com"
    acme_email = "ops@example.com"
  }
  assert {
    condition     = output.url == "https://langsmith.example.com" && output.values.langsmith.values.ingress.annotations["traefik.ingress.kubernetes.io/router.tls.certresolver"] == "le"
    error_message = "dns should serve LangSmith on its domain over HTTPS from the le resolver."
  }
}

run "dns_needs_a_domain" {
  command = plan
  variables { access = "dns" }
  expect_failures = [terraform_data.fit]
}

run "tunnel_needs_its_token" {
  command = plan
  variables {
    access = "tunnel"
    domain = "langsmith.example.com"
  }
  expect_failures = [terraform_data.fit]
}

run "a_plan_without_resolved_versions_is_refused" {
  command = plan
  variables { resolved = null }
  expect_failures = [terraform_data.fit]
}

run "the_plan_installs_the_versions_resolve_wrote" {
  command = plan
  variables {
    resolved = {
      charts       = { langsmith = "0.18.7", "mission-control" = "1.2.12", datastores = "0.6.0-abc" }
      app_versions = { "mission-control" = "1.2.12" }
    }
  }
  assert {
    condition     = output.values.langsmith.chart.version == "0.18.7" && output.plan.versions.mission_control_images == "1.2.12" && strcontains(output.values.grafana.values.dashboards.lite.langsmith.url, "/langsmith-0.18.7/")
    error_message = "the plan should install the resolved versions and read the dashboard at that release."
  }
}

run "mission_control_writes_nothing" {
  command = plan
  assert {
    condition     = alltrue([for f in ["fixIssue", "adopt", "alerts", "configSave", "valuesOverride", "deploy", "contention"] : !output.values["mission-control"].values.config.features[f]])
    error_message = "Mission Control's write features should be off."
  }
}

run "node_exporter_stays_off_the_hosts_network" {
  command = plan
  assert {
    condition     = !output.values.prometheus.values["prometheus-node-exporter"].hostNetwork
    error_message = "node-exporter would serve unauthenticated metrics on every address of the box."
  }
}

run "every_bound_has_an_alert" {
  command = plan
  assert {
    condition     = length(output.values.grafana.values.alerting["rules.yaml"].groups[0].rules) == 4
    error_message = "with the data on the system disk, the alerts should cover that disk, Redis, Postgres and pod memory."
  }
}

run "a_data_disk_gets_its_own_alert" {
  command = plan
  variables {
    data_path = "/srv/data"
    machine   = { cpu = 8, memory_gi = 32, disk_gi = 40, data_disk_gi = 600 }
  }
  assert {
    condition     = length(output.values.grafana.values.alerting["rules.yaml"].groups[0].rules) == 5
    error_message = "a data disk of its own should add its alert."
  }
}

# A cluster of one's own: one install a namespace, its storage classes, its ingress, no box to fit.
run "a_cluster_of_ones_own_needs_its_storage_classes" {
  command = plan
  variables {
    cloud = "cluster"
  }
  expect_failures = [terraform_data.fit]
}

run "a_cluster_of_ones_own" {
  command = plan
  variables {
    cloud                 = "cluster"
    namespace             = "acme-langsmith"
    storage_class         = "gp3"
    scratch_storage_class = "gp3"
    box                   = "s"
  }
  assert {
    condition = (
      output.values.datastores.namespace == "acme-langsmith-data" &&
      output.values.datastores.values.storageClass == "gp3" &&
      !output.values.langsmith.values.ingress.enabled &&
      output.plan.releases == ["datastores", "langsmith"] &&
      output.plan.cost_usd_a_month == null
    )
    error_message = "on a cluster: the instance's namespaces, the cluster's storage class, no ingress, no observability or Mission Control, no box cost."
  }
}
