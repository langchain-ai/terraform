# Plans the in-cluster datastores against mocked providers: no cluster, no credentials.
# Run: bash scripts/plan-tests.sh modules/baremetal
#
# One release of charts/datastores holds every in-cluster store, as StatefulSets by default or through
# the operators, and the Secrets LangSmith reads name the same hosts in both runtimes. That the chart
# renders in both runtimes is checked by scripts/check.sh (helm lint and helm template).

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

# Known at plan, so the assertions can follow each password into the values and the Secrets.
override_resource {
  target          = random_password.postgres
  override_during = plan
  values          = { result = "pgTestPassword" }
}

override_resource {
  target          = random_password.redis
  override_during = plan
  values          = { result = "redisTestPassword" }
}

override_resource {
  target          = random_password.rustfs_access_key
  override_during = plan
  values          = { result = "rustfsTestAccessKey" }
}

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

run "statefulsets_by_default_in_one_release" {
  command = plan

  variables {
    enable_standalone_polly = true
  }

  assert {
    condition     = length(helm_release.datastores) == 1 && length(helm_release.cnpg) == 0 && length(helm_release.redis_operator) == 0
    error_message = "By default one release of the chart runs every store, and no operator is installed."
  }

  assert {
    condition     = module.values.datastore_values.runtime == "statefulset" && module.values.datastore_values.postgres.instances.langsmith.enabled && module.values.datastore_values.postgres.instances.smithdb.enabled && module.values.datastore_values.redis.instances.langsmith.enabled && !module.values.datastore_values.redis.instances.juicefs.enabled && module.values.datastore_values.rustfs.enabled
    error_message = "Without Sandboxes the chart runs both Postgres, LangSmith's Redis and RustFS, and no JuiceFS Redis."
  }

  assert {
    condition     = join(",", module.values.datastore_values.postgres.instances.langsmith.databases) == "langsmith_polly" && join(",", module.values.datastore_values.rustfs.buckets) == "smithdb,langsmith-blobs" && join(",", module.values.datastore_values.rustfs.ttlBuckets) == "langsmith-blobs"
    error_message = "Each product gets its database, and only the blob bucket its expiry."
  }

  assert {
    condition     = module.values.datastore_values.postgres.instances.langsmith.resources.limits.memory == "${module.values.sized_datastores.postgres_langsmith.lim_mem_mi}Mi" && module.values.datastore_values.redis.instances.langsmith.volumeSize == "${module.values.sized_datastores.redis_langsmith.storage_gi}Gi"
    error_message = "The chart should get the sizes the budget counts."
  }

  assert {
    condition     = !strcontains(output.datastore_values, "pgTestPassword") && local.datastore_secret_values.postgres.instances.langsmith.password == "pgTestPassword" && local.datastore_secret_values.rustfs.accessKey == "rustfsTestAccessKey"
    error_message = "The passwords go in the second values document only, never the one the output shows."
  }

  assert {
    condition     = nonsensitive(kubernetes_secret_v1.langsmith_postgres[0].data.connection_url) == "langsmith:pgTestPassword@postgres-langsmith.langsmith-data.svc.cluster.local:5432/langsmith" && nonsensitive(kubernetes_secret_v1.langsmith_redis[0].data.connection_url) == "redis://:redisTestPassword@redis-langsmith.langsmith-data.svc.cluster.local:6379/0"
    error_message = "LangSmith's Secrets should name each store's Service in the one data namespace."
  }
}

run "every_store_in_the_namespace_given" {
  command = plan

  variables {
    datastore_namespace  = "acme-prod-data"
    enable_sandboxes     = true
    sandbox_hosts        = ["worker-1"]
    sandbox_source_cidrs = ["10.42.0.0/16"]
  }

  assert {
    condition     = module.values.datastore_values.namespace == "acme-prod-data" && module.values.datastore_values.createNamespaces && module.values.redis.juicefs.host == "redis-juicefs.acme-prod-data.svc.cluster.local" && module.values.rustfs.endpoint == "http://rustfs.acme-prod-data.svc.cluster.local:9000"
    error_message = "Every store, the JuiceFS Redis and RustFS included, should be reached in the one namespace given."
  }

  assert {
    condition     = nonsensitive(kubernetes_secret_v1.sandbox_juicefs[0].data.bucket) == "http://rustfs.acme-prod-data.svc.cluster.local:9000/sandbox-juicefs"
    error_message = "The sandboxes' JuiceFS bucket should be on RustFS in that namespace."
  }
}

run "langsmiths_own_namespace_is_not_created_twice" {
  command = plan

  variables {
    datastore_namespace = "langsmith"
  }

  assert {
    condition     = !module.values.datastore_values.createNamespaces
    error_message = "Terraform owns the langsmith namespace; the chart must not create it too."
  }
}

