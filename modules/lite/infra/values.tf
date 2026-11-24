#------------------------------------------------------------------------------
# The Helm values of every release, as data. No credential is in any of them:
# each release reads a Secret by name (bundle.tf), so the values can be read,
# diffed, tested and exported freely (make values, make export).
#------------------------------------------------------------------------------

# Ingress: how Traefik (k3s's own) carries LangSmith in each access mode. localhost and tunnel: plain HTTP
# inside the box, which ssh or the tunnel encrypts. ip: HTTPS with Traefik's self-signed certificate.
# dns: HTTPS with Let's Encrypt.
locals {
  ingress_annotations = {
    localhost = { "traefik.ingress.kubernetes.io/router.entrypoints" = "web" }
    tunnel    = { "traefik.ingress.kubernetes.io/router.entrypoints" = "web" }
    ip = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"         = "true"
    }
    dns = {
      "traefik.ingress.kubernetes.io/router.entrypoints"      = "websecure"
      "traefik.ingress.kubernetes.io/router.tls"              = "true"
      "traefik.ingress.kubernetes.io/router.tls.certresolver" = "le"
    }
  }[var.access]

  # localhost and tunnel take Traefik's Service off the host's ports (ClusterIP); ip and dns keep k3s's
  # servicelb on 80 and 443 and send 80 to 443.
  # Traefik chart 40 (k3s 1.36's) takes the redirect under ports.web.http; make render checks it against
  # the chart k3s bundles, which refused the older ports.web.redirections.
  https_redirect = { ports = { web = { http = { redirections = { entryPoint = { to = "websecure", scheme = "https", permanent = true } } } } } }
  traefik_values = {
    localhost = { service = { type = "ClusterIP" } }
    tunnel    = { service = { type = "ClusterIP" } }
    ip        = local.https_redirect
    dns = merge(local.https_redirect, {
      certificatesResolvers = { le = { acme = { email = var.acme_email, storage = "/data/acme.json", httpChallenge = { entryPoint = "web" } } } }
      # The account and certificates survive a restart, so Let's Encrypt's rate limit is not spent.
      persistence = { enabled = true, size = "128Mi", storageClass = var.storage_class }
    })
  }[var.access]
}

# LangSmith, tracing only.
locals {
  # A service whose feature is off runs no pod: the chart has no switch for playground or ace-backend,
  # and nothing on the tracing path calls either. (Through JSON: a conditional's two branches must
  # otherwise be objects of the same shape.)
  services = ["platformBackend", "ingestQueue", "queue", "playground", "aceBackend"]

  langsmith_values = merge(
    # One replica each, said here: the chart's defaults are 3 platform-backends, 3 ingest-queues and 2
    # backends, which rendered three times the pods the plan sized and fitted (found rendering 0.18.2
    # with Lite's values, 2026-11-24).
    { for c in local.services : c => { deployment = jsondecode(contains(keys(local.k8s), c) ? jsonencode({ replicas = 1, resources = local.k8s[c] }) : jsonencode({ replicas = 0 })) } },
    {
      commonLabels = local.instance_label
      config = {
        existingSecretName   = "langsmith-config"
        authType             = "mixed"
        initialOrgAdminEmail = var.admin_email
        hostname             = local.public_url
        basicAuth            = { enabled = true }
        blobStorage = {
          external             = { enabled = true }
          engine               = "S3"
          bucketName           = local.s3.blobs
          apiURL               = local.s3.endpoint
          s3UsePathStyle       = true
          minBlobStorageSizeKb = tostring(var.blob_min_kb)
        }
        # One pair of TTLs drives LangSmith, SmithDB's long-term retention (the chart reads longlived) and
        # the blob bucket's expiry rules (datastores_values).
        ttl = {
          enabled            = true
          ttl_period_seconds = { longlived = tostring(local.long_ttl * 86400), shortlived = tostring(local.short_ttl * 86400) }
        }
        settings = { redisRunsExpirySeconds = tostring(var.redis_runs_expiry_hours * 3600) }
      }
      backend = {
        # The chart's own CI smoke test: a pod nobody reads here.
        e2eTest    = { enabled = false }
        deployment = { replicas = 1, resources = local.k8s.backend }
      }
      frontend = {
        maxBodySize = "${var.max_payload_mb}M"
        deployment  = { replicas = 1, resources = local.k8s.frontend }
      }
      postgres = { external = { enabled = true, existingSecretName = "langsmith-postgres" } }
      redis    = { external = { enabled = true, existingSecretName = "langsmith-redis" } }
      # Every product beyond tracing off, and ClickHouse, the store SmithDB replaces.
      clickhouse         = { enabled = false }
      insights           = { enabled = false }
      polly              = { enabled = false }
      operator           = { enabled = false }
      fleetToolServer    = { enabled = false }
      fleetTriggerServer = { enabled = false }
      # On a box, k3s's Traefik; on a cluster of one's own, its ingress or gateway, set by its operator.
      ingress = { enabled = var.cloud != "cluster", ingressClassName = "traefik", annotations = local.ingress_annotations }
      smithdb = {
        enabled   = true
        topology  = "unified"
        langsmith = { ingestion = { enabled = true }, query = { enabled = true } }
        config = {
          existingSecretName = "smithdb-config"
          metastore = {
            hostSecretKey     = "smithdb_metastore_host"
            databaseSecretKey = "smithdb_metastore_db"
            usernameSecretKey = "smithdb_metastore_user"
            passwordSecretKey = "smithdb_metastore_password"
          }
          objectStore = {
            type   = "s3"
            bucket = local.s3.smithdb
            s3 = {
              region                   = local.s3.region
              endpoint                 = local.s3.endpoint
              allowHttp                = true
              accessKeyIdSecretKey     = "smithdb_s3_access_key"
              secretAccessKeySecretKey = "smithdb_s3_secret_key"
            }
          }
        }
        unified = { deployment = {
          resources         = local.k8s.smithdb
          priorityClassName = local.stores_priority_class
          # The query cache is disposable: the scratch class, sized from the hot window (the chart's
          # tier would ask 100 GiB). SmithDB keeps it within SMITHDB__DISK_LIMIT, read from this size.
          volumes = [{ name = "cache", ephemeral = { volumeClaimTemplate = { spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = var.scratch_storage_class
            resources        = { requests = { storage = "${local.volumes.smithdb_cache}Gi" } }
          } } } }]
        } }
      }
    },
  )
}

