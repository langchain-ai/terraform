#------------------------------------------------------------------------------
# Every pod, every volume, what the box costs, and whether it fits. Each block
# is a block of SIZING.md's computation, in its order and under its names. No
# cluster is read: the plan sizes the box before it exists. Data: sizes.yaml.
#------------------------------------------------------------------------------

locals {
  sizes   = yamldecode(file("${path.module}/sizes.yaml"))
  preset  = local.sizes.boxes[var.box]
  machine = var.machine != null ? var.machine : local.preset.machine

  peak    = coalesce(var.runs_per_second, local.preset.design.runs_per_second)
  readers = coalesce(var.readers, local.preset.design.readers)

  # Retention has defaults, but every plan says when they are in use (summary.py, retention).
  short_ttl     = coalesce(var.short_ttl_days, 14)
  long_ttl      = coalesce(var.long_ttl_days, 30)
  retention_set = var.short_ttl_days != null && var.long_ttl_days != null

  features = {
    code_evaluators = var.code_evaluators
    # On a cluster of one's own both are off unless asked for: several installs sharing a cluster would
    # collide on their cluster-wide roles, and a fleet watches its installs from one stack.
    observability   = coalesce(var.observability, var.cloud == "cluster" ? false : local.preset.features.observability)
    mission_control = coalesce(var.mission_control, var.cloud == "cluster" ? false : local.preset.features.mission_control)
    tunnel          = var.cloud != "cluster" && var.access == "tunnel"
    k3s             = var.cloud != "cluster"
  }
}

# SIZING.md's computation, pods: LangSmith's services from the measured model.
locals {
  model = local.sizes.model
  work  = { offered = local.peak, processed = local.peak, readers = local.readers, fixed = 0 }
  service_pods = {
    for name, w in local.model.workloads : name => {
      cpu_m  = max(local.model.min_cpu_m, ceil((w.base + w.per_unit * local.work[w.work]) * local.model.headroom * 1000))
      mem_mi = ceil(w.mem_mi * local.model.mem_headroom)
      # Past the measured rates a request can exceed the usual limit, which Kubernetes refuses, so the
      # limit rises with it.
      lim_cpu_m  = max(w.lim_cpu_m, ceil((w.base + w.per_unit * local.work[w.work]) * local.model.headroom * 1000))
      lim_mem_mi = max(ceil(w.mem_mi * local.model.mem_headroom) * local.model.mem_limit_factor, ceil(w.mem_mi * local.model.mem_headroom) + local.model.mem_limit_floor_mi)
    } if try(local.features[w.feature], true)
  }
  fixed_pods = { for name, p in local.sizes.fixed : name => p if local.features[p.feature] }
}

# SIZING.md's computation, what a run costs: decimal KB in each store, weighted by the payload mix. Attachments go to
# the blob bucket.
locals {
  st        = local.sizes.storage
  mix       = var.payload_mix_pct != null ? var.payload_mix_pct : local.st.mix_pct
  mix_total = local.mix.small + local.mix.medium + local.mix.large
  kb = {
    for store in ["smithdb", "blob", "redis"] : store => sum([
      for size in ["small", "medium", "large"] : local.mix[size] * local.st["${store}_kb"][size]
    ]) / local.mix_total + (store == "blob" ? var.attachment_kib_per_run * 1.024 : 0)
  }
}