run "operators_install_before_the_chart" {
  command = plan

  variables {
    datastore_runtime = "operator"
  }

  assert {
    condition     = length(helm_release.cnpg) == 1 && length(helm_release.redis_operator) == 1 && helm_release.cnpg[0].version == var.cnpg_chart_version && helm_release.redis_operator[0].version == var.redis_operator_chart_version
    error_message = "With the operator runtime the module installs CloudNativePG and the Redis operator, at their pinned versions."
  }

  assert {
    condition     = module.values.datastore_values.runtime == "operator" && module.values.datastore_values.postgres.operatorImage == var.cnpg_postgres_image && module.values.datastore_values.redis.operatorImage == var.opstree_redis_image
    error_message = "The chart should run the operator runtime on the operators' images."
  }

  assert {
    condition     = length([for p in output.pods : p if p.name == "addon/cnpg-operator" || p.name == "addon/redis-operator"]) == 2
    error_message = "The budget should count both operators."
  }

  assert {
    condition     = nonsensitive(kubernetes_secret_v1.langsmith_postgres[0].data.connection_url) == "langsmith:pgTestPassword@postgres-langsmith.langsmith-data.svc.cluster.local:5432/langsmith" && nonsensitive(kubernetes_secret_v1.smithdb_config.data.smithdb_metastore_host) == "postgres-smithdb.langsmith-data.svc.cluster.local"
    error_message = "The operator runtime keeps every host LangSmith and SmithDB read."
  }
}

run "three_replicas_under_operators_are_counted" {
  command = plan

  variables {
    datastore_runtime  = "operator"
    datastore_replicas = 3
  }

  assert {
    condition     = module.values.datastore_values.postgres.instances.langsmith.replicas == 3 && module.values.datastore_values.postgres.instances.smithdb.replicas == 3 && module.values.datastore_values.redis.instances.langsmith.replicas == 3
    error_message = "Every Postgres and Redis instance should run three pods."
  }

  assert {
    condition     = length([for p in output.pods : p if p.name == "datastore/postgres-langsmith" && p.replicas == 3 && p.disk_gi == module.values.sized_datastores.postgres_langsmith.storage_gi]) == 1 && length([for p in output.pods : p if p.name == "datastore/rustfs" && p.replicas == 1]) == 1
    error_message = "The budget should count each Postgres pod with its own volume, and RustFS once."
  }

  assert {
    condition     = length([for p in output.pods : p if p.name == "datastore/redis-langsmith-sentinel" && p.replicas == 3 && p.cpu_n == 0.1 && p.mem_gi == 0.125]) == 1
    error_message = "Three Sentinels at 100m and 128Mi should be counted for the Redis."
  }

  assert {
    condition     = output.budget.requested.disk_gi - run.operators_install_before_the_chart.budget.requested.disk_gi == 2 * (module.values.sized_datastores.postgres_langsmith.storage_gi + module.values.sized_datastores.postgres_smithdb.storage_gi + module.values.sized_datastores.redis_langsmith.storage_gi)
    error_message = "Two more replicas of each Postgres and the Redis should add two more of each volume to the budget."
  }

  assert {
    condition     = output.budget.requested.cpu > run.operators_install_before_the_chart.budget.requested.cpu && length([for p in output.pods : p if p.name == "addon/cnpg-operator" || p.name == "addon/redis-operator"]) == 2
    error_message = "The replicas should raise the CPU the budget counts, beside both controllers."
  }
}

run "replicas_are_refused_under_statefulsets" {
  command = plan

  variables {
    datastore_replicas = 2
  }

  expect_failures = [var.datastore_replicas]
}

run "more_than_three_replicas_are_refused" {
  command = plan

  variables {
    datastore_runtime  = "operator"
    datastore_replicas = 4
  }

  expect_failures = [var.datastore_replicas]
}

run "no_operator_for_a_store_they_run" {
  command = plan

  variables {
    datastore_runtime = "operator"
    redis_source      = "external"
    redis_secret      = "acme-redis"
  }

  assert {
    condition     = length(helm_release.cnpg) == 1 && length(helm_release.redis_operator) == 0 && !module.values.datastore_values.redis.instances.langsmith.enabled
    error_message = "With their Redis there is no Redis operator and no Redis in the chart."
  }
}

run "no_release_when_they_run_every_store" {
  command = plan

  variables {
    postgres_source          = "external"
    redis_source             = "external"
    smithdb_metastore_source = "external"
    object_store_source      = "external"
    object_store_endpoint    = "https://objectscale.example:9021"
  }

  assert {
    condition     = length(helm_release.datastores) == 0 && length(random_password.postgres) == 0 && length(random_password.redis) == 0 && length(random_password.rustfs_access_key) == 0
    error_message = "With every store theirs the module runs no datastore and generates no password."
  }
}

run "an_unknown_runtime_is_refused" {
  command = plan

  variables {
    datastore_runtime = "kubedb"
  }

  expect_failures = [var.datastore_runtime]
}
