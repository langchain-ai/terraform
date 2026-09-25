# Conditional wiring in the GCP root: every optional module, asserted in both
# directions. mock_provider means no cloud credentials, no state, and no API
# calls, so these run in the PR path.
#
# Each run sets every flag it asserts on rather than relying on the default, so
# a default change shows up as a failing assertion here and not as a test that
# quietly stops covering anything.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "null" {}
mock_provider "local" {}

variables {
  project_id = "langsmith-plan-tests"
  # postgres_source defaults to external, and both the root precondition and
  # the postgres module's own length validation require a value.
  postgres_password = "fixture-not-a-real-secret-Aa1"
}

# master_auth is a computed nested block, and a mock provider returns computed
# blocks as an empty list rather than as unknown. modules/k8s-cluster/outputs.tf
# indexes master_auth[0], so without this override every run fails on that index
# instead of on what it asserts. The cost is that the cluster module itself is
# not planned here, so its autopilot conditional needs its own test once that
# output stops hard-indexing.
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

# random_id.suffix.hex is unknown at plan time with a mock provider. The SmithDB
# network-disk StorageClass name carries the suffix, so fix it to keep
# smithdb_helm_values known.
override_resource {
  target          = random_id.suffix
  override_during = plan
  values = {
    hex = "a1b2c3d4"
  }
}

# ── Optional modules, off ────────────────────────────────────────────────────

run "optional_modules_absent_when_flags_are_false" {
  command = plan

  variables {
    enable_sandboxes             = false
    enable_smithdb               = false
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 0
    error_message = "enable_sandboxes = false still planned the JuiceFS Redis"
  }
  assert {
    condition     = length(module.smithdb) == 0
    error_message = "enable_smithdb = false still planned SmithDB"
  }
  assert {
    condition     = length(module.iam) == 0
    error_message = "enable_gcp_iam_module = false still planned the iam module"
  }
  assert {
    condition     = length(module.secrets) == 0
    error_message = "enable_secret_manager_module = false still planned the secrets module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "enable_dns_module = false still planned the dns module"
  }
  assert {
    condition     = length(module.ingress) == 0
    error_message = "install_ingress = false still planned the ingress module"
  }
}

# ── Optional modules, one flag at a time ─────────────────────────────────────
# Every flag starts false and exactly one is flipped, so a run that also plans a
# sibling module means two flags read the same variable.

run "enable_gcp_iam_module_adds_only_iam" {
  command = plan

  variables {
    enable_gcp_iam_module        = true
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.iam) == 1
    error_message = "enable_gcp_iam_module = true did not plan the iam module"
  }
  assert {
    condition     = length(module.secrets) == 0
    error_message = "enable_gcp_iam_module = true also planned the secrets module"
  }
}

run "enable_secret_manager_module_adds_only_secrets" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = true
    enable_dns_module            = false
    install_ingress              = false
  }

  assert {
    condition     = length(module.secrets) == 1
    error_message = "enable_secret_manager_module = true did not plan the secrets module"
  }
  assert {
    condition     = length(module.iam) == 0
    error_message = "enable_secret_manager_module = true also planned the iam module"
  }
}

run "enable_dns_module_adds_only_dns" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = true
    install_ingress              = false
  }

  assert {
    condition     = length(module.dns) == 1
    error_message = "enable_dns_module = true did not plan the dns module"
  }
  assert {
    condition     = length(module.ingress) == 0
    error_message = "enable_dns_module = true also planned the ingress module"
  }
}

run "install_ingress_adds_only_ingress" {
  command = plan

  variables {
    enable_gcp_iam_module        = false
    enable_secret_manager_module = false
    enable_dns_module            = false
    install_ingress              = true
  }

  assert {
    condition     = length(module.ingress) == 1
    error_message = "install_ingress = true did not plan the ingress module"
  }
  assert {
    condition     = length(module.dns) == 0
    error_message = "install_ingress = true also planned the dns module"
  }
}

