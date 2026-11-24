#------------------------------------------------------------------------------
# What the scripts and the person read. Everything sensitive is marked so: the
# bundle and the logins print only on request (make access).
#------------------------------------------------------------------------------

output "ssh" {
  value       = { host = local.host, user = var.ssh_user != "" ? var.ssh_user : (var.cloud == "aws" ? "ubuntu" : null), port = var.ssh_port }
  description = "Where the scripts reach the box."
}

output "url" {
  value       = local.url
  description = "Where LangSmith answers. localhost: while make access runs."
}

output "plan" {
  value = {
    box             = var.box
    machine         = local.machine
    runs_per_second = local.runs_per_second
    readers         = local.readers
    requested       = local.requested
    allowed         = local.ceiling
    used_pct = {
      cpu    = floor(100 * local.requested.cpu_m / local.ceiling.cpu_m)
      memory = floor(100 * local.requested.mem_mi / local.ceiling.mem_mi)
      disk   = floor(100 * local.disk_needed_gi / local.machine.disk_gi)
    }
    volumes_gi     = local.volumes
    pods           = local.pods
    versions       = merge(local.chart_version, { k3s = local.pins.k3s, mission_control_images = local.mission_control_tag })
    retention_days = { short = var.short_ttl_days, long = var.long_ttl_days, metrics = var.prometheus_retention_days }
  }
  description = "The sizing: every pod's requests and limits, the totals against what the box allows, the volumes and the versions."
}

output "bundle" {
  value       = local.bundle
  sensitive   = true
  description = "Every file the box installs, by name (bundle.tf). Read by make up and make install."
}

output "logins" {
  value = {
    langsmith       = { url = local.url, user = var.admin_email, password = local.secret.admin }
    grafana         = { url = "http://localhost:3000", user = "admin", password = local.secret.grafana_admin }
    mission_control = { url = "http://localhost:3001", user = "admin", password = local.secret.mission_control }
  }
  sensitive   = true
  description = "Every login on the box. make access prints them and opens the tunnels Grafana and Mission Control need."
}

output "values" {
  value = {
    for name, r in local.releases : name => {
      chart     = r.source
      namespace = r.namespace
      values    = r.values
      # A second values layer over values, as helm-controller applies it (langsmith only).
      layer = name == "langsmith" ? local.scrape_values : ""
    }
  }
  description = "Each release's chart and Helm values, with no credential in them: what the box installs, for review (make values) and for make render."
}
