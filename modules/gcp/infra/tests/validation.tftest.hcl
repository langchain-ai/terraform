# Variable validation in the GCP root. Every validation block in variables.tf is
# fed a value it must reject.
#
# Bad values are grouped by class rather than given one run each. Terraform
# reports every variable validation error in a single pass, so a group costs one
# plan and still names the variable whose validation stopped firing: the run
# fails with the expected failure that did not occur. A variable with two
# validations needs two runs, since expect_failures names the variable and not
# the individual block.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id        = "langsmith-plan-tests"
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# Terraform keeps planning past an expected variable validation failure, and a
# mock provider returns the computed master_auth block as an empty list, which
# the cluster module's ca_certificate output indexes. See tests/wiring.tftest.hcl
# for the same override and the full reason.
override_module {
  target = module.gke_cluster
  outputs = {
    cluster_name   = "langsmith-plan-tests-gke"
    cluster_id     = "projects/langsmith-plan-tests/locations/us-central1/clusters/langsmith-plan-tests-gke"
    endpoint       = "10.0.0.1"
    ca_certificate = "ZmFrZS1jYS1mb3ItcGxhbi10ZXN0cw=="
    location       = "us-central1"
  }
}

run "enums_reject_an_unlisted_value" {
  command = plan

  variables {
    environment                               = "qa"
    gke_release_channel                       = "EXTENDED"
    gke_network_policy_provider               = "CILIUM"
    postgres_source                           = "cloudsql"
    postgres_ssl_mode                         = "REQUIRED"
    redis_source                              = "memorystore"
    ingress_type                              = "nginx"
    clickhouse_source                         = "clickhouse-cloud"
    tls_certificate_source                    = "acm"
    sizing_profile                            = "small"
    smithdb_metastore_source                  = "import"
    smithdb_metastore_ssl_mode                = "REQUIRED"
    sandbox_juicefs_redis_rdb_snapshot_period = "THIRTY_MINUTES"
    smithdb_instance_store_local_ssd_count    = 3
  }

  expect_failures = [
    var.environment,
    var.gke_release_channel,
    var.gke_network_policy_provider,
    var.postgres_source,
    var.postgres_ssl_mode,
    var.redis_source,
    var.ingress_type,
    var.clickhouse_source,
    var.tls_certificate_source,
    var.sizing_profile,
    var.smithdb_metastore_source,
    var.smithdb_metastore_ssl_mode,
    var.sandbox_juicefs_redis_rdb_snapshot_period,
    var.smithdb_instance_store_local_ssd_count,
  ]
}

run "names_and_versions_reject_a_malformed_value" {
  command = plan

  variables {
    project_id                         = "P"
    region                             = "us-central"
    zone                               = "us-central1"
    name_prefix                        = "Prod"
    langsmith_namespace                = "LangSmith"
    postgres_version                   = "POSTGRES_16_1"
    redis_version                      = "REDIS_7"
    smithdb_metastore_database_version = "POSTGRES_14"
    smithdb_auth_proxy_image           = "gcr.io/langsmith/auth-proxy"
    labels                             = { "Owner" = "platform" }
    sandbox_default_container_requests = { cpu = "100m" }
  }

  expect_failures = [
    var.project_id,
    var.region,
    var.zone,
    var.name_prefix,
    var.langsmith_namespace,
    var.postgres_version,
    var.redis_version,
    var.smithdb_metastore_database_version,
    var.smithdb_auth_proxy_image,
    var.labels,
    var.sandbox_default_container_requests,
  ]
}

run "cidrs_reject_a_non_cidr" {
  command = plan

  variables {
    subnet_cidr   = "10.0.0.0"
    pods_cidr     = "10.1.0.0"
    services_cidr = "10.2.0.0"
  }

  expect_failures = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]
}

run "sizes_and_counts_reject_a_value_below_the_floor" {
  command = plan

  variables {
    gke_node_count                         = 0
    gke_min_nodes                          = 0
    gke_max_nodes                          = 0
    gke_disk_size                          = 20
    postgres_disk_size                     = 5
    redis_memory_size                      = 0
    sandbox_juicefs_redis_memory_size      = 0
    storage_ttl_short_days                 = 0
    storage_ttl_long_days                  = 0
    sandbox_host_ephemeral_local_ssd_count = -1
  }

  expect_failures = [
    var.gke_node_count,
    var.gke_min_nodes,
    var.gke_max_nodes,
    var.gke_disk_size,
    var.postgres_disk_size,
    var.redis_memory_size,
    var.sandbox_juicefs_redis_memory_size,
    var.storage_ttl_short_days,
    var.storage_ttl_long_days,
    var.sandbox_host_ephemeral_local_ssd_count,
  ]
}

run "sizes_and_counts_reject_a_value_above_the_ceiling" {
  command = plan

  variables {
    gke_node_count                    = 101
    gke_max_nodes                     = 1001
    gke_disk_size                     = 65537
    postgres_disk_size                = 65537
    redis_memory_size                 = 301
    sandbox_juicefs_redis_memory_size = 301
    storage_ttl_short_days            = 3651
    storage_ttl_long_days             = 3651
  }

  expect_failures = [
    var.gke_node_count,
    var.gke_max_nodes,
    var.gke_disk_size,
    var.postgres_disk_size,
    var.redis_memory_size,
    var.sandbox_juicefs_redis_memory_size,
    var.storage_ttl_short_days,
    var.storage_ttl_long_days,
  ]
}

# Local SSDs are whole disks, and the count above only covers the lower bound.
run "local_ssd_count_rejects_a_fraction" {
  command = plan

  variables {
    sandbox_host_ephemeral_local_ssd_count = 1.5
  }

  expect_failures = [var.sandbox_host_ephemeral_local_ssd_count]
}

# An empty password is how in-cluster Postgres is expressed, so the validation
# accepts "" and rejects anything shorter than 8 characters.
run "postgres_password_rejects_a_short_value" {
  command = plan

  variables {
    postgres_password = "short"
  }

  expect_failures = [var.postgres_password]
}