# SIZING.md's computation, volumes: storage fills at the average rate and keeps each run for its TTL.
locals {
  runs_a_day   = local.peak / local.st.peak_factor * 86400
  extended     = var.extended_retention_pct / 100
  smithdb_days = (1 - local.extended) * (local.short_ttl + local.st.smithdb_delete_lag_days) + local.extended * (local.long_ttl + local.st.smithdb_delete_lag_days)
  blob_days    = (1 - local.extended) * local.short_ttl + local.extended * local.long_ttl
  gib          = pow(1024, 3)

  object_store_gi  = ceil(local.runs_a_day * 1000 * (local.kb.smithdb * local.smithdb_days + local.kb.blob * local.blob_days) * var.storage_factor * local.st.headroom / local.gib)
  smithdb_cache_gi = max(local.st.cache_min_gi, ceil(local.runs_a_day * 1000 * local.kb.smithdb * var.query_hot_days * local.st.headroom / local.gib))

  rd                 = local.sizes.redis
  redis_maxmemory_mi = max(local.rd.min_maxmemory_mi, ceil(local.peak * local.kb.redis * 1000 * var.redis_runs_expiry_hours * 3600 * local.rd.headroom / pow(1024, 2)))
  redis_limit_mi     = ceil(local.redis_maxmemory_mi / local.rd.maxmemory_share)

  volumes = {
    object_store  = coalesce(var.volumes.object_store_gi, local.object_store_gi)
    smithdb_cache = coalesce(var.volumes.smithdb_cache_gi, local.smithdb_cache_gi)
    redis         = coalesce(var.volumes.redis_gi, ceil(local.redis_maxmemory_mi / 1024))
    postgres      = coalesce(var.volumes.postgres_gi, local.preset.postgres.volume_gi)
    prometheus    = local.features.observability ? coalesce(var.volumes.prometheus_gi, local.preset.prometheus.volume_gi) : 0
  }
  volumes_gi = sum(values(local.volumes))
}

# SIZING.md's computation, the stores: Redis and Postgres reserve their memory (request equals limit);
# SmithDB and RustFS ask what they use and may burst. All four run at the stores' priority.
locals {
  pg                       = local.sizes.postgres
  postgres_connections     = 2 * local.pg.pool_api_pod + 2 * local.pg.pool_worker_pod + local.pg.others
  postgres_max_connections = coalesce(var.postgres_max_connections, max(local.pg.min_connections, ceil(local.postgres_connections / local.pg.budget / local.pg.round_to) * local.pg.round_to))

  store_pods = {
    smithdb  = local.preset.smithdb
    rustfs   = local.preset.rustfs
    postgres = merge(local.preset.postgres, { lim_mem_mi = local.preset.postgres.mem_mi })
    redis    = { cpu_m = local.rd.cpu_m, mem_mi = local.redis_limit_mi, lim_cpu_m = local.rd.lim_cpu_m, lim_mem_mi = local.redis_limit_mi }
  }

  # A measured size replaces a pod's whole size, so a measured request never mixes with a modelled limit.
  pods_sized        = merge(local.service_pods, { for k, v in local.store_pods : k => { cpu_m = v.cpu_m, mem_mi = v.mem_mi, lim_cpu_m = v.lim_cpu_m, lim_mem_mi = v.lim_mem_mi } }, { for k, v in local.fixed_pods : k => { cpu_m = v.cpu_m, mem_mi = v.mem_mi, lim_cpu_m = v.lim_cpu_m, lim_mem_mi = v.lim_mem_mi } })
  pods              = { for name, p in local.pods_sized : name => lookup(var.resources, name, p) }
  unknown_overrides = [for name in keys(var.resources) : name if !contains(keys(local.pods_sized), name)]
}

