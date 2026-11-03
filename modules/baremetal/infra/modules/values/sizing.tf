#------------------------------------------------------------------------------
# Sizing profiles
#
# One sizing_profile drives every layer:
#   - app pods:   helm/values/examples/langsmith-values-sizing-<file>.yaml (read here,
#                 so the budget uses the exact numbers Helm will deploy)
#   - SmithDB:    resource tier per profile (same mapping as modules/gcp)
#   - datastores: Postgres x2, Redis, RustFS in charts/datastores
#   - add-ons:    metrics-server, local-path, MetalLB, Envoy Gateway
#
# Quantities stay in Kubernetes format ("500m", "2Gi") so the same tables can
# feed the resources later; they're parsed to numbers only for the budget.
#------------------------------------------------------------------------------
locals {
  # lab reuses the dev app sizing; it differs from dev only in its SmithDB tier,
  # which is what lets it fit 6-CPU nodes.
  app_sizing_files = {
    minimum            = "${path.module}/../../../helm/values/examples/langsmith-values-sizing-minimum.yaml"
    lab                = "${path.module}/../../../helm/values/examples/langsmith-values-sizing-dev.yaml"
    dev                = "${path.module}/../../../helm/values/examples/langsmith-values-sizing-dev.yaml"
    production         = "${path.module}/../../../helm/values/examples/langsmith-values-sizing-production.yaml"
    "production-large" = "${path.module}/../../../helm/values/examples/langsmith-values-sizing-production-large.yaml"
  }
  app_values = yamldecode(file(local.app_sizing_files[var.sizing_profile]))
  # The overlay deploy.sh applies last: requests and replica floors set there are what Helm deploys, so
  # the budget counts them over the sizing file's. Without it, requests sized from measurement read as
  # the profile's and the budget refused a cluster they fit.
  values_local_file = var.values_local_file != "" ? var.values_local_file : "${path.module}/../../../helm/values/langsmith-values-local.yaml"
  values_local      = try(yamldecode(file(local.values_local_file)), {})

  # Components the chart runs for a SmithDB-only install with insights/polly off.
  app_components = ["frontend", "backend", "platformBackend", "ingestQueue", "queue", "playground", "aceBackend"]

  # Replicas the scheduler must place up front: the HPA floor when an HPA is on,
  # otherwise the Deployment's replica count.
  app_pods = {
    for c in local.app_components : c => {
      replicas = try(local.values_local[c].autoscaling.hpa.enabled, local.app_values[c].autoscaling.hpa.enabled, false) ? try(local.values_local[c].autoscaling.hpa.minReplicas, local.app_values[c].autoscaling.hpa.minReplicas, 1) : try(local.values_local[c].deployment.replicas, local.app_values[c].deployment.replicas, 1)
      cpu      = tostring(try(local.values_local[c].deployment.resources.requests.cpu, local.app_values[c].deployment.resources.requests.cpu, "0"))
      memory   = tostring(try(local.values_local[c].deployment.resources.requests.memory, local.app_values[c].deployment.resources.requests.memory, "0"))
    }
  }
  # A component without requests in the sizing file would fall back to the
  # chart default, which the budget can't see. budget.tf fails on that.
  app_requests_missing = [
    for c in local.app_components : c
    if !can(local.app_values[c].deployment.resources.requests.cpu) || !can(local.app_values[c].deployment.resources.requests.memory)
  ]

  #----------------------------------------------------------------------------
  # SmithDB tiers. small/medium are the chart tiers (requests = limits); minimal
  # is the tested floor from modules/gcp/infra/locals.tf (limits = 2x requests).
  #----------------------------------------------------------------------------
  smithdb_tier_by_profile = {
    minimum            = "minimal"
    lab                = "minimal"
    dev                = "small"
    production         = "medium"
    "production-large" = "medium"
  }
  smithdb_tiers = {
    minimal = {
      query            = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" }, cache = "20Gi" }
      ingestion        = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" }, cache = "10Gi" }
      compactionWorker = { requests = { cpu = "1", memory = "2Gi" }, limits = { cpu = "2", memory = "4Gi" }, cache = "10Gi" }
      # compaction is only the scheduler: it plans merges, TTL, GC and cleanup,
      # and hands the merges to compactionWorker over gRPC (remote mode).
      # clusterManager only tracks heartbeats and tenant routing in memory.
      # The chart grows both with data volume; at lab volume they idle.
      compaction     = { requests = { cpu = "250m", memory = "512Mi" }, limits = { cpu = "1", memory = "1Gi" }, cache = "0" }
      clusterManager = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "250m", memory = "256Mi" }, cache = "0" }
    }
    small = {
      query            = { requests = { cpu = "4", memory = "8Gi" }, limits = { cpu = "4", memory = "8Gi" }, cache = "200Gi" }
      ingestion        = { requests = { cpu = "4", memory = "8Gi" }, limits = { cpu = "4", memory = "8Gi" }, cache = "100Gi" }
      compactionWorker = { requests = { cpu = "8", memory = "16Gi" }, limits = { cpu = "8", memory = "16Gi" }, cache = "100Gi" }
      compaction       = { requests = { cpu = "2", memory = "4Gi" }, limits = { cpu = "2", memory = "4Gi" }, cache = "0" }
      clusterManager   = { requests = { cpu = "250m", memory = "256Mi" }, limits = { cpu = "250m", memory = "256Mi" }, cache = "0" }
    }
    medium = {
      query            = { requests = { cpu = "28", memory = "48Gi" }, limits = { cpu = "28", memory = "48Gi" }, cache = "200Gi" }
      ingestion        = { requests = { cpu = "16", memory = "32Gi" }, limits = { cpu = "16", memory = "32Gi" }, cache = "100Gi" }
      compactionWorker = { requests = { cpu = "16", memory = "32Gi" }, limits = { cpu = "16", memory = "32Gi" }, cache = "100Gi" }
      compaction       = { requests = { cpu = "4", memory = "8Gi" }, limits = { cpu = "4", memory = "8Gi" }, cache = "0" }
      clusterManager   = { requests = { cpu = "250m", memory = "256Mi" }, limits = { cpu = "250m", memory = "256Mi" }, cache = "0" }
    }
  }
  smithdb_tier_name = var.smithdb_tier != "" ? var.smithdb_tier : local.smithdb_tier_by_profile[var.sizing_profile]
  smithdb_tier      = local.smithdb_tiers[local.smithdb_tier_name]

  #----------------------------------------------------------------------------
  # Datastores this module builds, sized from datastore-sizes.yaml. Sizes are
  # numbers (millicores, MiB, GiB) so feature increments can be added;
  # *_k8s below renders them back to strings.
  #----------------------------------------------------------------------------
  feature_class = contains(["minimum", "lab"], var.sizing_profile) ? "slim" : "full"

  # The tables are data (datastore-sizes.yaml), read as the app's sizing files are: a tool sizing a
  # store outside this module once read them out of this file with a regex, and silently found nothing
  # for lab and dev, whose rows were references.
  datastore_size_table = yamldecode(file("${path.module}/datastore-sizes.yaml"))

  # Products that share postgres-langsmith and redis-langsmith. Same layout as
  # modules/gcp: one logical database per product (langsmith_<name>) on the
  # shared Postgres, and Redis DB 0 LangSmith, 1 Fleet, 2 Polly, 3 Insights.
  redis_db_index = { langsmith = 0, fleet = 1, polly = 2, insights = 3 }
  standalone_feature_flags = {
    fleet = var.enable_fleet
    polly = var.enable_standalone_polly
    # Engine runs on the Insights deployment (docs engine-self-hosted), so it brings that deployment with it.
    insights = var.enable_standalone_insights || var.enable_engine
  }
  standalone_features = { for name, on in local.standalone_feature_flags : name => "langsmith_${name}" if on }
  shared_products = [
    for p, on in {
      polly    = var.enable_standalone_polly
      insights = var.enable_standalone_insights || var.enable_engine
      fleet    = var.enable_fleet
    } : p if on
  ]
  postgres_databases = concat(["langsmith"], values(local.standalone_features))

  # What each extra product adds to the shared instances.
  shared_increment = local.datastore_size_table.shared_increment[local.feature_class]
  n_shared         = length(local.shared_products)

  # The two sizes the load sets rather than the profile (redis_memory_gi, object_store_gi), before
  # the shared products' increments. Without them, the profile's fixed Redis limit capped every
  # install's rate, and the object store's fixed volume told the budget nothing of the retained data.
  datastore_profile = local.datastore_size_table.profiles[var.sizing_profile]
  datastore_sized = merge(local.datastore_profile, {
    redis_langsmith = var.redis_memory_gi == null ? local.datastore_profile.redis_langsmith : merge(local.datastore_profile.redis_langsmith, {
      mem_mi     = ceil(var.redis_memory_gi * 1024)
      lim_mem_mi = ceil(var.redis_memory_gi * 1024)
    })
    rustfs_smithdb = var.object_store_gi == null ? local.datastore_profile.rustfs_smithdb : merge(local.datastore_profile.rustfs_smithdb, {
      storage_gi = ceil(var.object_store_gi)
    })
  })
  datastores_core = {
    for k, d in local.datastore_sized : k => (
      k == "postgres_langsmith" ? merge(d, {
        cpu_m      = d.cpu_m + local.n_shared * local.shared_increment.postgres.cpu_m
        mem_mi     = d.mem_mi + local.n_shared * local.shared_increment.postgres.mem_mi
        lim_mem_mi = d.lim_mem_mi + local.n_shared * local.shared_increment.postgres.mem_mi
        storage_gi = d.storage_gi + local.n_shared * local.shared_increment.postgres.storage_gi
      }) :
      k == "redis_langsmith" ? merge(d, {
        mem_mi     = d.mem_mi + local.n_shared * local.shared_increment.redis.mem_mi
        lim_mem_mi = d.lim_mem_mi + local.n_shared * local.shared_increment.redis.mem_mi
      }) : d
    )
  }
  # Requests measured under load (datastore_requests) replace the whole request, products' increments
  # included, since the measurement saw them; a limit never falls below its request.
  datastores_measured = {
    for k, d in local.datastores_core : k => !contains(keys(var.datastore_requests), k) ? d : merge(d, {
      cpu_m      = var.datastore_requests[k].cpu_m
      mem_mi     = var.datastore_requests[k].mem_mi
      lim_cpu_m  = max(d.lim_cpu_m, var.datastore_requests[k].cpu_m)
      lim_mem_mi = max(d.lim_mem_mi, var.datastore_requests[k].mem_mi)
    })
  }
  # RustFS runs for the in-cluster object store, or, beside the customer's, for the sandboxes' JuiceFS
  # bucket alone: theirs takes SmithDB's segments and the blobs, which grow with every trace.
  rustfs_in_cluster = var.object_store_source == "in-cluster" || var.enable_sandboxes
  # The stores the customer runs (each <store>_source = external): not built, so not counted.
  external_stores = toset(compact([
    var.postgres_source == "external" ? "postgres_langsmith" : "",
    var.redis_source == "external" ? "redis_langsmith" : "",
    var.smithdb_metastore_source == "external" ? "postgres_smithdb" : "",
    local.rustfs_in_cluster ? "" : "rustfs_smithdb",
  ]))
  # The JuiceFS metadata Redis is a datastore like the others, so the budget and its StatefulSet read one size.
  datastores = merge(
    { for k, d in local.datastores_measured : k => d if !contains(local.external_stores, k) },
    var.enable_sandboxes ? { redis_juicefs = local.datastore_size_table.juicefs } : {},
  )
  # The Secrets LangSmith's namespace must hold before Helm runs: ours, or the customer's for a store
  # they run (deploy.sh checks each; the chart fails late without them).
  datastore_secrets = concat(
    [var.postgres_source == "external" ? var.postgres_secret : "langsmith-postgres", var.redis_source == "external" ? var.redis_secret : "langsmith-redis", "smithdb-config"],
    var.postgres_source == "external" ? [for p in keys(local.standalone_features) : "langsmith-${p}-postgres"] : [],
    var.redis_source == "external" ? [for p in keys(local.standalone_features) : "langsmith-${p}-redis"] : [],
    var.smithdb_metastore_source == "external" ? [var.smithdb_metastore_secret] : [],
    var.object_store_source == "external" ? [var.object_store_secret] : [],
  )

  # Kubernetes strings for the resources that will consume these sizes.
  datastores_k8s = {
    for k, d in local.datastores : k => {
      requests = { cpu = "${d.cpu_m}m", memory = "${d.mem_mi}Mi" }
      limits   = { cpu = "${d.lim_cpu_m}m", memory = "${d.lim_mem_mi}Mi" }
      storage  = "${d.storage_gi}Gi"
    }
  }

  #----------------------------------------------------------------------------
  # Feature pods (requests). "full" = chart 0.17.6 defaults / cloud example
  # sizes measured with helm template; "slim" for minimum and lab. Keyed by
  # component so shared ones (host-backend: deployments + fleet) are counted
  # once. Agent Builder is gone: Fleet replaces it.
  #----------------------------------------------------------------------------
  feature_pod_size_tiers = {
    slim = {
      deployments = { "host-backend" = { cpu_m = 100, mem_mi = 256 }, listener = { cpu_m = 250, mem_mi = 512 }, operator = { cpu_m = 100, mem_mi = 128 } }
      fleet       = { "fleet-api-server" = { cpu_m = 250, mem_mi = 512 }, "fleet-queue" = { cpu_m = 250, mem_mi = 512 }, "fleet-tool-server" = { cpu_m = 250, mem_mi = 512 }, "fleet-trigger-server" = { cpu_m = 250, mem_mi = 512 }, "host-backend" = { cpu_m = 100, mem_mi = 256 } }
      insights    = { "insights-api-server" = { cpu_m = 500, mem_mi = 1024 }, "insights-queue" = { cpu_m = 250, mem_mi = 512 } }
      polly       = { "polly-api-server" = { cpu_m = 500, mem_mi = 1024 }, "polly-queue" = { cpu_m = 250, mem_mi = 512 } }
    }
    full = {
      deployments = { "host-backend" = { cpu_m = 200, mem_mi = 1000 }, listener = { cpu_m = 1000, mem_mi = 2048 }, operator = { cpu_m = 1000, mem_mi = 2048 } }
      fleet       = { "fleet-api-server" = { cpu_m = 500, mem_mi = 1024 }, "fleet-queue" = { cpu_m = 500, mem_mi = 1024 }, "fleet-tool-server" = { cpu_m = 1000, mem_mi = 1024 }, "fleet-trigger-server" = { cpu_m = 1000, mem_mi = 2048 }, "host-backend" = { cpu_m = 200, mem_mi = 1000 } }
      insights    = { "insights-api-server" = { cpu_m = 2000, mem_mi = 4096 }, "insights-queue" = { cpu_m = 1000, mem_mi = 2048 } }
      polly       = { "polly-api-server" = { cpu_m = 2000, mem_mi = 4096 }, "polly-queue" = { cpu_m = 1000, mem_mi = 2048 } }
    }
  }
  feature_pod_sizes = local.feature_pod_size_tiers[local.feature_class]
  enabled_features = [
    for f, on in {
      deployments = var.enable_deployments
      fleet       = var.enable_fleet
      insights    = var.enable_standalone_insights || var.enable_engine
      polly       = var.enable_standalone_polly
    } : f if on
  ]
  feature_pods = merge({}, [for f in local.enabled_features : local.feature_pod_sizes[f]]...)
  # The production sizing files give host-backend and listener HPA floors of 2 and 4; one replica undercounted them.
  feature_chart_keys = { "host-backend" = "hostBackend" }
  feature_replicas = {
    for n, _ in local.feature_pods : n => (
      try(local.app_values[lookup(local.feature_chart_keys, n, n)].autoscaling.hpa.enabled, false)
      ? try(local.app_values[lookup(local.feature_chart_keys, n, n)].autoscaling.hpa.minReplicas, 1)
      : try(local.app_values[lookup(local.feature_chart_keys, n, n)].deployment.replicas, 1)
    )
  }

  # Each agent deployment runs an API server, a queue worker, and its own
  # Postgres and Redis, created at runtime by the operator with its own sizes
  # (not the sizing profile). Measured on chart 0.17.11 with operator defaults:
  # agent 200m/512Mi, queue 1/2Gi, Redis 1/2Gi, Postgres 1/3840Mi + 20Gi PVC.
  agent_deployment_estimate = { cpu_m = 3200, mem_mi = 8448, storage_gi = 20 }

  # Platform add-ons (same in every profile). MetalLB's speaker runs on every
  # worker, so its replicas follow the worker count.
  #
  # KEDA scales agent-deployment queue workers on queue depth, so it's installed
  # with Deployments (same rule as modules/gcp: install_keda follows
  # enable_langsmith_deployment). Sizes match the gcp helm_release; the
  # admission webhook sets no requests there, so it's an estimate.
  install_keda = var.enable_deployments
  # Only the add-ons this module installs (platform.tf): a cluster's own are not ours to budget.
  addon_pods = merge(
    var.install_metrics_server ? { "metrics-server" = { replicas = 1, cpu_m = 100, mem_mi = 200 } } : {},
    var.install_local_path ? { "local-path-provisioner" = { replicas = 1, cpu_m = 50, mem_mi = 64 } } : {},
    var.install_metallb ? {
      "metallb-controller" = { replicas = 1, cpu_m = 100, mem_mi = 100 }
      "metallb-speaker"    = { replicas = length(local.workers), cpu_m = 50, mem_mi = 64 }
    } : {},
    var.install_envoy_gateway ? {
      "envoy-gateway" = { replicas = 1, cpu_m = 100, mem_mi = 256 }
      "envoy-proxy"   = { replicas = 1, cpu_m = 200, mem_mi = 256 }
      # Envoy Gateway adds a shutdown-manager sidecar to each proxy pod (drains
      # connections on shutdown). Seen on the live pod: 10m / 32Mi.
      "envoy-proxy-shutdown-manager" = { replicas = 1, cpu_m = 10, mem_mi = 32 }
    } : {},
    var.enable_cloudflare_tunnel ? {
      "cloudflared" = { replicas = 2, cpu_m = 50, mem_mi = 64 }
    } : {},
    local.install_keda ? {
      "keda-operator"       = { replicas = 1, cpu_m = 100, mem_mi = 128 }
      "keda-metrics-server" = { replicas = 1, cpu_m = 100, mem_mi = 128 }
      "keda-webhooks"       = { replicas = 1, cpu_m = 50, mem_mi = 64 }
    } : {},
    # The datastore operators (datastores.tf). CloudNativePG's chart sets no requests; these are the ones its
    # values.yaml suggests. The OpsTree operator's are its chart's own (0.27.0, values.yaml resources).
    local.operator_runtime && length(local.postgres_in_chart) > 0 ? { "cnpg-operator" = { replicas = 1, cpu_m = 100, mem_mi = 100 } } : {},
    local.operator_runtime && length(local.redis_in_chart) > 0 ? { "redis-operator" = { replicas = 1, cpu_m = 500, mem_mi = 500 } } : {},
  )

  #----------------------------------------------------------------------------
  # Node pools. Pods are budgeted against the pool they will schedule on:
  #   workers          everything by default
  #   smithdb-cache    SmithDB query, ingestion, compaction-worker (cache disks)
  #   smithdb-compute  SmithDB compaction, cluster-manager
  # The smithdb pools are optional (the cloud modules' dedicated node pools).
  # With no such nodes, SmithDB shares the workers, as modules/gcp does for the
  # minimal tier.
  #----------------------------------------------------------------------------
  node_pools = {
    # A sandbox node is tainted for sandbox-host alone, so its capacity is not the workers'.
    workers           = { for k, n in var.cluster_nodes : k => n if n.role == "worker" && !contains(local.sandbox_nodes, k) }
    sandbox           = { for k, n in var.cluster_nodes : k => n if contains(local.sandbox_nodes, k) }
    "smithdb-cache"   = { for k, n in var.cluster_nodes : k => n if n.role == "smithdb-cache" }
    "smithdb-compute" = { for k, n in var.cluster_nodes : k => n if n.role == "smithdb-compute" }
  }
  workers                  = local.node_pools.workers
  smithdb_cache_components = ["query", "ingestion", "compactionWorker"]
  smithdb_pool = {
    cache   = length(local.node_pools["smithdb-cache"]) > 0 ? "smithdb-cache" : "workers"
    compute = length(local.node_pools["smithdb-compute"]) > 0 ? "smithdb-compute" : "workers"
  }

  #----------------------------------------------------------------------------
  # Every pod the profile schedules, in one list of numbers:
  # cpu in cores, mem_gi and disk_gi in GiB, plus the pool it lands in.
  #----------------------------------------------------------------------------
  # App and SmithDB sizes arrive as Kubernetes strings ("500m", "2Gi").
  string_pods = concat(
    [for c, p in local.app_pods : { name = "app/${c}", pool = "workers", replicas = p.replicas, cpu = p.cpu, memory = p.memory, disk = "0" }],
    [
      for c, s in(var.enable_smithdb ? local.smithdb_tier : {}) : {
        name     = "smithdb/${c}"
        pool     = contains(local.smithdb_cache_components, c) ? local.smithdb_pool.cache : local.smithdb_pool.compute
        replicas = try(local.values_local.smithdb[c].autoscaling.hpa.minReplicas, local.values_local.smithdb[c].deployment.replicas, 1)
        cpu      = tostring(try(local.values_local.smithdb[c].deployment.resources.requests.cpu, s.requests.cpu))
        memory   = tostring(try(local.values_local.smithdb[c].deployment.resources.requests.memory, s.requests.memory))
        disk     = s.cache
      }
    ],
    local.trace_store_pods,
    local.sandbox_pods,
  )
  pods_parsed = concat(
    [
      for p in local.string_pods : {
        name     = p.name
        pool     = p.pool
        replicas = p.replicas
        cpu_n    = endswith(p.cpu, "m") ? tonumber(trimsuffix(p.cpu, "m")) / 1000 : tonumber(p.cpu)
        mem_gi   = endswith(p.memory, "Gi") ? tonumber(trimsuffix(p.memory, "Gi")) : endswith(p.memory, "Mi") ? tonumber(trimsuffix(p.memory, "Mi")) / 1024 : tonumber(p.memory) / 1073741824
        disk_gi  = endswith(p.disk, "Gi") ? tonumber(trimsuffix(p.disk, "Gi")) : endswith(p.disk, "Mi") ? tonumber(trimsuffix(p.disk, "Mi")) / 1024 : tonumber(p.disk) / 1073741824
      }
    ],
    # Each replica has its own volume, so the disk counts once per pod too.
    [for n, d in local.datastores : { name = "datastore/${local.datastore_instance_names[n]}", pool = "workers", replicas = local.datastore_pod_replicas[n], cpu_n = d.cpu_m / 1000, mem_gi = d.mem_mi / 1024, disk_gi = d.storage_gi }],
    local.sentinel_pods,
    [for n, f in local.feature_pods : { name = "feature/${n}", pool = "workers", replicas = local.feature_replicas[n], cpu_n = f.cpu_m / 1000, mem_gi = f.mem_mi / 1024, disk_gi = 0 }],
    [for n, a in local.addon_pods : { name = "addon/${n}", pool = "workers", replicas = a.replicas, cpu_n = a.cpu_m / 1000, mem_gi = a.mem_mi / 1024, disk_gi = 0 }],
    var.expected_agent_deployments > 0 ? [{
      name     = "agents/estimate-per-deployment"
      pool     = "workers"
      replicas = var.expected_agent_deployments
      cpu_n    = local.agent_deployment_estimate.cpu_m / 1000
      mem_gi   = local.agent_deployment_estimate.mem_mi / 1024
      disk_gi  = local.agent_deployment_estimate.storage_gi
    }] : [],
  )

  #----------------------------------------------------------------------------
  # Budget per pool: what its pods ask for vs what its nodes can give.
  # control-plane nodes are in no pool.
  #----------------------------------------------------------------------------
  pool_pods = {
    for pool, nodes in local.node_pools : pool => [for p in local.pods_parsed : p if p.pool == pool]
    if length(nodes) > 0
  }
  pool_stats = {
    for pool, pods in local.pool_pods : pool => {
      nodes            = length(local.node_pools[pool])
      requested_cpu    = length(pods) > 0 ? sum([for p in pods : p.cpu_n * p.replicas]) : 0
      requested_mem_gi = length(pods) > 0 ? sum([for p in pods : p.mem_gi * p.replicas]) : 0
      requested_disk   = length(pods) > 0 ? sum([for p in pods : p.disk_gi * p.replicas]) : 0
      ceiling_cpu      = sum([for n in values(local.node_pools[pool]) : n.cpu - var.node_reserved.cpu]) * var.max_request_ratio
      ceiling_mem_gi   = sum([for n in values(local.node_pools[pool]) : n.memory_gi - var.node_reserved.memory_gi]) * var.max_request_ratio
      ceiling_disk     = sum([for n in values(local.node_pools[pool]) : n.disk_gi]) * var.max_request_ratio
      # A pod must fit on a single node, whatever the pool total.
      largest_pod_cpu  = length(pods) > 0 ? max([for p in pods : p.cpu_n]...) : 0
      largest_pod_mem  = length(pods) > 0 ? max([for p in pods : p.mem_gi]...) : 0
      largest_pod_disk = length(pods) > 0 ? max([for p in pods : p.disk_gi]...) : 0
      largest_cpu_pod  = length(pods) > 0 ? [for p in pods : p.name if p.cpu_n == max([for q in pods : q.cpu_n]...)][0] : "-"
      largest_mem_pod  = length(pods) > 0 ? [for p in pods : p.name if p.mem_gi == max([for q in pods : q.mem_gi]...)][0] : "-"
      largest_disk_pod = length(pods) > 0 ? [for p in pods : p.name if p.disk_gi == max([for q in pods : q.disk_gi]...)][0] : "-"
      largest_node_cpu = max([for n in values(local.node_pools[pool]) : n.cpu]...)
      largest_node_mem = max([for n in values(local.node_pools[pool]) : n.memory_gi]...)
      largest_node_dsk = max([for n in values(local.node_pools[pool]) : n.disk_gi]...)
    }
  }

  # Scheduling for the SmithDB Helm values: the cloud modules' label/taint keys
  # when a dedicated pool exists, otherwise nothing (share the workers).
  smithdb_scheduling = {
    for kind, pool in local.smithdb_pool : kind => pool == "workers" ? null : {
      node_selector = { (local.smithdb_node_label[pool]) = "true" }
      tolerations   = [{ key = local.smithdb_node_label[pool], operator = "Equal", value = "true", effect = "NoSchedule" }]
    }
  }

  budget_summary = {
    sizing_profile     = var.sizing_profile
    smithdb_tier       = local.smithdb_tier_name
    smithdb_pools      = local.smithdb_pool
    features           = local.enabled_features
    keda               = local.install_keda
    agent_deployments  = var.expected_agent_deployments
    postgres_databases = local.postgres_databases
    # Top-level numbers are the workers pool, where LangSmith itself runs.
    requested = { cpu = floor(local.pool_stats.workers.requested_cpu * 100) / 100, memory_gi = floor(local.pool_stats.workers.requested_mem_gi * 100) / 100, disk_gi = ceil(local.pool_stats.workers.requested_disk) }
    ceiling   = { cpu = floor(local.pool_stats.workers.ceiling_cpu * 100) / 100, memory_gi = floor(local.pool_stats.workers.ceiling_mem_gi * 100) / 100, disk_gi = floor(local.pool_stats.workers.ceiling_disk) }
    used_pct = {
      cpu    = floor(local.pool_stats.workers.requested_cpu / local.pool_stats.workers.ceiling_cpu * 100)
      memory = floor(local.pool_stats.workers.requested_mem_gi / local.pool_stats.workers.ceiling_mem_gi * 100)
      disk   = floor(local.pool_stats.workers.requested_disk / local.pool_stats.workers.ceiling_disk * 100)
    }
    largest_pod = {
      cpu    = "${local.pool_stats.workers.largest_cpu_pod} (${local.pool_stats.workers.largest_pod_cpu} CPU; biggest worker ${local.pool_stats.workers.largest_node_cpu})"
      memory = "${local.pool_stats.workers.largest_mem_pod} (${local.pool_stats.workers.largest_pod_mem} Gi; biggest worker ${local.pool_stats.workers.largest_node_mem} Gi)"
    }
    pools = {
      for pool, st in local.pool_stats : pool => {
        nodes     = st.nodes
        requested = { cpu = floor(st.requested_cpu * 100) / 100, memory_gi = floor(st.requested_mem_gi * 100) / 100, disk_gi = ceil(st.requested_disk) }
        ceiling   = { cpu = floor(st.ceiling_cpu * 100) / 100, memory_gi = floor(st.ceiling_mem_gi * 100) / 100, disk_gi = floor(st.ceiling_disk) }
      }
    }
  }
}

# The label and NoSchedule taint key of each dedicated SmithDB pool, as the cloud modules put them on
# their SmithDB node pools; the root labels and taints the nodes given those roles.
locals {
  smithdb_node_label = {
    "smithdb-cache"   = "smithdb-local/instance-store"
    "smithdb-compute" = "smithdb-local/compute"
  }
  smithdb_dedicated_nodes = {
    for name, n in var.cluster_nodes : name => local.smithdb_node_label[n.role]
    if contains(keys(local.smithdb_node_label), n.role)
  }
}
