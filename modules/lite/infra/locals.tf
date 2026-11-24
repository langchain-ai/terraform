#------------------------------------------------------------------------------
# Versions, namespaces, addresses and the URL LangSmith answers on.
#------------------------------------------------------------------------------

locals {
  pins = yamldecode(file("${path.module}/pins.yaml"))

  # The exact version each chart line resolved to (lib/versions.sh, at every make plan); the line itself in the offline
  # tests, which helm-controller would also accept but which would let the box resolve later than the plan.
  chart_version = {
    for name, c in local.pins.charts : name => try(var.resolved.charts[name], c.version)
  }
  # The official dashboard at the release tag of the chart that runs; the line's base in the tests.
  langsmith_release = trimprefix(local.chart_version.langsmith, "~")
  dashboard_url     = replace(local.pins.observability.dashboard, "{release}", local.langsmith_release)
  # The chart's own scrape annotations (examples/langsmith-observability/components/smithdb/
  # prometheus-values.yaml at the installed release), applied as a second values layer: the chart's
  # maintainers keep its metrics ports, not Lite. Empty in the offline tests.
  scrape_values       = try(var.resolved.scrape_values, "")
  mission_control_tag = try(var.resolved.app_versions["mission-control"], trimprefix(local.chart_version["mission-control"], "~"))

  # The datastores chart is the bare-metal module's, packaged at every make plan under a name that carries a
  # digest of its files, so any change to it is a new chart URL and helm-controller upgrades it.
  datastores_tgz = try("datastores-${var.resolved.charts.datastores}.tgz", "datastores.tgz")

  # One install's namespaces, from its name unless given, so many installs can share a cluster (make
  # export). cloudflared, the one pod that takes requests from the internet, runs apart from the stores.
  namespace = coalesce(var.namespace, var.name)
  ns = {
    langsmith = local.namespace
    data      = "${local.namespace}-data"
    observe   = "${local.namespace}-observe"
    tunnel    = "${local.namespace}-tunnel"
  }

  # On every object Lite makes, so a fleet can find, watch and account each install by its name.
  instance_label = { "langsmith-lite/instance" = var.name }
  # Cluster-scoped, so named for the install: one install's make down must not remove another's.
  stores_priority_class = "langsmith-lite-stores-${var.name}"

  # Where every store's volume lives on the box: an AWS data volume is mounted at k3s's own storage folder;
  # a bare-metal data_path is given to k3s as that folder; otherwise the root filesystem holds them.
  data_mount = var.cloud == "aws" ? "/var/lib/rancher/k3s/storage" : var.data_path != "" ? var.data_path : "/"

  # Each store at the address the datastores chart gives it (its README, "Two runtimes, one interface").
  postgres = {
    host     = "postgres-langsmith.${local.ns.data}.svc.cluster.local"
    port     = 5432
    user     = "langsmith"
    database = "langsmith"
    # SmithDB's metastore is a second database on the same Postgres: one box runs one Postgres.
    metastore = "smithdb_metastore"
  }
  redis_host = "redis-langsmith.${local.ns.data}.svc.cluster.local"
  s3 = {
    endpoint = "http://rustfs.${local.ns.data}.svc.cluster.local:9000"
    region   = "us-east-1"
    smithdb  = "smithdb"
    blobs    = "langsmith-blobs"
  }

  # The URL LangSmith redirects to and the ingress host. localhost and ip have no name: the chart then
  # renders a rule for every host, and an Ingress host cannot be an address anyway.
  named_access = contains(["dns", "tunnel"], var.access)
  public_url   = local.named_access ? "https://${var.domain}" : ""
  url = {
    localhost = "http://localhost:8080"
    ip        = "https://${local.host}"
    dns       = "https://${var.domain}"
    tunnel    = "https://${var.domain}"
  }[var.access]
}