run "enable_sandboxes_adds_the_juicefs_redis" {
  command = plan

  variables {
    enable_sandboxes = true
  }

  assert {
    condition     = length(module.sandbox_juicefs_redis) == 1
    error_message = "enable_sandboxes = true did not plan the JuiceFS Redis"
  }
}

# ── SmithDB ──────────────────────────────────────────────────────────────────

# Resolved values: the tier table and pool defaults in locals.tf, plus a
# 100m/128Mi Auth Proxy sidecar per pod in the quota figures.
run "smithdb_plans_its_own_node_pool" {
  command = plan

  variables {
    enable_smithdb    = true
    gke_use_autopilot = false
  }

  assert {
    condition     = length(module.smithdb) == 1
    error_message = "enable_smithdb = true did not plan SmithDB"
  }
  assert {
    condition     = length(module.smithdb_nodes) == 1
    error_message = "SmithDB did not plan the Local SSD node pool it needs"
  }
  assert {
    condition = output.smithdb_sizing == "small" && output.smithdb_cache_storage == "local-ssd" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "n2-standard-16"
      instance_store_local_ssd_count = 2
      instance_store_disk_size_gb    = 100
      compute_machine_type           = "n2-standard-8"
    } && output.smithdb_quota_extra == { cpu = 27, memory_gi = 53, pods = 12 }
    error_message = "sizing_profile = default did not resolve to SmithDB small local-ssd (n2-standard-16, 2 Local SSD, quota 27 CPU / 53 GiB)"
  }
  assert {
    condition = yamldecode(output.smithdb_helm_values).smithdb.query.deployment.resources == {
      requests = { cpu = "4", memory = "8Gi", "ephemeral-storage" = "200Gi" }
      limits   = { cpu = "4", memory = "8Gi", "ephemeral-storage" = "200Gi" }
      } && alltrue([
        for c in ["query", "ingestion", "compactionWorker"] :
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.volumes == [{ name = "cache", emptyDir = { sizeLimit = c == "query" ? "200Gi" : "100Gi" } }] &&
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.nodeSelector == { "smithdb-local/instance-store" = "true" } &&
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.replicas == 1 &&
        yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1 } }
    ])
    error_message = "SmithDB local-ssd cache components are not an emptyDir named cache on the cache pool with the tier resources, 1 replica, and an HPA minimum of 1"
  }
  assert {
    condition = (
      yamldecode(output.smithdb_helm_values).smithdb.compaction.deployment.nodeSelector == { "smithdb-local/compute" = "true" } &&
      yamldecode(output.smithdb_helm_values).smithdb.migration.job.nodeSelector == { "smithdb-local/instance-store" = "true" } &&
      yamldecode(output.smithdb_helm_values).smithdb.migration.taskdb.postgres.statefulSet.nodeSelector == { "smithdb-local/compute" = "true" } &&
      !contains(keys(yamldecode(output.smithdb_helm_values).smithdb), "cache") &&
      module.k8s_bootstrap.smithdb_cache_storage_class_name == null
    )
    error_message = "SmithDB local-ssd pins or cache settings are wrong"
  }
  # An existing install must not start dual write when it upgrades the chart.
  assert {
    condition     = output.smithdb_ingestion_enabled == false
    error_message = "smithdb_ingestion_enabled no longer defaults to false"
  }
  assert {
    condition     = output.smithdb_metastore_use_auth_proxy == true && output.smithdb_metastore_use_ssl == false
    error_message = "A created SmithDB metastore did not resolve to the Auth Proxy with direct TLS off"
  }
  assert {
    condition     = output.smithdb_metastore_tier == "db-custom-4-16384"
    error_message = "SmithDB small did not give the created metastore the tier db-custom-4-16384"
  }
  assert {
    condition     = !strcontains(output.smithdb_helm_values, "startTime")
    error_message = "An empty smithdb_migration_start_time still wrote smithdb.migration.startTime"
  }
}