# SIZING.md's computation, the fit. Requests within the share of the machine pods may ask; the volumes on the data disk
# (or with the system on one disk); a single machine only up to the measured single-machine range.
locals {
  allocatable = {
    cpu_m  = local.machine.cpu * 1000 - local.preset.reserved.cpu_m
    mem_mi = local.machine.memory_gi * 1024 - local.preset.reserved.mem_mi
  }
  allowed = {
    cpu_m  = floor(local.allocatable.cpu_m * var.max_request_ratio)
    mem_mi = floor(local.allocatable.mem_mi * var.max_request_ratio)
  }
  requested = {
    cpu_m  = sum([for p in values(local.pods) : p.cpu_m])
    mem_mi = sum([for p in values(local.pods) : p.mem_mi])
  }

  # Where the volumes live: on AWS a data volume of their own; on bare metal data_path if set; else the
  # system's disk.
  data_disk_separate = var.cloud == "aws" || var.data_path != ""
  fill               = local.sizes.disk_fill_max
  data_disk_gi = (
    var.cloud == "aws" ? coalesce(var.data_disk_gi, ceil(local.volumes_gi / local.fill / 10) * 10) :
    var.data_path != "" ? try(local.machine.data_disk_gi, 0) : 0
  )
  system_disk_gi = var.cloud == "aws" ? local.sizes.system_disk_gi : local.machine.disk_gi

  max_peak = local.sizes.single_machine_max_runs_per_second
  # On a cluster of one's own there is no machine to fit: the cluster's scheduler places the pods. The
  # one-replica shape still holds only to the single-machine range.
  machine_fit = var.cloud != "cluster"
  fit_problems = compact([
    !local.machine_fit || local.requested.cpu_m <= local.allowed.cpu_m ? "" : "the pods request ${local.requested.cpu_m}m CPU; the machine allows ${local.allowed.cpu_m}m ((${local.machine.cpu} vCPU - ${local.preset.reserved.cpu_m}m reserved) x ${var.max_request_ratio})",
    !local.machine_fit || local.requested.mem_mi <= local.allowed.mem_mi ? "" : "the pods request ${local.requested.mem_mi}Mi memory; the machine allows ${local.allowed.mem_mi}Mi ((${local.machine.memory_gi} GiB - ${local.preset.reserved.mem_mi}Mi reserved) x ${var.max_request_ratio})",
    !local.machine_fit ? "" : local.data_disk_separate ? (
      local.volumes_gi <= local.data_disk_gi * local.fill ? "" : "the volumes need ${local.volumes_gi} GiB, which may fill the data disk to ${local.fill * 100}%: it needs ${ceil(local.volumes_gi / local.fill)} GiB, and has ${local.data_disk_gi}${var.data_path != "" ? " (machine.data_disk_gi)" : ""}"
      ) : (
      local.volumes_gi + local.sizes.system_disk_gi <= local.machine.disk_gi * local.fill ? "" : "the volumes and the system need ${local.volumes_gi + local.sizes.system_disk_gi} GiB, which may fill the disk to ${local.fill * 100}%: it needs ${ceil((local.volumes_gi + local.sizes.system_disk_gi) / local.fill)} GiB, and has ${local.machine.disk_gi} (the object store alone ${local.volumes.object_store} GiB for ${floor(local.runs_a_day)} runs a day kept ${local.short_ttl} days)"
    ),
    local.peak <= local.max_peak ? "" : "${local.peak} runs/s is past what one machine was measured to hold (${local.max_peak} runs/s at peak): that is a full deployment, a cloud module (../aws, ../gcp, ../azure)",
  ])

  k8s = {
    for name, p in local.pods : name => {
      requests = { cpu = "${p.cpu_m}m", memory = "${p.mem_mi}Mi" }
      limits   = merge({ memory = "${p.lim_mem_mi}Mi" }, p.lim_cpu_m > 0 ? { cpu = "${p.lim_cpu_m}m" } : {})
    }
  }
}

# SIZING.md, The cost: what the box costs a month on AWS's list prices.
locals {
  prices       = local.sizes.aws_prices
  aws_instance = var.aws_instance_type != "" ? var.aws_instance_type : local.preset.aws
  aws_hourly   = coalesce(var.aws_hourly_usd, lookup(local.prices.instance_hourly_usd, local.aws_instance, null), 0)
  cost_usd_a_month = {
    instance = local.aws_hourly * local.prices.hours_a_month
    disks    = (local.sizes.system_disk_gi + local.data_disk_gi) * local.prices.gp3_gb_month_usd
    # Snapshots are incremental: the first holds the data in use, the rest what changed. The volumes'
    # planned size is the bound.
    snapshots = var.backup_snapshot_days > 0 ? local.volumes_gi * local.prices.snapshot_gb_month_usd : 0
    address   = local.prices.public_ipv4_hourly_usd * local.prices.hours_a_month
  }
}