# The stores: the bare-metal module's datastores chart. One Postgres holding LangSmith's database and
# SmithDB's metastore, one Redis, one RustFS with both buckets, at the stores' priority.
locals {
  datastores_values = {
    runtime           = "statefulset"
    storageClass      = var.storage_class
    namespace         = local.ns.data
    createNamespaces  = false
    existingSecrets   = true
    priorityClassName = local.stores_priority_class
    datastoreLabel    = merge({ "langsmith.lab/datastore" = "true" }, local.instance_label)
    # The exporters read the stores from the observability namespace.
    allowedNamespaces = [local.ns.langsmith, local.ns.observe]
    postgres = { instances = {
      langsmith = {
        enabled        = true
        namespace      = local.ns.data
        database       = local.postgres.database
        username       = local.postgres.user
        databases      = [local.postgres.metastore]
        maxConnections = local.postgres_max_connections
        replicas       = 1
        resources      = local.k8s.postgres
        volumeSize     = "${local.volumes.postgres}Gi"
      }
      smithdb = { enabled = false }
    } }
    redis = { instances = {
      langsmith = {
        enabled         = true
        namespace       = local.ns.data
        persistence     = "rdb"
        maxmemoryPolicy = "noeviction"
        replicas        = 1
        # The chart sets maxmemory to three quarters of this limit: the plan's redis_maxmemory_mi.
        resources  = local.k8s.redis
        volumeSize = "${local.volumes.redis}Gi"
      }
      juicefs = { enabled = false }
    } }
    rustfs = {
      enabled    = true
      namespace  = local.ns.data
      buckets    = [local.s3.smithdb, local.s3.blobs]
      ttlBuckets = [local.s3.blobs]
      ttlDays    = { short = local.short_ttl, long = local.long_ttl }
      resources  = local.k8s.rustfs
      volumeSize = "${local.volumes.object_store}Gi"
    }
  }
}

# Observability: Prometheus finds LangSmith's metrics from the chart's own scrape annotations (a second
# values layer, releases.tf) through its default pod job, which also carries every pod label, the
# instance's among them, onto the series. Its other default jobs add the kubelet's cAdvisor and every
# Service annotated prometheus.io/scrape (the two exporters).
locals {
  prometheus_values = {
    alertmanager             = { enabled = false }
    "prometheus-pushgateway" = { enabled = false }
    "kube-state-metrics"     = { resources = try(local.k8s["kube-state-metrics"], null) }
    # Off the host's network: the chart's default served node metrics, unauthenticated, on 9100 of every
    # address the box has.
    "prometheus-node-exporter" = { resources = try(local.k8s["node-exporter"], null), hostNetwork = false }
    server = {
      # Without the chart's web.enable-lifecycle: it let any pod that reached Prometheus shut it down.
      extraFlags = []
      retention  = "${var.prometheus_retention_days}d"
      # And by size: a volume is not a quota, so metrics could otherwise fill the disk.
      retentionSize    = "${floor(local.volumes.prometheus * 0.8)}GB"
      resources        = try(local.k8s.prometheus, null)
      persistentVolume = { enabled = true, size = "${local.volumes.prometheus}Gi", storageClass = var.scratch_storage_class }
      # A Prometheus label name cannot hold the pod label's slash; this one names the instance on every
      # series a shared Prometheus federates.
      global = { scrape_interval = "15s", evaluation_interval = "15s", external_labels = { langsmith_lite_instance = var.name } }
    }
  }
}