run "smithdb_on_autopilot_is_rejected" {
  command = plan

  variables {
    enable_smithdb    = true
    gke_use_autopilot = true
  }

  # SmithDB needs the Local SSD node pools that Autopilot will not let this
  # module create.
  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_minimal_runs_on_the_general_pool" {
  command = plan

  variables {
    enable_smithdb = true
    sizing_profile = "minimum"
  }

  # Limits decide the extra: half of 12.5 CPU and 21.5 GiB, rounded up.
  assert {
    condition = (
      output.smithdb_sizing == "minimal" && output.smithdb_cache_storage == "network-disk" &&
      length(module.smithdb_nodes) == 0 && module.k8s_bootstrap.smithdb_cache_storage_class_name == null &&
      output.smithdb_quota_extra == { cpu = 7, memory_gi = 11, pods = 12 }
    )
    error_message = "sizing_profile = minimum did not resolve to SmithDB minimal: no node pools, no created StorageClass, quota 7 CPU / 11 GiB"
  }
  assert {
    condition = (
      yamldecode(output.smithdb_helm_values).smithdb.resourceTier == "small" &&
      yamldecode(output.smithdb_helm_values).smithdb.cache == { storageClassName = "standard-rwo" } &&
      !strcontains(output.smithdb_helm_values, "nodeSelector") &&
      alltrue([
        for c in ["query", "ingestion", "compactionWorker"] :
        yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1, maxReplicas = 1 } } &&
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.resources == {
          requests = { cpu = "1", memory = "2Gi" }
          limits   = { cpu = "2", memory = "4Gi" }
        }
      ])
    )
    error_message = "SmithDB minimal values are not the small tier on standard-rwo, with no pins, 1/2Gi requests, 2/4Gi limits, and one HPA replica"
  }
  # A partial Job resources block keeps the chart 100Gi default.
  assert {
    condition = yamldecode(output.smithdb_helm_values).smithdb.migration.job.resources == {
      requests = { cpu = "1", memory = "4Gi", "ephemeral-storage" = "10Gi" }
      limits   = { cpu = "2", memory = "8Gi", "ephemeral-storage" = "20Gi" }
    }
    error_message = "SmithDB minimal migration Job resources are not the complete reduced block"
  }
  assert {
    condition     = output.smithdb_metastore_tier == "db-custom-2-8192"
    error_message = "SmithDB minimal did not keep the created metastore on the tier db-custom-2-8192"
  }
}

# The taskdb keeps the chart default resources (2 / 4Gi requests, 4 / 8Gi
# limits). Limits decide the CPU extra: half of 19 CPU, rounded up. Memory is
# 19 GiB from the requests (18.1 GiB, rounded up) and from half of the limits.
run "smithdb_minimal_backfill_keeps_the_chart_taskdb" {
  command = plan

  variables {
    enable_smithdb            = true
    sizing_profile            = "minimum"
    smithdb_ingestion_enabled = true
    smithdb_migration_enabled = true
  }

  assert {
    condition = (
      output.smithdb_quota_extra == { cpu = 10, memory_gi = 19, pods = 20 } &&
      !contains(keys(yamldecode(output.smithdb_helm_values).smithdb.migration), "taskdb")
    )
    error_message = "SmithDB minimal with the backfill sets taskdb resources, or the quota is not 10 CPU / 19 GiB / 20 pods"
  }
}

