#------------------------------------------------------------------------------
# What each release is: its chart, its namespace, its values, and the order it
# installs in. The box bundle (bundle.tf) and make export both read this, so a
# box and an install on a cluster of one's own run the same releases.
#------------------------------------------------------------------------------

locals {
  chart_source = {
    for name, c in local.pins.charts : name => { repo = c.repo, chart = c.chart, version = local.chart_version[name] }
  }

  # In install order: the stores before LangSmith, whose migrations need them. A feature that is off has no
  # release at all.
  release_order = concat(
    ["datastores", "langsmith"],
    local.features.observability ? ["prometheus", "grafana", "redis-exporter", "postgres-exporter"] : [],
    local.features.mission_control ? ["mission-control"] : [],
  )

  release_defs = {
    datastores = {
      namespace = local.ns.data
      # The bare-metal module's chart, packaged by make plan: on a box k3s serves it from its static
      # charts folder; make export ships the package beside the values.
      source = { chart = "https://%%{KUBERNETES_API}%/static/charts/${local.datastores_tgz}" }
      values = local.datastores_values
      layer  = ""
    }
    # The chart's own Prometheus scrape annotations ride as a second values layer (pins.yaml).
    langsmith           = { namespace = local.ns.langsmith, source = local.chart_source.langsmith, values = local.langsmith_values, layer = local.scrape_values }
    prometheus          = { namespace = local.ns.observe, source = local.chart_source.prometheus, values = local.prometheus_values, layer = "" }
    grafana             = { namespace = local.ns.observe, source = local.chart_source.grafana, values = local.grafana_values, layer = "" }
    "redis-exporter"    = { namespace = local.ns.observe, source = local.chart_source["redis-exporter"], values = local.redis_exporter_values, layer = "" }
    "postgres-exporter" = { namespace = local.ns.observe, source = local.chart_source["postgres-exporter"], values = local.postgres_exporter_values, layer = "" }
    "mission-control"   = { namespace = local.ns.langsmith, source = local.chart_source["mission-control"], values = local.mission_control_values, layer = "" }
  }
  releases = { for name in local.release_order : name => local.release_defs[name] }

  # Every namespace the releases use, and what they need before any release installs.
  namespaces = concat(
    [
      { name = local.ns.langsmith, labels = local.instance_label },
      # The stores need baseline: Postgres and Redis run as their images' own users.
      { name = local.ns.data, labels = merge(local.instance_label, { "pod-security.kubernetes.io/enforce" = "baseline" }) },
    ],
    local.features.observability ? [{ name = local.ns.observe, labels = local.instance_label }] : [],
    local.features.tunnel ? [{ name = local.ns.tunnel, labels = merge(local.instance_label, { "pod-security.kubernetes.io/enforce" = "restricted" }) }] : [],
  )

  # Every namespace refuses traffic in, but from where it is needed: LangSmith from itself, its
  # observability (scrapes), the tunnel and the ingress controller; observability from itself; the
  # tunnel from nowhere (cloudflared only dials out). The stores'
  # namespace has the datastores chart's own policies (datastores_values.allowedNamespaces). Without these
  # any pod on a shared cluster reached Prometheus, Grafana, Mission Control and LangSmith's services
  # (security review, 2026-11-24). Egress stays open: the pods call the registries and the license server.
  allowed_in = {
    (local.ns.langsmith) = concat([local.ns.langsmith, local.ns.observe, local.ns.tunnel], var.ingress_namespaces)
    (local.ns.observe)   = [local.ns.observe]
    (local.ns.tunnel)    = []
  }
  network_policies = [for ns, from in local.allowed_in : {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "langsmith-lite-ingress", namespace = ns, labels = local.instance_label }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress"]
      # No rule at all, not a rule with no sources: an empty "from" admits everyone.
      ingress = length(from) == 0 ? [] : [{ from = [for n in from : { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = n } } }] }]
    } } if contains([for n in local.namespaces : n.name], ns)
  ]

  cluster_objects = concat(
    [for n in local.namespaces : { apiVersion = "v1", kind = "Namespace", metadata = { name = n.name, labels = n.labels } }],
    [{
      # Above the app's pods, so under memory pressure the kubelet evicts an app pod before a store.
      apiVersion    = "scheduling.k8s.io/v1"
      kind          = "PriorityClass"
      metadata      = { name = local.stores_priority_class }
      value         = 100000
      globalDefault = false
      description   = "LangSmith Lite's stores: Postgres, Redis, RustFS and SmithDB."
    }],
    local.network_policies,
  )
}
