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

  # Namespace quota headroom for SmithDB. The chart sets SmithDB requests equal
  # to limits, so these are exact rather than estimates.
  #
  # Steady state (chart 0.16.x defaults), per replica:
  #   query 4 CPU / 8Gi, ingestion 4 / 8, compactionWorker 4 / 8,
  #   compaction 2 / 4, clusterManager 250m / 256Mi   = 14.25 CPU / 28.25Gi
  # Auth Proxy sidecar adds 100m / 128Mi to each of those five pods. A native
  # sidecar counts toward the pod total rather than folding into the
  # init-container maximum, so it is 500m / 640Mi, not zero.
  #
  # A rolling upgrade then needs a second copy of the largest pod alive at once
  # while the old one drains, which is another 4.1 CPU / 8.125Gi. Without that
  # surge allowance an upgrade wedges: the replacement pod is refused, so the
  # old pod never terminates, and Helm waits on a rollout that cannot progress.
  smithdb_quota_steady_cpu       = 15 # 14.25 steady + 0.5 sidecars, rounded up
  smithdb_quota_steady_memory_gi = 29 # 28.25 steady + 0.625 sidecars, rounded up
  smithdb_quota_surge_cpu        = 5  # one extra 4 CPU pod + its sidecar
  smithdb_quota_surge_memory_gi  = 9  # one extra 8Gi pod + its sidecar

  # The one-shot ClickHouse backfill Job: 8 CPU / 16Gi plus its own Auth Proxy
  # sidecar. It also brings an in-chart taskdb Postgres StatefulSet.
  smithdb_quota_migration_cpu       = 9
  smithdb_quota_migration_memory_gi = 18

  smithdb_quota_extra_cpu = var.enable_smithdb ? (
    local.smithdb_quota_steady_cpu + local.smithdb_quota_surge_cpu +
    (var.smithdb_migration_enabled ? local.smithdb_quota_migration_cpu : 0)
  ) : 0

  smithdb_quota_extra_memory_gi = var.enable_smithdb ? (
    local.smithdb_quota_steady_memory_gi + local.smithdb_quota_surge_memory_gi +
    (var.smithdb_migration_enabled ? local.smithdb_quota_migration_memory_gi : 0)
  ) : 0

  # Five SmithDB Deployments, the metastore migration hook, and during the
  # backfill the migration Job plus its taskdb StatefulSet. Doubled to leave
  # room for rolling-update surge across all of them.
  smithdb_quota_extra_pods = var.enable_smithdb ? (var.smithdb_migration_enabled ? 20 : 12) : 0

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