run "smithdb_minimal_with_local_ssd_is_rejected" {
  command = plan

  variables {
    enable_smithdb        = true
    smithdb_sizing        = "minimal"
    smithdb_cache_storage = "local-ssd"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_network_disk_uses_the_created_storage_class" {
  command = plan

  variables {
    enable_smithdb               = true
    sizing_profile               = "dev"
    smithdb_cache_storage        = "network-disk"
    smithdb_ingestion_enabled    = true
    smithdb_migration_enabled    = true
    smithdb_migration_start_time = "2026-01-01T08:30:00.5+02:00"
  }

  assert {
    condition = output.smithdb_sizing == "small" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "c3-standard-22"
      instance_store_local_ssd_count = 0
      instance_store_disk_size_gb    = 300
      compute_machine_type           = "n2-standard-8"
    } && output.smithdb_quota_extra == { cpu = 37, memory_gi = 90, pods = 20 }
    error_message = "sizing_profile = dev with network-disk did not resolve to small on c3-standard-22, 0 Local SSD, 300 GB, quota 37 CPU / 90 GiB with the backfill"
  }
  assert {
    condition = (
      module.k8s_bootstrap.smithdb_cache_storage_class_name == "smithdb-cache-a1b2c3d4" &&
      yamldecode(output.smithdb_helm_values).smithdb.cache == { storageClassName = "smithdb-cache-a1b2c3d4" } &&
      yamldecode(output.smithdb_helm_values).smithdb.migration.startTime == "2026-01-01T08:30:00.5+02:00" &&
      alltrue([
        for c in ["query", "ingestion", "compactionWorker"] :
        keys(yamldecode(output.smithdb_helm_values).smithdb[c].deployment) == ["nodeSelector", "replicas", "tolerations"] &&
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.replicas == 1 &&
        yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1 } }
      ])
    )
    error_message = "SmithDB network-disk did not select the created StorageClass and the start time, or a cache pod carries more than the pool pins, 1 replica, and an HPA minimum of 1"
  }
}

# N2 cannot attach the Hyperdisk Balanced cache volumes.
run "smithdb_network_disk_on_n2_is_rejected" {
  command = plan

  variables {
    enable_smithdb                      = true
    smithdb_sizing                      = "small"
    smithdb_cache_storage               = "network-disk"
    smithdb_instance_store_machine_type = "n2-standard-16"
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_network_disk_with_local_ssd_is_rejected" {
  command = plan

  variables {
    enable_smithdb                         = true
    smithdb_sizing                         = "small"
    smithdb_cache_storage                  = "network-disk"
    smithdb_instance_store_local_ssd_count = 2
  }

  expect_failures = [terraform_data.validate_inputs]
}

# The 300 GB default passes in smithdb_network_disk_uses_the_created_storage_class.
run "smithdb_network_disk_backfill_on_a_small_boot_disk_is_rejected" {
  command = plan

  variables {
    enable_smithdb                   = true
    smithdb_cache_storage            = "network-disk"
    smithdb_instance_store_disk_size = 100
    smithdb_ingestion_enabled        = true
    smithdb_migration_enabled        = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

# An N2 type with no Local SSD puts the emptyDir cache on the boot disk.
run "smithdb_local_ssd_without_local_ssd_is_rejected" {
  command = plan

  variables {
    enable_smithdb                         = true
    smithdb_cache_storage                  = "local-ssd"
    smithdb_instance_store_local_ssd_count = 0
  }

  expect_failures = [terraform_data.validate_inputs]
}

run "smithdb_sizing_follows_sizing_profile_production" {
  command = plan

  variables {
    enable_smithdb = true
    sizing_profile = "production"
  }

  assert {
    condition = yamldecode(output.smithdb_helm_values).smithdb.resourceTier == "medium" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "n2-standard-32"
      instance_store_local_ssd_count = 4
      instance_store_disk_size_gb    = 100
      compute_machine_type           = "n2-standard-8"
    } && output.smithdb_quota_extra == { cpu = 93, memory_gi = 169, pods = 12 }
    error_message = "sizing_profile = production did not resolve to SmithDB medium on n2-standard-32 with 4 Local SSD, quota 93 CPU / 169 GiB / 12 pods"
  }
  assert {
    condition = alltrue([
      for c in ["query", "ingestion", "compactionWorker"] :
      yamldecode(output.smithdb_helm_values).smithdb[c].deployment.replicas == 1 &&
      yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1 } }
    ])
    error_message = "SmithDB medium local-ssd values do not set 1 replica and an HPA minimum of 1 for query, ingestion, and compactionWorker"
  }
  assert {
    condition     = output.smithdb_metastore_tier == "db-custom-6-32768"
    error_message = "SmithDB medium did not give the created metastore the tier db-custom-6-32768"
  }
}

