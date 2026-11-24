#------------------------------------------------------------------------------
# Every pod's requests and limits, and whether they fit the box. No cluster is
# read: the plan sizes the box before it exists. Data in sizes.yaml, method in
# SIZING.md.
#------------------------------------------------------------------------------

locals {
  sizes   = yamldecode(file("${path.module}/sizes.yaml"))
  preset  = local.sizes.boxes[var.box]
  machine = var.machine != null ? var.machine : local.preset.machine

  runs_per_second = coalesce(var.runs_per_second, local.preset.design.runs_per_second)
  readers         = coalesce(var.readers, local.preset.design.readers)
  work = {
    offered   = local.runs_per_second
    processed = local.runs_per_second
    readers   = local.readers
    fixed     = 0
  }

  model = local.sizes.model
  # LangSmith's pods from the measured model: (idle + per unit x work) x headroom, never below the floor.
  app_pods = {
    for name, w in local.model.workloads : name => {
      cpu_m  = max(local.model.min_cpu_m, ceil((w.base + w.per_unit * local.work[w.work]) * local.model.headroom * 1000))
      mem_mi = w.mem_mi
      # Past the measured rates the model can ask more than the usual limit; a limit below its request
      # is refused by Kubernetes, so the limit rises with it.
      lim_cpu_m  = max(w.lim_cpu_m, ceil((w.base + w.per_unit * local.work[w.work]) * local.model.headroom * 1000))
      lim_mem_mi = max(w.mem_mi * local.model.mem_limit_factor, w.mem_mi + local.model.mem_limit_floor_mi)
    }
  }

  # The stores and SmithDB at the preset's sizes; their volumes are counted apart.
  store_pods = {
    for name in ["smithdb", "postgres", "redis", "rustfs"] : name => {
      cpu_m      = local.preset[name].cpu_m
      mem_mi     = local.preset[name].mem_mi
      lim_cpu_m  = local.preset[name].lim_cpu_m
      lim_mem_mi = local.preset[name].lim_mem_mi
    }
  }

  # cloudflared runs only for a tunnel.
  fixed_pods = { for name, p in local.sizes.fixed : name => p if name != "cloudflared" || var.access == "tunnel" }

  # An override replaces a pod's whole size, so a measured request never mixes with a modelled limit.
  pods_sized        = merge(local.app_pods, local.store_pods, local.fixed_pods)
  pods              = { for name, p in local.pods_sized : name => lookup(var.resources, name, p) }
  unknown_overrides = [for name in keys(var.resources) : name if !contains(keys(local.pods_sized), name)]

  volumes = {
    postgres      = coalesce(var.volumes.postgres_gi, local.preset.postgres.volume_gi)
    redis         = coalesce(var.volumes.redis_gi, local.preset.redis.volume_gi)
    object_store  = coalesce(var.volumes.object_store_gi, local.preset.rustfs.volume_gi)
    smithdb_cache = coalesce(var.volumes.smithdb_cache_gi, local.preset.smithdb.cache_gi)
    prometheus    = coalesce(var.volumes.prometheus_gi, local.preset.prometheus.volume_gi)
  }

  # What the kubelet offers once k3s and the OS keep theirs, and the share the pods may request.
  allocatable = {
    cpu_m  = local.machine.cpu * 1000 - local.preset.reserved.cpu_m
    mem_mi = local.machine.memory_gi * 1024 - local.preset.reserved.mem_mi
  }
  ceiling = {
    cpu_m  = floor(local.allocatable.cpu_m * var.max_request_ratio)
    mem_mi = floor(local.allocatable.mem_mi * var.max_request_ratio)
  }
  # An upgrade's hook Jobs (the migrations) run one at a time beside every pod for a minute or two;
  # the room max_request_ratio leaves above the requests holds them, so no chart's Job size is copied here.
  requested = {
    cpu_m  = sum([for p in values(local.pods) : p.cpu_m])
    mem_mi = sum([for p in values(local.pods) : p.mem_mi])
  }
  disk_needed_gi = sum(values(local.volumes)) + local.sizes.disk_overhead_gi

  fit = {
    cpu  = local.requested.cpu_m <= local.ceiling.cpu_m
    mem  = local.requested.mem_mi <= local.ceiling.mem_mi
    disk = local.disk_needed_gi <= local.machine.disk_gi
  }
  fit_problems = compact([
    local.fit.cpu ? "" : "the pods request ${local.requested.cpu_m}m CPU; the box allows ${local.ceiling.cpu_m}m ((${local.machine.cpu} vCPU - ${local.preset.reserved.cpu_m}m reserved) x ${var.max_request_ratio})",
    local.fit.mem ? "" : "the pods request ${local.requested.mem_mi}Mi memory; the box allows ${local.ceiling.mem_mi}Mi ((${local.machine.memory_gi} GiB - ${local.preset.reserved.mem_mi}Mi reserved) x ${var.max_request_ratio})",
    local.fit.disk ? "" : "the volumes and images need ${local.disk_needed_gi} GiB of disk; the box has ${local.machine.disk_gi}",
  ])

  # Kubernetes quantities for the charts.
  k8s = {
    for name, p in local.pods : name => {
      requests = { cpu = "${p.cpu_m}m", memory = "${p.mem_mi}Mi" }
      limits = merge(
        { memory = "${p.lim_mem_mi}Mi" },
        p.lim_cpu_m > 0 ? { cpu = "${p.lim_cpu_m}m" } : {},
      )
    }
  }
}
