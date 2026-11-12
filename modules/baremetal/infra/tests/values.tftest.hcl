# Plans modules/values alone, with no provider at all, and the root against mocked providers.
# Run: bash scripts/plan-tests.sh modules/baremetal
#
# modules/values is how a tool gets the module's values without a cluster: it must give what the root
# gives for the same inputs, with the root's defaults for whatever it is not given, and its outputs must
# carry every name and size a tool would otherwise copy out of this module's files.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  kube_context        = "test"
  metallb_addresses   = ["10.20.0.51-10.20.0.59"]
  envoy_gateway_lb_ip = "10.20.0.50"
  sizing_profile      = "production"
  cluster_nodes = {
    worker-1 = { cpu = 64, memory_gi = 256, disk_gi = 4000 }
    worker-2 = { cpu = 64, memory_gi = 256, disk_gi = 4000 }
    worker-3 = { cpu = 64, memory_gi = 256, disk_gi = 4000 }
  }
}

run "root" {
  command = plan
}

run "alone" {
  command = plan

  module {
    source = "./modules/values"
  }

  assert {
    condition     = output.langsmith_values == run.root.langsmith_helm_values && output.smithdb_values == run.root.smithdb_helm_values && yamlencode(output.datastore_values) == run.root.datastore_values
    error_message = "modules/values alone gives other Helm values than the root for the same inputs: a default in modules/values/variables.tf has drifted from the root's."
  }

  assert {
    condition     = output.pods == run.root.pods && output.features == run.root.features && output.budget == run.root.budget && output.values_files == run.root.values_files
    error_message = "modules/values alone counts other pods or features than the root for the same inputs: a default in modules/values/variables.tf has drifted from the root's."
  }
}

run "every_profile_sizes_every_store" {
  command = plan

  module {
    source = "./modules/values"
  }

  assert {
    condition     = alltrue([for p in ["minimum", "lab", "dev", "production", "production-large"] : length(output.datastore_sizes.profiles[p]) == 4 && alltrue([for s in values(output.datastore_sizes.profiles[p]) : s.cpu_m > 0 && s.lim_mem_mi >= s.mem_mi && s.storage_gi > 0])])
    error_message = "Every sizing profile sizes all four stores in datastore-sizes.yaml, each with a request, a limit at least as large and a volume."
  }

  assert {
    condition     = output.datastore_sizes.profiles.dev == output.datastore_sizes.profiles.lab && output.datastore_sizes.shared_increment.full.postgres.storage_gi > 0 && output.datastore_sizes.juicefs.lim_mem_mi > 0
    error_message = "dev takes lab's table; the products' increments and the JuiceFS Redis are in the table too."
  }
}

run "the_datastores_say_where_each_store_answers" {
  command = plan

  module {
    source = "./modules/values"
  }

  variables {
    datastore_namespace = "acme-data"
    enable_fleet        = true
  }

  assert {
    condition     = output.datastores.namespace == "acme-data" && output.datastores.instances["postgres-langsmith"].host == "postgres-langsmith.acme-data.svc.cluster.local" && output.datastores.instances["redis-langsmith"].port == 6379 && output.datastores.instances.rustfs.enabled && !output.datastores.instances["redis-juicefs"].enabled
    error_message = "Each instance the chart can run is listed with its host in the data namespace, and whether this install runs it."
  }

  assert {
    condition     = output.datastores.secrets.postgres.name == "langsmith-postgres" && output.datastores.secrets.fleet_postgres.name == "langsmith-fleet-postgres" && output.datastores.secrets.fleet_redis.keys == ["redis_connection_url"] && output.datastores.redis_db.fleet == 1
    error_message = "The Secrets LangSmith reads, a product's included, carry their names and keys, and each product its Redis database."
  }

  assert {
    condition     = output.datastores.instance_label == "langsmith.lab/datastore-instance" && output.datastores.buckets.juicefs == "sandbox-juicefs"
    error_message = "The label selecting each instance and the buckets are outputs, not left to be copied from the chart."
  }
}

run "images_and_operator_charts_are_outputs" {
  command = plan

  module {
    source = "./modules/values"
  }

  variables {
    postgres_image       = "mirror.example.com/library/postgres:18.6"
    cnpg_chart_version   = "0.29.9"
    redis_sentinel_image = "mirror.example.com/opstree/redis-sentinel:v7.4.11"
  }

  assert {
    condition     = output.datastore_values.redis.sentinelImage == "mirror.example.com/opstree/redis-sentinel:v7.4.11" && output.images.redis_sentinel == output.datastore_values.redis.sentinelImage
    error_message = "redis_sentinel_image must reach the chart's redis.sentinelImage, or the Sentinels stay on quay.io whatever a mirror carries."
  }

  assert {
    condition     = output.images.postgres == "mirror.example.com/library/postgres:18.6" && output.images.redis_opstree == "quay.io/opstree/redis:v7.4.11" && length(output.images) == 10
    error_message = "Every image the module runs outside the chart is an output, set or pinned."
  }

  assert {
    condition     = output.operator_charts.postgres.version == "0.29.9" && output.operator_charts.redis.chart == "redis-operator" && output.datastore_values.operatorNamespaces.postgres == output.operator_charts.postgres.namespace
    error_message = "The operators' charts are outputs, and the chart's values name the same namespaces."
  }
}

run "values_files_follow_the_features" {
  command = plan

  module {
    source = "./modules/values"
  }

  variables {
    enable_deployments         = true
    enable_standalone_insights = true
    enable_sso_oidc            = true
  }

  assert {
    condition     = output.values_files == ["values.yaml", "langsmith-values-overrides.yaml", "langsmith-values-admin.yaml", "langsmith-values-sizing-production.yaml", "langsmith-values-agent-deploys.yaml", "langsmith-values-standalone-insights.yaml", "langsmith-values-sso.yaml", "langsmith-values-smithdb.yaml"]
    error_message = "values_files is deploy.sh's order: base, overrides, admin, sizing, each enabled feature, SSO, then SmithDB."
  }
}

run "smithdb_replaces_its_pods_in_place" {
  command = plan

  module {
    source = "./modules/values"
  }

  assert {
    condition     = alltrue([for c in ["ingestion", "query", "mutations", "runRules", "statsQuery"] : output.smithdb_values.smithdb[c].deployment.strategy.rollingUpdate.maxSurge == 0 && output.smithdb_values.smithdb[c].deployment.strategy.rollingUpdate.maxUnavailable == 1])
    error_message = "SmithDB's Deployments roll out with no surge pod: on fixed hardware nothing adds the room for one."
  }

  assert {
    condition     = output.smithdb_values.smithdb.query.deployment.strategy.type == "RollingUpdate" && can(output.smithdb_values.smithdb.compaction) && !can(output.smithdb_values.smithdb.compaction.deployment.strategy)
    error_message = "The rollout joins the tier's own values and leaves the components the chart rolls without a surge alone."
  }
}

run "clickhouse_takes_the_volume_given" {
  command = plan

  variables {
    clickhouse_source     = "in-cluster"
    clickhouse_storage_gi = 900
  }

  assert {
    condition     = output.langsmith_helm_values.clickhouse.statefulSet.persistence.size == "900Gi" && one([for p in output.pods : p.disk_gi if p.name == "clickhouse/statefulset"]) == 900
    error_message = "ClickHouse's volume is the one given, in its values and in the budget alike."
  }
}

run "clickhouse_storage_must_be_whole_gib" {
  command = plan

  variables {
    clickhouse_storage_gi = 0.5
  }

  expect_failures = [var.clickhouse_storage_gi]
}