run "smithdb_medium_network_disk_uses_the_c3_pool" {
  command = plan

  variables {
    enable_smithdb        = true
    sizing_profile        = "production"
    smithdb_cache_storage = "network-disk"
  }

  assert {
    condition = output.smithdb_sizing == "medium" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "c3-standard-44"
      instance_store_local_ssd_count = 0
      instance_store_disk_size_gb    = 300
      compute_machine_type           = "n2-standard-8"
    } && output.smithdb_quota_extra == { cpu = 93, memory_gi = 169, pods = 12 }
    error_message = "sizing_profile = production with network-disk did not resolve to medium on c3-standard-44, 0 Local SSD, 300 GB, quota 93 CPU / 169 GiB / 12 pods"
  }
  assert {
    condition = (
      yamldecode(output.smithdb_helm_values).smithdb.resourceTier == "medium" &&
      yamldecode(output.smithdb_helm_values).smithdb.cache == { storageClassName = "smithdb-cache-a1b2c3d4" } &&
      alltrue([
        for c in ["query", "ingestion", "compactionWorker"] :
        keys(yamldecode(output.smithdb_helm_values).smithdb[c].deployment) == ["nodeSelector", "replicas", "tolerations"] &&
        yamldecode(output.smithdb_helm_values).smithdb[c].deployment.replicas == 1 &&
        yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1 } }
      ])
    )
    error_message = "SmithDB medium network-disk values are not the medium tier on the created StorageClass, with only the pool pins, 1 replica, and an HPA minimum of 1 on each cache pod"
  }
}

# The largest figure: 10 cache pods and 2 compute pods, with the backfill.
# k8s-bootstrap bounds the extra at 1024 CPU and 2048 GiB.
run "smithdb_sizing_follows_sizing_profile_production_large" {
  command = plan

  variables {
    enable_smithdb            = true
    sizing_profile            = "production-large"
    smithdb_ingestion_enabled = true
    smithdb_migration_enabled = true
  }

  assert {
    condition = output.smithdb_sizing == "large" && output.smithdb_cache_storage == "local-ssd" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "n2-standard-64"
      instance_store_local_ssd_count = 8
      instance_store_disk_size_gb    = 100
      compute_machine_type           = "n2-standard-16"
    } && output.smithdb_quota_extra == { cpu = 414, memory_gi = 906, pods = 34 }
    error_message = "sizing_profile = production-large did not resolve to SmithDB large on n2-standard-64 with 8 Local SSD and n2-standard-16 compute, quota 414 CPU / 906 GiB / 34 pods with the backfill"
  }
  assert {
    condition = (
      yamldecode(output.smithdb_helm_values).smithdb.resourceTier == "large" &&
      yamldecode(output.smithdb_helm_values).smithdb.query.autoscaling == { hpa = { minReplicas = 4 } } &&
      yamldecode(output.smithdb_helm_values).smithdb.ingestion.autoscaling == { hpa = { minReplicas = 2 } } &&
      yamldecode(output.smithdb_helm_values).smithdb.compactionWorker.autoscaling == { hpa = { minReplicas = 4 } } &&
      yamldecode(output.smithdb_helm_values).smithdb.query.deployment.replicas == 4 &&
      yamldecode(output.smithdb_helm_values).smithdb.ingestion.deployment.replicas == 2 &&
      yamldecode(output.smithdb_helm_values).smithdb.compactionWorker.deployment.replicas == 4 &&
      !contains(keys(yamldecode(output.smithdb_helm_values).smithdb.compaction), "autoscaling")
    )
    error_message = "SmithDB large values do not set the HPA minimum and the replicas to 4 query, 2 ingestion, and 4 compactionWorker"
  }
  assert {
    condition     = output.smithdb_metastore_tier == "db-custom-10-65536"
    error_message = "SmithDB large did not give the created metastore the tier db-custom-10-65536"
  }
}

