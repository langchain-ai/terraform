# What reaches the charts: tracing only on SmithDB, one TTL pair everywhere, the payload limit, each
# access mode's ingress and Traefik settings, and the versions the plan resolved.

variables {
  resolved = {
    charts       = { langsmith = "0.18.2", "mission-control" = "1.2.10", prometheus = "30.0.0", grafana = "14.5.0", "redis-exporter" = "6.38.0", "postgres-exporter" = "8.3.0", datastores = "0.5.0-test" }
    app_versions = { "mission-control" = "1.2.10" }
  }
  cloud                 = "baremetal"
  ssh_host              = "box.example.com"
  box                   = "m"
  langsmith_license_key = "test"
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
  assert {
    condition     = output.values.langsmith.values.smithdb.unified.deployment.volumes[0].ephemeral.volumeClaimTemplate.spec.resources.requests.storage == "50Gi"
    error_message = "SmithDB's cache is not the preset's 50 GiB."
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

run "payload_and_redis_knobs_reach_the_chart" {
  command = plan
  variables {
    max_payload_mb          = 50
    redis_runs_expiry_hours = 2
    blob_min_kb             = 64
  }
  assert {
    condition     = output.values.langsmith.values.frontend.maxBodySize == "50M"
    error_message = "max_payload_mb did not reach the frontend."
  }
  assert {
    condition     = output.values.langsmith.values.config.settings.redisRunsExpirySeconds == "7200"
    error_message = "redis_runs_expiry_hours did not reach the chart."
  }
  assert {
    condition     = output.values.langsmith.values.config.blobStorage.minBlobStorageSizeKb == "64"
    error_message = "blob_min_kb did not reach the chart."
  }
}

run "one_postgres_holds_the_metastore" {
  command = plan
  assert {
    condition     = output.values.datastores.values.postgres.instances.langsmith.databases == ["smithdb_metastore"] && !output.values.datastores.values.postgres.instances.smithdb.enabled
    error_message = "SmithDB's metastore should be a second database on the one Postgres."
  }
}

run "localhost_exposes_nothing_but_ssh" {
  command = plan
  variables { access = "localhost" }
  assert {
    condition     = output.url == "http://localhost:8080" && output.values.langsmith.values.config.hostname == ""
    error_message = "localhost should be served through make access with no hostname."
  }
  assert {
    condition     = output.values.langsmith.values.ingress.annotations["traefik.ingress.kubernetes.io/router.entrypoints"] == "web"
    error_message = "localhost should route on Traefik's plain HTTP entrypoint, which ssh carries."
  }
}

run "dns_needs_a_domain" {
  command = plan
  variables { access = "dns" }
  expect_failures = [terraform_data.fit]
}

run "dns_serves_https_with_lets_encrypt" {
  command = plan
  variables {
    access     = "dns"
    domain     = "langsmith.example.com"
    acme_email = "ops@example.com"
  }
  assert {
    condition     = output.url == "https://langsmith.example.com" && output.values.langsmith.values.config.hostname == "https://langsmith.example.com"
    error_message = "dns should serve LangSmith on its domain over HTTPS."
  }
  assert {
    condition     = output.values.langsmith.values.ingress.annotations["traefik.ingress.kubernetes.io/router.tls.certresolver"] == "le"
    error_message = "dns should take its certificate from the le resolver."
  }
}

run "tunnel_needs_its_token" {
  command = plan
  variables {
    access = "tunnel"
    domain = "langsmith.example.com"
  }
  expect_failures = [terraform_data.fit]
}

run "the_plan_installs_the_versions_resolve_wrote" {
  command = plan
  variables {
    resolved = {
      charts       = { langsmith = "0.18.7", "mission-control" = "1.2.12", datastores = "0.5.0-abc" }
      app_versions = { "mission-control" = "1.2.12" }
    }
  }
  assert {
    condition     = output.values.langsmith.chart.version == "0.18.7" && output.plan.versions.mission_control_images == "1.2.12"
    error_message = "the plan does not install the resolved versions."
  }
  assert {
    condition     = strcontains(output.values.grafana.values.dashboards.lite.langsmith.url, "/langsmith-0.18.7/")
    error_message = "the dashboard is not read at the installed chart's release tag."
  }
  assert {
    condition     = endswith(output.values.datastores.chart.chart, "/static/charts/datastores-0.5.0-abc.tgz")
    error_message = "the datastores chart URL does not carry the packaged chart's digest."
  }
}

run "a_plan_without_resolved_versions_is_refused" {
  command = plan
  variables { resolved = null }
  expect_failures = [terraform_data.fit]
}

run "mission_control_writes_nothing" {
  command = plan
  assert {
    condition = alltrue([for f in ["fixIssue", "adopt", "alerts", "configSave", "valuesOverride", "deploy", "contention"] :
    !output.values["mission-control"].values.config.features[f]])
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