locals {
  redis_exporter_values = {
    redisAddress = "redis://${local.redis_host}:6379"
    auth         = { enabled = true, secret = { name = "redis-exporter", key = "password" } }
    resources    = try(local.k8s["redis-exporter"], null)
    service      = { annotations = { "prometheus.io/scrape" = "true", "prometheus.io/port" = "9121" } }
  }

  postgres_exporter_values = {
    config = { datasource = {
      host           = local.postgres.host
      port           = tostring(local.postgres.port)
      user           = local.postgres.user
      database       = local.postgres.database
      sslmode        = "disable"
      passwordSecret = { name = "postgres-exporter", key = "password" }
    } }
    resources = try(local.k8s["postgres-exporter"], null)
    service   = { annotations = { "prometheus.io/scrape" = "true", "prometheus.io/port" = "9187" } }
  }
}

# Grafana: the chart's own dashboard (every SmithDB and LangSmith metric, in depth), three community
# dashboards, and Lite's health dashboard with an alert rule on every signal in health.yaml: SmithDB's
# recommended alerts and the bounds the plan sized. A rule fires at its critical level and shows in
# Grafana's alert list; where it is sent is the operator's to set in Grafana.
locals {
  health = yamldecode(file("${path.module}/health.yaml"))

  # Each signal twice: for its alert, on this install's namespaces; for the dashboard, on the namespaces
  # its picker selects (this install's by default), so one Grafana can show many installs. The data disk's
  # only when the data has a disk of its own.
  dash_ns = { "{ns}|{data}" = "(${"$"}{namespace:regex})(-data)?", "{data}" = "(${"$"}{namespace:regex})-data", "{ns}" = "${"$"}{namespace:regex}" }
  signals = [for sig in local.health.signals : merge(sig, {
    expr      = replace(replace(replace(sig.expr, "{ns}", local.ns.langsmith), "{data}", local.ns.data), "{mount}", local.data_mount)
    dash_expr = replace(replace(replace(replace(sig.expr, "{ns}|{data}", local.dash_ns["{ns}|{data}"]), "{data}", local.dash_ns["{data}"]), "{ns}", local.dash_ns["{ns}"]), "{mount}", local.data_mount)
    guard     = try(replace(sig.guard, "{ns}", local.ns.langsmith), null)
    warn      = try(sig.warn, null)
    crit      = try(sig.crit, null)
  }) if try(sig.when, "") != "data_disk" || local.data_mount != "/"]
  alerting_signals = [for sig in local.signals : sig if sig.crit != null]

  datasource = { name = "prometheus" }
  # Green below the warning level, orange to the critical, red above it.
  steps = { for sig in local.signals : sig.id => concat(
    [{ color = "green", value = null }],
    sig.warn == null ? [] : [{ color = "orange", value = sig.warn }],
    sig.crit == null ? [] : [{ color = "red", value = sig.crit }],
  ) }

  query = { for sig in local.signals : sig.id => { kind = "QueryGroup", spec = { transformations = [], queryOptions = {}, queries = [{ kind = "PanelQuery", spec = {
    refId = "A", hidden = false
    query = { kind = "DataQuery", group = "prometheus", version = "v0", datasource = local.datasource, spec = { expr = sig.dash_expr, legendFormat = "__auto" } }
  } }] } } }

  # One tile a signal on Red flags, coloured by its levels; one graph a signal on its tab, its levels as lines.
  health_elements = merge(
    { intro = { kind = "Panel", spec = {
      id = 1, title = "", description = "", links = [], transparent = true, data = { kind = "QueryGroup", spec = { queries = [], transformations = [], queryOptions = {} } }
      vizConfig = { kind = "VizConfig", group = "text", version = "", spec = { fieldConfig = { defaults = {}, overrides = [] }, options = { mode = "markdown", content = join("", [
        "**${var.name}: red flags.** Green is healthy, orange is the early signal, red fires an alert (Alerting, Alert rules). ",
        "The SmithDB signals and their levels are LangSmith's [recommended SmithDB alerts](https://docs.langchain.com/langsmith/self-host-smithdb-alerts), numbered as there; ",
        "the rest are the bounds Lite's plan sized. Each tab graphs its signals over time, one line an install (the picker above); the LangSmith dashboard has every metric in depth.",
      ]) } } }
    } } },
    # A tile only for a signal with a level: an element no tab places is dropped when Grafana converts the
    # dashboard (it logged "data loss detected" for the throttling tile, 2026-11-24, Grafana 13.3.1).
    { for i, sig in local.alerting_signals : "flag-${sig.id}" => { kind = "Panel", spec = {
      id = 100 + i, title = sig.title, description = sig.action, links = [], transparent = false, data = local.query[sig.id]
      vizConfig = { kind = "VizConfig", group = "stat", version = "", spec = {
        options     = { reduceOptions = { calcs = ["lastNotNull"], fields = "", values = false }, colorMode = "background", graphMode = "area", textMode = "value", justifyMode = "center", orientation = "auto" }
        fieldConfig = { defaults = { unit = sig.unit, decimals = 1, noValue = try(sig.zero_when_absent, false) ? "0" : "not read", color = { mode = "thresholds" }, thresholds = { mode = "absolute", steps = local.steps[sig.id] } }, overrides = [] }
      } }
    } } },
    { for i, sig in local.signals : "graph-${sig.id}" => { kind = "Panel", spec = {
      id = 200 + i, title = sig.title, description = sig.action, links = [], transparent = false, data = local.query[sig.id]
      vizConfig = { kind = "VizConfig", group = "timeseries", version = "", spec = {
        options = { legend = { displayMode = "list", placement = "bottom", showLegend = true }, tooltip = { mode = "multi", sort = "desc" } }
        fieldConfig = { defaults = {
          unit   = sig.unit, min = 0, color = { mode = "fixed", fixedColor = "blue" }, thresholds = { mode = "absolute", steps = local.steps[sig.id] }
          custom = { drawStyle = "line", lineWidth = 2, fillOpacity = 10, gradientMode = "opacity", showPoints = "never", thresholdsStyle = { mode = "dashed" } }
        }, overrides = [] }
      } }
    } } },
  )

  tab_items = { for tab in local.health.tabs : tab => [for i, sig in [for s in local.signals : s if s.tab == tab] : { kind = "GridLayoutItem", spec = {
    x = (i % 2) * 12, y = floor(i / 2) * 8, width = 12, height = 8, element = { kind = "ElementReference", name = "graph-${sig.id}" }
  } }] }

  health_dashboard = {
    apiVersion = "dashboard.grafana.app/v2beta1"
    kind       = "Dashboard"
    metadata   = { name = "lite-health" }
    spec = {
      title       = "LangSmith Lite health"
      description = "Red flags first: SmithDB's recommended alerts and the bounds the plan sized, for ${var.name}."
      annotations = []
      cursorSync  = "Crosshair"
      editable    = true
      links       = []
      preload     = false
      tags        = ["langsmith-lite"]
      # The installs shown: this one by default; every namespace where SmithDB reports, to pick from.
      variables = [{ kind = "QueryVariable", spec = {
        name    = "namespace", label = "Install (namespace)", hide = "dontHide", skipUrlSync = false, refresh = "onTimeRangeChanged", regex = "", options = []
        multi   = true, includeAll = true, allValue = ".*", allowCustomValue = true, sort = "alphabeticalAsc", definition = "label_values(sys_jemalloc_resident_bytes, namespace)"
        current = { text = [local.ns.langsmith], value = [local.ns.langsmith] }
        query   = { kind = "DataQuery", group = "prometheus", version = "v0", datasource = local.datasource, spec = { query = "label_values(sys_jemalloc_resident_bytes, namespace)", refId = "namespace" } }
      } }]
      timeSettings = { timezone = "utc", from = "now-6h", to = "now", autoRefresh = "1m", autoRefreshIntervals = ["30s", "1m", "5m", "15m", "1h"], hideTimepicker = false, fiscalYearStartMonth = 0 }
      elements     = local.health_elements
      layout = { kind = "TabsLayout", spec = { tabs = concat(
        [{ kind = "TabsLayoutTab", spec = { title = "Red flags", layout = { kind = "GridLayout", spec = { items = concat(
          [{ kind = "GridLayoutItem", spec = { x = 0, y = 0, width = 24, height = 3, element = { kind = "ElementReference", name = "intro" } } }],
          [for i, sig in local.alerting_signals : { kind = "GridLayoutItem", spec = {
            x = (i % 4) * 6, y = 3 + floor(i / 4) * 5, width = 6, height = 5, element = { kind = "ElementReference", name = "flag-${sig.id}" }
          } }],
        ) } } } }],
        [for tab in local.health.tabs : { kind = "TabsLayoutTab", spec = { title = tab, layout = { kind = "GridLayout", spec = { items = local.tab_items[tab] } } } }],
      ) } }
    }
  }

  # Grafana's unified alerting, provisioned: one rule a signal with a critical level. A guard (a minimum
  # count) applies to the alert only: the dashboard shows the share at any traffic.
  alert_rules = { apiVersion = 1, groups = [{
    orgId    = 1
    name     = "health"
    folder   = "LangSmith Lite"
    interval = "1m"
    rules = [for sig in local.alerting_signals : {
      uid          = "lite-${sig.id}"
      title        = sig.title
      condition    = "C"
      for          = sig.for
      noDataState  = try(sig.no_data, false) ? "Alerting" : "OK"
      execErrState = "Error"
      labels       = { severity = sig.severity, langsmith_lite_instance = var.name }
      annotations  = { summary = sig.title, description = sig.action, runbook_url = "https://docs.langchain.com/langsmith/self-host-smithdb-alerts" }
      data = [
        { refId = "A", relativeTimeRange = { from = 600, to = 0 }, datasourceUid = "prometheus", model = {
          refId = "A", instant = true, expr = sig.guard == null ? sig.expr : "(${sig.expr}) and on () (${sig.guard})"
        } },
        { refId = "C", datasourceUid = "__expr__", model = { refId = "C", type = "threshold", expression = "A", conditions = [{ evaluator = { type = "gt", params = [sig.crit] } }] } },
      ]
    }]
  }] }

  grafana_values = {
    admin       = { existingSecret = "grafana-admin", userKey = "admin-user", passwordKey = "admin-password" }
    resources   = try(local.k8s.grafana, null)
    persistence = { enabled = false }
    "grafana.ini" = {
      analytics = { reporting_enabled = false, check_for_updates = false }
      server    = { root_url = "http://localhost:3000" }
    }
    datasources = { "datasources.yaml" = { apiVersion = 1, datasources = [{
      name      = "Prometheus"
      type      = "prometheus"
      uid       = "prometheus"
      url       = "http://prometheus-server.${local.ns.observe}.svc.cluster.local"
      access    = "proxy"
      isDefault = true
    }] } }
    dashboardProviders = { "dashboardproviders.yaml" = { apiVersion = 1, providers = [{
      name            = "lite"
      orgId           = 1
      folder          = "LangSmith Lite"
      type            = "file"
      disableDeletion = true
      editable        = true
      options         = { path = "/var/lib/grafana/dashboards/lite" }
    }] } }
    dashboards = { lite = merge(
      { langsmith = { url = local.dashboard_url }, health = { json = jsonencode(local.health_dashboard) } },
      { for name, d in local.pins.dashboards : name => { gnetId = d.id, revision = d.revision, datasource = "Prometheus" } },
    ) }
    alerting = { "rules.yaml" = local.alert_rules }
  }
}

# Mission Control: read-only but for its diagnostics. The features that write (delete pods, patch
# ownership, save drafts, alert config, value overrides, deploy) are off, and with them their RBAC verbs;
# its login is made by Lite (bundle.tf), so it never writes its own auth Secret.
locals {
  mission_control_values = {
    commonLabels = local.instance_label
    images = {
      # Public images: the chart's default regcred pull secret is not needed.
      imagePullSecrets = []
      backendImage     = { tag = local.mission_control_tag }
      frontendImage    = { tag = local.mission_control_tag }
    }
    config = {
      strictReadOnly     = true
      auth               = { enabled = true, existingSecret = "mission-control-auth", jwtSecretKey = "jwt-secret" }
      discoverNamespaces = "${local.ns.langsmith},${local.ns.data}"
      # One switch for every write and disclosure endpoint, and for every write verb in its RBAC: with
      # auth on, the chart otherwise granted a Role create on Secrets, enough to mint a token (security
      # review, 2026-11-24). It also turns off the database tools, discover and chat (which calls out).
      features = { chat = false }
    }
    backend  = { resources = try(local.k8s["mission-control-backend"], null) }
    frontend = { resources = try(local.k8s["mission-control-frontend"], null) }
  }
}