# A type that bundles Local SSD takes a count of 0 in local-ssd mode. The
# quota is for large in dual write, and the pool variables do not change it.
run "smithdb_explicit_pool_variables_win_over_the_size" {
  command = plan

  variables {
    enable_smithdb                         = true
    sizing_profile                         = "production-large"
    smithdb_instance_store_machine_type    = "c3-standard-88-lssd"
    smithdb_instance_store_local_ssd_count = 0
    smithdb_instance_store_disk_size       = 150
    smithdb_compute_machine_type           = "n2-standard-32"
  }

  assert {
    condition = output.smithdb_sizing == "large" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "c3-standard-88-lssd"
      instance_store_local_ssd_count = 0
      instance_store_disk_size_gb    = 150
      compute_machine_type           = "n2-standard-32"
    } && output.smithdb_quota_extra == { cpu = 404, memory_gi = 870, pods = 26 }
    error_message = "sizing_profile = production-large did not give large with quota 404 CPU / 870 GiB / 26 pods, or explicit pool variables did not win"
  }
}

# The upgrade pin: smithdb_sizing = "medium" keeps a production-large install on medium.
run "smithdb_explicit_sizing_wins_over_sizing_profile" {
  command = plan

  variables {
    enable_smithdb            = true
    sizing_profile            = "production-large"
    smithdb_sizing            = "medium"
    smithdb_ingestion_enabled = true
    smithdb_migration_enabled = true
  }

  assert {
    condition = output.smithdb_sizing == "medium" && output.smithdb_node_pool_config == {
      instance_store_machine_type    = "n2-standard-32"
      instance_store_local_ssd_count = 4
      instance_store_disk_size_gb    = 100
      compute_machine_type           = "n2-standard-8"
      } && output.smithdb_quota_extra == { cpu = 103, memory_gi = 206, pods = 20 } && alltrue([
        for c in ["query", "ingestion", "compactionWorker"] :
        yamldecode(output.smithdb_helm_values).smithdb[c].autoscaling == { hpa = { minReplicas = 1 } }
    ])
    error_message = "smithdb_sizing = medium did not win over sizing_profile = production-large: n2-standard-32, 4 Local SSD, n2-standard-8 compute, quota 103 CPU / 206 GiB / 20 pods with the backfill, HPA minimum 1"
  }
  # The metastore tier follows the resolved smithdb_sizing, not sizing_profile.
  assert {
    condition     = output.smithdb_metastore_tier == "db-custom-6-32768"
    error_message = "smithdb_sizing = medium with sizing_profile = production-large did not give the created metastore the medium tier db-custom-6-32768"
  }
}

# The metastore upgrade pin: an explicit tier keeps the earlier default on large.
run "smithdb_explicit_metastore_tier_wins_over_the_size" {
  command = plan

  variables {
    enable_smithdb         = true
    sizing_profile         = "production-large"
    smithdb_metastore_tier = "db-custom-2-8192"
  }

  assert {
    condition     = output.smithdb_sizing == "large" && output.smithdb_metastore_tier == "db-custom-2-8192"
    error_message = "smithdb_metastore_tier = db-custom-2-8192 did not win over the large default tier"
  }
}

# ── SmithDB metastore TLS ────────────────────────────────────────────────────
# The created-metastore default (Auth Proxy) is in smithdb_plans_its_own_node_pool.

