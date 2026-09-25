# Locals - Centralized naming conventions and computed values
# This ensures consistent naming across all resources and prevents collisions

locals {
  #----------------------------------------------------------------------------
  # Naming Convention
  # Format: {prefix}-{environment}-{resource_type}-{suffix}
  # Example: myco-prod-vpc-a1b2c3d4
  #----------------------------------------------------------------------------

  # Random suffix for uniqueness (only if enabled)
  suffix = var.unique_suffix ? "-${random_id.suffix.hex}" : ""

  # Base name used as prefix for all resources
  base_name = "${var.name_prefix}-${var.environment}"

  #----------------------------------------------------------------------------
  # Resource Names (all derived from base_name)
  #----------------------------------------------------------------------------

  # Networking
  vpc_name    = "${local.base_name}-vpc"
  subnet_name = "${local.base_name}-subnet"
  router_name = "${local.base_name}-router"
  nat_name    = "${local.base_name}-nat"

  # GKE
  cluster_name                    = "${local.base_name}-gke"
  node_pool_name                  = "${local.base_name}-nodepool"
  sandbox_host_node_sa_account_id = "${local.base_name}-sbox-node"
  sandbox_host_node_sa_project_roles = toset([
    "roles/container.defaultNodeServiceAccount",
    "roles/monitoring.metricWriter",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  # Cloud SQL
  postgres_instance_name = "${local.base_name}-pg${local.suffix}"
  postgres_database_name = "langsmith"
  postgres_user_name     = "langsmith"

  # Redis
  redis_instance_name                 = "${local.base_name}-redis${local.suffix}"
  sandbox_juicefs_redis_instance_name = "${local.base_name}-jfs-redis${local.suffix}"

  # Storage
  bucket_name = "${var.project_id}-${local.base_name}-traces${local.suffix}"

  # SmithDB (optional, enable_smithdb)
  smithdb_name                    = "${local.base_name}-smithdb"
  smithdb_metastore_instance_name = "${local.base_name}-smithdb-pg${local.suffix}"
  smithdb_bucket_name             = var.smithdb_bucket_name != "" ? var.smithdb_bucket_name : "${var.project_id}-${local.base_name}-smithdb${local.suffix}"

  #----------------------------------------------------------------------------
  # SmithDB sizing. One size and one cache mode set the node pool shapes, the
  # namespace quota headroom, and the smithdb_helm_values output.
  #----------------------------------------------------------------------------
  smithdb_sizing_by_profile = {
    minimum            = "minimal"
    dev                = "small"
    default            = "small"
    production         = "medium"
    "production-large" = "large"
  }

  smithdb_sizing        = coalesce(var.smithdb_sizing, local.smithdb_sizing_by_profile[var.sizing_profile])
  smithdb_minimal       = local.smithdb_sizing == "minimal"
  smithdb_cache_storage = coalesce(var.smithdb_cache_storage, local.smithdb_minimal ? "network-disk" : "local-ssd")
  smithdb_network_disk  = local.smithdb_cache_storage == "network-disk"

  # The chart has the small, medium, and large tiers. minimal uses small with
  # explicit resources, and runs on the general node pool.
  smithdb_resource_tier   = local.smithdb_minimal ? "small" : local.smithdb_sizing
  smithdb_dedicated_pools = var.enable_smithdb && !var.gke_use_autopilot && !local.smithdb_minimal

  # Per-replica resources and cache size for each chart tier. Copied from chart
  # 0.17.0-rc.42, templates/_helpers.tpl, "langsmith.smithdb.tierResources".
  # The chart sets requests equal to limits. Update this table with the chart.
  smithdb_tiers = {
    small = {
      query            = { cpu = "4", memory = "8Gi", cache = "200Gi" }
      ingestion        = { cpu = "4", memory = "8Gi", cache = "100Gi" }
      compactionWorker = { cpu = "8", memory = "16Gi", cache = "100Gi" }
      compaction       = { cpu = "2", memory = "4Gi" }
      clusterManager   = { cpu = "250m", memory = "256Mi" }
    }
    medium = {
      query            = { cpu = "28", memory = "48Gi", cache = "200Gi" }
      ingestion        = { cpu = "16", memory = "32Gi", cache = "100Gi" }
      compactionWorker = { cpu = "16", memory = "32Gi", cache = "100Gi" }
      compaction       = { cpu = "4", memory = "8Gi" }
      clusterManager   = { cpu = "250m", memory = "256Mi" }
    }
    large = {
      query            = { cpu = "28", memory = "50Gi", cache = "1000Gi" }
      ingestion        = { cpu = "56", memory = "150Gi", cache = "1000Gi" }
      compactionWorker = { cpu = "28", memory = "50Gi", cache = "300Gi" }
      compaction       = { cpu = "8", memory = "16Gi" }
      clusterManager   = { cpu = "2", memory = "2Gi" }
    }
  }
  smithdb_tier = local.smithdb_tiers[local.smithdb_resource_tier]

  # Replicas for each tier, from the SmithDB sizing table in the LangSmith
  # self-hosted docs (small: 10 ingest / 10 query QPS, medium: 100 / 40, large:
  # 1000 / 100). The chart tier sets only the per-replica resources, so the
  # values set these counts as the HPA minReplicas of the three cache
  # components. compaction and clusterManager have no HPA and one replica.
  smithdb_tier_replicas = {
    small  = { query = 1, ingestion = 1, compactionWorker = 1, compaction = 1, clusterManager = 1 }
    medium = { query = 1, ingestion = 1, compactionWorker = 1, compaction = 1, clusterManager = 1 }
    large  = { query = 4, ingestion = 2, compactionWorker = 4, compaction = 1, clusterManager = 1 }
  }
  smithdb_replicas = local.smithdb_tier_replicas[local.smithdb_resource_tier]

  # Components with a cache run on the cache pool, the others on the compute pool.
  smithdb_cache_components   = ["query", "ingestion", "compactionWorker"]
  smithdb_compute_components = ["compaction", "clusterManager"]

  # minimal: explicit resources, limits 2x requests. A partial resources block
  # keeps the chart default for each key that it omits. The chart Job default
  # has 100Gi of ephemeral-storage, so the Job block sets every key.
  # The taskdb keeps the chart default resources.
  smithdb_minimal_resources = {
    query            = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } }
    ingestion        = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } }
    compactionWorker = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" } }
    compaction       = { requests = { cpu = "500m", memory = "1Gi" }, limits = { cpu = "1", memory = "2Gi" } }
    clusterManager   = { requests = { cpu = "250m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    migration_job = {
      requests = { cpu = "1", memory = "4Gi", "ephemeral-storage" = "10Gi" }
      limits   = { cpu = "2", memory = "8Gi", "ephemeral-storage" = "20Gi" }
    }
  }

  # Default node pool shapes. An explicit smithdb_* pool variable wins.
  smithdb_pool_defaults = {
    small  = { local_ssd_type = "n2-standard-16", local_ssd_count = 2, network_disk_type = "c3-standard-22", compute_type = "n2-standard-8" }
    medium = { local_ssd_type = "n2-standard-32", local_ssd_count = 4, network_disk_type = "c3-standard-44", compute_type = "n2-standard-8" }
    large  = { local_ssd_type = "n2-standard-64", local_ssd_count = 8, network_disk_type = "c3-standard-88", compute_type = "n2-standard-16" }
  }
  smithdb_pool_default = local.smithdb_pool_defaults[local.smithdb_resource_tier]

  smithdb_instance_store_machine_type = coalesce(
    var.smithdb_instance_store_machine_type,
    local.smithdb_network_disk ? local.smithdb_pool_default.network_disk_type : local.smithdb_pool_default.local_ssd_type,
  )
  smithdb_instance_store_local_ssd_count = coalesce(
    var.smithdb_instance_store_local_ssd_count,
    local.smithdb_network_disk ? 0 : local.smithdb_pool_default.local_ssd_count,
  )
  # network-disk: the backfill Job takes 100Gi of ephemeral storage from the
  # boot disk, and a 200 GB boot disk has only about 97 GiB allocatable.
  smithdb_instance_store_disk_size = coalesce(var.smithdb_instance_store_disk_size, local.smithdb_network_disk ? 300 : 100)
  smithdb_compute_machine_type     = coalesce(var.smithdb_compute_machine_type, local.smithdb_pool_default.compute_type)

  # Default Cloud SQL tier of a created metastore, for each size. The docs
  # section "Metastore capacity" (langsmith/self-host-smithdb-scale) gives a
  # dedicated metastore 2 vCPU / 16 GiB for small, 4 / 32 for medium, and 8 / 64
  # for large. A custom tier has at most 6.5 GB for each vCPU and an even vCPU
  # count, so each tier has more vCPU than the docs to get the docs memory.
  # minimal keeps the earlier default. An explicit smithdb_metastore_tier wins.
  # An external metastore does not use the tier.
  smithdb_metastore_tier_defaults = {
    minimal = "db-custom-2-8192"
    small   = "db-custom-4-16384"
    medium  = "db-custom-6-32768"
    large   = "db-custom-10-65536"
  }
  smithdb_metastore_tier = coalesce(var.smithdb_metastore_tier, local.smithdb_metastore_tier_defaults[local.smithdb_sizing])

  # network-disk with dedicated pools: k8s-bootstrap creates a Hyperdisk
  # Balanced class (cluster-scoped, so with the suffix). minimal uses the GKE
  # built-in standard-rwo class.
  smithdb_create_cache_storage_class = local.smithdb_dedicated_pools && local.smithdb_network_disk
  smithdb_cache_storage_class        = local.smithdb_minimal ? "standard-rwo" : "smithdb-cache${local.suffix}"

  # With SmithDB off, the proxy is off, so the metastore TLS variables have no
  # effect and the preconditions in main.tf do not reject them.
  smithdb_metastore_use_auth_proxy = var.enable_smithdb && coalesce(var.smithdb_metastore_use_auth_proxy, var.smithdb_metastore_source == "create")
  smithdb_metastore_use_ssl        = coalesce(var.smithdb_metastore_use_ssl, !local.smithdb_metastore_use_auth_proxy)

  #----------------------------------------------------------------------------
  # SmithDB namespace quota headroom, from the resolved resources. It covers:
  # - the tier replicas of each component (smithdb_replicas);
  # - one surge copy of the largest pod (a rolling update starts the new pod first);
  # - an Auth Proxy sidecar per pod when the proxy is on;
  # - with the backfill, the migration Job and the taskdb.
  # HPA scale-out above the tier replicas has only the surge room.
  # CPU is in millicores and memory in MiB, so the sums are exact.
  #----------------------------------------------------------------------------
  smithdb_quota_inputs = merge(
    {
      for c, t in local.smithdb_tier : c => local.smithdb_minimal ? local.smithdb_minimal_resources[c] : {
        requests = { cpu = t.cpu, memory = t.memory }
        limits   = { cpu = t.cpu, memory = t.memory }
      }
    },
    {
      # Chart values.yaml defaults for smithdb.migration.job.resources and
      # smithdb.migration.taskdb.postgres.statefulSet.resources.
      migration_job = local.smithdb_minimal ? local.smithdb_minimal_resources.migration_job : {
        requests = { cpu = "8", memory = "32Gi", "ephemeral-storage" = "100Gi" }
        limits   = { cpu = "8", memory = "32Gi", "ephemeral-storage" = "100Gi" }
      }
      taskdb = {
        requests = { cpu = "2", memory = "4Gi" }
        limits   = { cpu = "4", memory = "8Gi" }
      }
      # The sidecar that helm/scripts/init-values.sh adds. Keep the two copies the same.
      auth_proxy = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    },
  )

  # "250m" and "4" to millicores, "256Mi" and "8Gi" to MiB.
  smithdb_quota_numbers = {
    for name, r in local.smithdb_quota_inputs : name => merge([
      for side in ["requests", "limits"] : {
        "${side}_cpu_m"     = tonumber(trimsuffix(r[side].cpu, "m")) * (endswith(r[side].cpu, "m") ? 1 : 1000)
        "${side}_memory_mi" = tonumber(trimsuffix(trimsuffix(r[side].memory, "Gi"), "Mi")) * (endswith(r[side].memory, "Gi") ? 1024 : 1)
      }
    ]...)
  }
  smithdb_quota_keys = ["requests_cpu_m", "limits_cpu_m", "requests_memory_mi", "limits_memory_mi"]
  smithdb_quota_sidecar = {
    for k in local.smithdb_quota_keys : k => local.smithdb_metastore_use_auth_proxy ? local.smithdb_quota_numbers.auth_proxy[k] : 0
  }
  smithdb_quota_total = {
    for k in local.smithdb_quota_keys : k => (
      sum([for c in keys(local.smithdb_tier) : local.smithdb_replicas[c] * (local.smithdb_quota_numbers[c][k] + local.smithdb_quota_sidecar[k])]) +
      max([for c in keys(local.smithdb_tier) : local.smithdb_quota_numbers[c][k]]...) + local.smithdb_quota_sidecar[k] +
      (var.smithdb_migration_enabled ? local.smithdb_quota_numbers.migration_job[k] + local.smithdb_quota_sidecar[k] + local.smithdb_quota_numbers.taskdb[k] : 0)
    )
  }

  # k8s-bootstrap adds the extra once to requests and twice to limits, so it
  # must cover the requests total and half of the limits total.
  smithdb_quota_extra_cpu = var.enable_smithdb ? max(
    ceil(local.smithdb_quota_total.requests_cpu_m / 1000), ceil(local.smithdb_quota_total.limits_cpu_m / 2000)
  ) : 0
  smithdb_quota_extra_memory_gi = var.enable_smithdb ? max(
    ceil(local.smithdb_quota_total.requests_memory_mi / 1024), ceil(local.smithdb_quota_total.limits_memory_mi / 2048)
  ) : 0

  # The SmithDB pods at the tier replicas plus the metastore migration hook,
  # doubled for rolling-update surge. The backfill adds 8 for the migration Job
  # and its taskdb StatefulSet. With one replica each, this gives 12, or 20
  # with the backfill.
  smithdb_quota_extra_pods = var.enable_smithdb ? (
    2 * (sum(values(local.smithdb_replicas)) + 1) + (var.smithdb_migration_enabled ? 8 : 0)
  ) : 0

  #----------------------------------------------------------------------------
  # SmithDB Helm values (output smithdb_helm_values). init-values.sh writes them
  # to helm/values/langsmith-values-smithdb-sizing.yaml.
  #----------------------------------------------------------------------------
  smithdb_pin_cache_pool = {
    nodeSelector = { "smithdb-local/instance-store" = "true" }
    tolerations  = [{ key = "smithdb-local/instance-store", operator = "Equal", value = "true", effect = "NoSchedule" }]
  }
  smithdb_pin_compute_pool = {
    nodeSelector = { "smithdb-local/compute" = "true" }
    tolerations  = [{ key = "smithdb-local/compute", operator = "Equal", value = "true", effect = "NoSchedule" }]
  }
  smithdb_start_time_values = var.smithdb_migration_start_time != "" ? { startTime = var.smithdb_migration_start_time } : {}

  # Values for small, medium, and large. The backfill Job goes to the cache
  # pool, which has room for its 100Gi ephemeral-storage request, and the taskdb
  # goes to the compute pool. Each cache component gets the tier replicas as
  # its HPA minReplicas, and keeps the chart maxReplicas (10). The tier
  # replicas also go to deployment.replicas. The chart uses that field only
  # when the HPA is off.
  smithdb_values_cache_autoscaling = {
    for c in local.smithdb_cache_components : c => { hpa = { minReplicas = local.smithdb_replicas[c] } }
  }
  smithdb_values_cache_deployment = {
    for c in local.smithdb_cache_components : c => merge(local.smithdb_pin_cache_pool, { replicas = local.smithdb_replicas[c] })
  }
  smithdb_values_pools_common = merge(
    { resourceTier = local.smithdb_resource_tier },
    { for c in local.smithdb_compute_components : c => { deployment = local.smithdb_pin_compute_pool } },
    {
      migration = merge(local.smithdb_start_time_values, {
        job    = local.smithdb_pin_cache_pool
        taskdb = { postgres = { statefulSet = local.smithdb_pin_compute_pool } }
      })
    },
  )

  # local-ssd: each cache is an emptyDir on node Local SSD. The chart needs
  # limits.ephemeral-storage for an emptyDir cache. Explicit resources replace
  # the tier, so cpu and memory repeat the tier values.
  smithdb_values_local_ssd = {
    smithdb = merge(local.smithdb_values_pools_common, {
      for c in local.smithdb_cache_components : c => {
        deployment = merge(local.smithdb_values_cache_deployment[c], {
          resources = {
            for side in ["requests", "limits"] : side => {
              cpu = local.smithdb_tier[c].cpu, memory = local.smithdb_tier[c].memory, "ephemeral-storage" = local.smithdb_tier[c].cache
            }
          }
          volumes = [{ name = "cache", emptyDir = { sizeLimit = local.smithdb_tier[c].cache } }]
        })
        autoscaling = local.smithdb_values_cache_autoscaling[c]
      }
    })
  }

  # network-disk: the chart makes a per-pod cache volume from the StorageClass,
  # sized from the tier.
  smithdb_values_network_disk = {
    smithdb = merge(
      local.smithdb_values_pools_common,
      { cache = { storageClassName = local.smithdb_cache_storage_class } },
      {
        for c in local.smithdb_cache_components : c => {
          deployment  = local.smithdb_values_cache_deployment[c]
          autoscaling = local.smithdb_values_cache_autoscaling[c]
        }
      },
    )
  }

  # minimal: no node pins, the explicit resources, and one replica for each
  # autoscaled component (chart autoscaling.hpa keys).
  smithdb_values_minimal = {
    smithdb = merge(
      { resourceTier = "small", cache = { storageClassName = local.smithdb_cache_storage_class } },
      {
        for c in local.smithdb_cache_components : c => {
          deployment  = { resources = local.smithdb_minimal_resources[c] }
          autoscaling = { hpa = { minReplicas = 1, maxReplicas = 1 } }
        }
      },
      { for c in local.smithdb_compute_components : c => { deployment = { resources = local.smithdb_minimal_resources[c] } } },
      {
        migration = merge(local.smithdb_start_time_values, {
          job = { resources = local.smithdb_minimal_resources.migration_job }
        })
      },
    )
  }

  smithdb_helm_values = !var.enable_smithdb ? null : (
    local.smithdb_minimal ? yamlencode(local.smithdb_values_minimal) :
    local.smithdb_network_disk ? yamlencode(local.smithdb_values_network_disk) : yamlencode(local.smithdb_values_local_ssd)
  )

  #----------------------------------------------------------------------------
  # Common Labels (applied to all resources)
  #----------------------------------------------------------------------------
  common_labels = merge(
    {
      # Standard labels
      "app"         = "langsmith"
      "environment" = var.environment
      "managed-by"  = "terraform"
      "project"     = var.project_id
      "name-prefix" = var.name_prefix

      # Optional labels (only if provided)
      "owner" = var.owner
    },
    # Add cost center if provided
    var.cost_center != "" ? { "cost-center" = var.cost_center } : {},
    # Merge custom labels
    var.labels
  )

  #----------------------------------------------------------------------------
  # Computed Values
  #----------------------------------------------------------------------------

  #----------------------------------------------------------------------------
  # Feature Flags
  #----------------------------------------------------------------------------
}
