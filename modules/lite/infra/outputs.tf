#------------------------------------------------------------------------------
# What the commands and the person read, and what a system running many
# instances reads: every output is plain data, keyed the same for every box.
# The bundle, the export and the logins are sensitive.
#------------------------------------------------------------------------------

output "instance" {
  value = {
    name      = var.name
    cloud     = var.cloud
    box       = var.box
    namespace = local.ns.langsmith
    label     = local.instance_label
  }
  description = "Which install this is: its name, where it runs, and the label on every object it makes."
}

output "ssh" {
  value       = { host = local.host, user = var.ssh_user != "" ? var.ssh_user : (var.cloud == "aws" ? "ubuntu" : null), port = var.ssh_port, host_key = try(module.aws[0].host_public_key, null) }
  description = "Where the commands reach the box."
}

output "url" {
  value       = local.url
  description = "Where LangSmith answers. localhost: while make access runs."
}

output "namespaces" {
  value       = local.ns
  description = "The install's namespaces."
}

output "plan" {
  value = {
    box             = var.box
    machine         = local.machine
    runs_per_second = local.peak
    readers         = local.readers
    requested       = local.requested
    allowed         = local.allowed
    used_pct = {
      cpu    = floor(100 * local.requested.cpu_m / local.allowed.cpu_m)
      memory = floor(100 * local.requested.mem_mi / local.allowed.mem_mi)
    }
    disks = {
      system_gi     = local.system_disk_gi
      data_gi       = local.data_disk_gi
      data_separate = local.data_disk_separate
      data_mount    = local.data_mount
      volumes_gi    = local.volumes_gi
      used_pct      = local.data_disk_separate ? floor(100 * local.volumes_gi / max(local.data_disk_gi, 1)) : floor(100 * (local.volumes_gi + local.sizes.system_disk_gi) / local.machine.disk_gi)
      snapshot_days = var.cloud == "aws" ? var.backup_snapshot_days : 0
    }
    volumes_gi = local.volumes
    data = {
      runs_a_day               = floor(local.runs_a_day)
      kb_a_run                 = local.kb
      redis_maxmemory_mi       = local.redis_maxmemory_mi
      redis_stall_hours        = var.redis_runs_expiry_hours
      postgres_max_connections = local.postgres_max_connections
    }
    retention = {
      short_days    = local.short_ttl
      long_days     = local.long_ttl
      extended_pct  = var.extended_retention_pct
      metrics_days  = var.prometheus_retention_days
      set_by_person = local.retention_set
    }
    features = local.features
    pods     = local.pods
    releases = local.release_order
    cost_usd_a_month = var.cloud == "aws" ? merge(local.cost_usd_a_month, {
      total         = ceil(sum(values(local.cost_usd_a_month)))
      instance_type = local.aws_instance
    }) : null
    versions = merge(local.chart_version, { k3s = local.pins.k3s, mission_control_images = local.mission_control_tag })
  }
  description = "The sizing: every pod, the totals against what the machine allows, the disks and volumes, the data a box keeps, the retention, the features, the cost on AWS and the versions."
}

output "values" {
  value = {
    for name, r in local.releases : name => { chart = r.source, namespace = r.namespace, values = r.values, layer = r.layer }
  }
  description = "Each release's chart and Helm values, in install order, with no credential: what the box installs (make values) and make export writes."
}

output "bundle" {
  value       = local.bundle
  sensitive   = true
  description = "Every file a k3s box installs, by name (bundle.tf). Read by make up."
}

output "export" {
  value = {
    order          = local.release_order
    cluster_yaml   = join("", [for d in local.cluster_objects : "---\n${yamlencode(d)}"])
    secrets_yaml   = local.secrets_yaml
    datastores_tgz = local.datastores_tgz
  }
  sensitive   = true
  description = "What make export writes for a cluster of one's own, beside the values: the namespaces and priority class, and the Secrets."
}

output "logins" {
  value = merge(
    { langsmith = { url = local.url, user = var.admin_email, password = local.secret.admin } },
    local.features.observability ? { grafana = { url = "http://localhost:3000", user = "admin", password = local.secret.grafana_admin } } : {},
    local.features.mission_control ? { mission_control = { url = "http://localhost:3001", user = "admin", password = local.secret.mission_control } } : {},
  )
  sensitive   = true
  description = "Every login on the box. make access prints them and opens the tunnels to the UIs that run."
}

output "data_volume_id" {
  value       = try(module.aws[0].data_volume_id, "")
  description = "cloud = aws: the data volume, which make preflight checks is attached."
}

output "box" {
  value = {
    k3s_version    = local.pins.k3s
    k3s_config     = local.k3s_config
    traefik_values = local.traefik_values
    releases       = local.release_order
    # The objects made before any release, by kind, namespace and name: what to look for on a box.
    objects = [for o in local.box_objects : "${o.kind}/${try(o.metadata.namespace, "-")}/${o.metadata.name}"]
  }
  description = "What a k3s box gets beside the releases: k3s's version and config, Traefik's settings (make render checks them against k3s's bundled Traefik chart), and the objects made before any release."
}
