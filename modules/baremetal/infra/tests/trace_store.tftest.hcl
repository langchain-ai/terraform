# Plans the trace-store inputs against mocked providers: no cluster, no credentials.
# Run: bash agents/plan-tests.sh modules/baremetal
#
# The defaults must leave this module's install exactly as it was (SmithDB-only),
# and each stage of a ClickHouse to SmithDB migration must give the chart what it
# needs and the budget what it will schedule.

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}

variables {
  kube_context        = "test"
  metallb_addresses   = ["10.20.0.51-10.20.0.59"]
  envoy_gateway_lb_ip = "10.20.0.50"
  sizing_profile      = "lab"
  # Room for ClickHouse beside everything else: three 16-core workers.
  cluster_nodes = {
    control-plane = { cpu = 6, memory_gi = 23.2, disk_gi = 208, role = "control-plane" }
    worker-1      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
    worker-2      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
    worker-3      = { cpu = 16, memory_gi = 64, disk_gi = 500 }
  }
}

run "defaults_are_smithdb_only" {
  command = plan

  assert {
    condition     = output.smithdb_helm_values.smithdb.enabled && output.smithdb_helm_values.smithdb.langsmith.ingestion.enabled && output.smithdb_helm_values.smithdb.langsmith.query.enabled && !output.smithdb_helm_values.smithdb.langsmith.migration.enabled
    error_message = "By default SmithDB takes every write and read, with no migration: the install this module made before these inputs."
  }

  assert {
    condition     = !can(output.langsmith_helm_values.clickhouse) && !can(output.smithdb_helm_values.smithdb.migration)
    error_message = "By default no ClickHouse and no migration values reach the chart."
  }

  assert {
    condition     = length(kubernetes_secret_v1.langsmith_clickhouse) == 0 && length(kubernetes_secret_v1.smithdb_taskdb) == 0
    error_message = "By default no ClickHouse or TaskDB Secret is created."
  }
}

run "clickhouse_in_cluster_is_the_charts_statefulset_on_our_secret" {
  command = plan

  variables {
    clickhouse_source = "in-cluster"
  }

  assert {
    condition     = output.langsmith_helm_values.clickhouse.enabled && output.langsmith_helm_values.clickhouse.disableSecretCreation && output.langsmith_helm_values.clickhouse.external.existingSecretName == "langsmith-clickhouse"
    error_message = "In-cluster ClickHouse is the chart's StatefulSet, reading the Secret Terraform makes instead of the chart's default password."
  }

  assert {
    condition     = length(kubernetes_secret_v1.langsmith_clickhouse) == 1 && output.langsmith_helm_values.clickhouse.statefulSet.persistence.size == "50Gi"
    error_message = "In-cluster ClickHouse gets its Secret and the volume the budget counts."
  }

  # The lab profile deploys the dev sizing file, whose ClickHouse requests 2 CPU and 8Gi.
  assert {
    condition     = output.budget.requested.cpu == run.defaults_are_smithdb_only.budget.requested.cpu + 2 && output.budget.requested.memory_gi == run.defaults_are_smithdb_only.budget.requested.memory_gi + 8
    error_message = "The budget counts ClickHouse at the sizing file's requests (2 CPU, 8Gi on lab)."
  }
}

run "dual_write_with_reads_on_clickhouse" {
  command = plan

  variables {
    clickhouse_source     = "in-cluster"
    smithdb_query_enabled = false
  }

  assert {
    condition     = output.smithdb_helm_values.smithdb.langsmith.ingestion.enabled && !output.smithdb_helm_values.smithdb.langsmith.query.enabled
    error_message = "Dual write: SmithDB takes writes, reads stay on ClickHouse."
  }
}

run "backfill_adds_the_job_and_taskdb" {
  command = plan

  variables {
    clickhouse_source             = "in-cluster"
    smithdb_query_enabled         = false
    smithdb_migration_enabled     = true
    smithdb_migration_parallelism = 2
  }

  assert {
    condition     = output.smithdb_helm_values.smithdb.migration.job.parallelism == 2 && output.smithdb_helm_values.smithdb.migration.taskdb.postgres.auth.existingSecretName == "smithdb-taskdb"
    error_message = "The backfill runs at the asked parallelism, with TaskDB on the Secret Terraform makes."
  }

  assert {
    condition     = length(kubernetes_secret_v1.smithdb_taskdb) == 1
    error_message = "A backfill creates the TaskDB Secret."
  }

  # minimal sizes on lab: 2 migration pods at 1 CPU / 2Gi, TaskDB at 250m / 512Mi, on the workers pool.
  assert {
    condition     = output.budget.requested.cpu == run.clickhouse_in_cluster_is_the_charts_statefulset_on_our_secret.budget.requested.cpu + 2.25
    error_message = "The budget counts every migration pod and TaskDB."
  }
}

run "clickhouse_only_customer_runs_no_smithdb" {
  command = plan

  variables {
    clickhouse_source         = "in-cluster"
    enable_smithdb            = false
    smithdb_ingestion_enabled = false
    smithdb_query_enabled     = false
  }

  assert {
    condition     = !output.smithdb_helm_values.smithdb.enabled
    error_message = "A customer before the move has SmithDB off."
  }

  assert {
    condition     = output.budget.requested.cpu < run.clickhouse_in_cluster_is_the_charts_statefulset_on_our_secret.budget.requested.cpu
    error_message = "With SmithDB off, the budget drops SmithDB's pods."
  }
}

run "backfill_without_clickhouse_is_refused" {
  command = plan

  variables {
    smithdb_migration_enabled = true
  }

  expect_failures = [terraform_data.trace_store]
}

run "nothing_taking_writes_is_refused" {
  command = plan

  variables {
    smithdb_ingestion_enabled = false
  }

  expect_failures = [terraform_data.trace_store]
}

run "gates_without_smithdb_are_refused" {
  command = plan

  variables {
    clickhouse_source = "in-cluster"
    enable_smithdb    = false
  }

  expect_failures = [terraform_data.trace_store]
}