# No Auth Proxy, so the quota has no sidecar term.
run "smithdb_external_metastore_defaults_to_direct_tls" {
  command = plan

  variables {
    enable_smithdb                      = true
    smithdb_sizing                      = "minimal"
    smithdb_metastore_source            = "external"
    smithdb_external_metastore_host     = "10.0.0.5"
    smithdb_external_metastore_username = "smithdb"
  }

  assert {
    condition = (
      output.smithdb_metastore_use_auth_proxy == false && output.smithdb_metastore_use_ssl == true &&
      output.smithdb_quota_extra.cpu == 5 && output.smithdb_quota_extra.memory_gi == 10
    )
    error_message = "An external SmithDB metastore did not default to direct TLS with no proxy, or the minimal quota is not 5 CPU / 10 GiB without sidecars"
  }
}

# large would give a created metastore db-custom-10-65536. An external
# metastore gets no Cloud SQL instance and no tier.
run "smithdb_external_metastore_ignores_the_size_tier" {
  command = plan

  variables {
    enable_smithdb                      = true
    sizing_profile                      = "production-large"
    smithdb_metastore_source            = "external"
    smithdb_external_metastore_host     = "10.0.0.5"
    smithdb_external_metastore_username = "smithdb"
  }

  assert {
    condition = (
      output.smithdb_sizing == "large" && output.smithdb_metastore_tier == null &&
      output.smithdb_metastore_instance_name == null && output.smithdb_metastore_host == "10.0.0.5"
    )
    error_message = "An external SmithDB metastore got a Cloud SQL instance or a tier, or its host is not the external host"
  }
}

run "smithdb_auth_proxy_on_an_external_metastore_is_rejected" {
  command = plan

  variables {
    enable_smithdb                      = true
    smithdb_metastore_source            = "external"
    smithdb_external_metastore_host     = "10.0.0.5"
    smithdb_external_metastore_username = "smithdb"
    smithdb_metastore_use_auth_proxy    = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

# The earlier default use_ssl = true now meets the default proxy.
run "smithdb_direct_tls_with_the_auth_proxy_is_rejected" {
  command = plan

  variables {
    enable_smithdb            = true
    smithdb_metastore_source  = "create"
    smithdb_metastore_use_ssl = true
  }

  expect_failures = [terraform_data.validate_inputs]
}

# Proxy off with use_ssl unset resolves to direct TLS, which fails with
# UnknownIssuer.
run "smithdb_created_metastore_without_the_proxy_is_rejected" {
  command = plan

  variables {
    enable_smithdb                   = true
    smithdb_metastore_source         = "create"
    smithdb_metastore_use_auth_proxy = false
  }

  expect_failures = [terraform_data.validate_inputs]
}

# A successful plan is the check.
run "smithdb_created_metastore_mode_2_plans" {
  command = plan

  variables {
    enable_smithdb                   = true
    smithdb_metastore_source         = "create"
    smithdb_metastore_use_auth_proxy = false
    smithdb_metastore_use_ssl        = false
    smithdb_metastore_ssl_mode       = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
  }
}

# ── Data plane source switches ───────────────────────────────────────────────
# in-cluster means the chart runs it, so Terraform must plan nothing.

run "external_postgres_is_planned" {
  command = plan

  variables {
    postgres_source = "external"
  }

  assert {
    condition     = length(module.cloudsql) == 1
    error_message = "postgres_source = external did not plan Cloud SQL"
  }
}

run "in_cluster_postgres_plans_nothing" {
  command = plan

  variables {
    postgres_source = "in-cluster"
  }

  assert {
    condition     = length(module.cloudsql) == 0
    error_message = "postgres_source = in-cluster still planned Cloud SQL"
  }
}

run "external_redis_is_planned" {
  command = plan

  variables {
    redis_source = "external"
  }

  assert {
    condition     = length(module.redis) == 1
    error_message = "redis_source = external did not plan Memorystore"
  }
}

run "in_cluster_redis_plans_nothing" {
  command = plan

  variables {
    redis_source = "in-cluster"
  }

  assert {
    condition     = length(module.redis) == 0
    error_message = "redis_source = in-cluster still planned Memorystore"
  }
}
