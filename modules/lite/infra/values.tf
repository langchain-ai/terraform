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
    { for c in local.services : c => { deployment = jsondecode(contains(keys(local.k8s), c) ? jsonencode({ resources = local.k8s[c] }) : jsonencode({ replicas = 0 })) } },
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
        deployment = { resources = local.k8s.backend }
      }
      frontend = {
        maxBodySize = "${var.max_payload_mb}M"
        deployment  = { resources = local.k8s.frontend }
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
      retention = "${var.prometheus_retention_days}d"
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

# Grafana: the chart's dashboard and three community dashboards, and Lite's own capacity dashboard with an
# alert rule on every bound the plan sized (SIZING.md, each store). A rule fires at 80% of its bound and
# shows in Grafana's alert list; where it is sent is the operator's to set in Grafana.
locals {
  ns_regex = join("|", [local.ns.langsmith, local.ns.data, local.ns.observe])

  # Each bound: what is used over what it may use, as one PromQL expression per row.
  # The data disk's row only when the data has a disk of its own; otherwise the system disk's row is it.
  bounds = merge(local.data_mount == "/" ? {} : {
    data_disk = {
      title = "Data disk used"
      expr  = "1 - node_filesystem_avail_bytes{mountpoint=\"${local.data_mount}\"} / node_filesystem_size_bytes{mountpoint=\"${local.data_mount}\"}"
    }
    }, {
    system_disk = {
      title = "System disk used"
      expr  = "1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}"
    }
    redis_memory = {
      title = "Redis memory of maxmemory"
      expr  = "max(redis_memory_used_bytes) / max(redis_memory_max_bytes)"
    }
    postgres_connections = {
      title = "Postgres connections of max_connections"
      expr  = "sum(pg_stat_activity_count) / max(pg_settings_max_connections)"
    }
    pod_memory = {
      title = "Pod memory of its limit (the highest pod)"
      expr  = "max(max by (pod) (container_memory_working_set_bytes{namespace=~\"${local.ns_regex}\",container!=\"\"}) / max by (pod) (kube_pod_container_resource_limits{namespace=~\"${local.ns_regex}\",resource=\"memory\"}))"
    }
  })

  capacity_dashboard = {
    title       = "Capacity"
    uid         = "lite-capacity"
    tags        = ["langsmith-lite"]
    timezone    = "utc"
    refresh     = "1m"
    time        = { from = "now-24h", to = "now" }
    annotations = { list = [] }
    panels = concat(
      [for i, k in keys(local.bounds) : {
        id          = i + 1
        type        = "timeseries"
        title       = local.bounds[k].title
        datasource  = { type = "prometheus", uid = "prometheus" }
        gridPos     = { x = (i % 2) * 12, y = floor(i / 2) * 8, w = 12, h = 8 }
        targets     = [{ refId = "A", expr = local.bounds[k].expr }]
        fieldConfig = { defaults = { unit = "percentunit", min = 0, max = 1, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "orange", value = 0.8 }, { color = "red", value = 0.9 }] } }, overrides = [] }
      }],
      [{
        id          = length(local.bounds) + 1
        type        = "timeseries"
        title       = "CPU throttled, by pod"
        datasource  = { type = "prometheus", uid = "prometheus" }
        gridPos     = { x = 0, y = ceil(length(local.bounds) / 2) * 8, w = 24, h = 8 }
        targets     = [{ refId = "A", expr = "sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace=~\"${local.ns_regex}\"}[5m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace=~\"${local.ns_regex}\"}[5m]))", legendFormat = "{{pod}}" }]
        fieldConfig = { defaults = { unit = "percentunit", min = 0 }, overrides = [] }
      }],
    )
    schemaVersion = 39
  }

  # Grafana's unified alerting, provisioned: one rule a bound, firing when it holds above 80% for 10 minutes.
  alert_rules = { apiVersion = 1, groups = [{
    orgId    = 1
    name     = "capacity"
    folder   = "LangSmith Lite"
    interval = "1m"
    rules = [for k, b in local.bounds : {
      uid          = "lite-${replace(k, "_", "-")}"
      title        = "${b.title} above 80%"
      condition    = "C"
      for          = "10m"
      noDataState  = "OK"
      execErrState = "Error"
      labels       = { langsmith_lite_instance = var.name }
      annotations  = { summary = "${b.title} is above 80% of what the plan sized: raise it with make plan, or find what grew (OPERATE.md)." }
      data = [
        { refId = "A", relativeTimeRange = { from = 600, to = 0 }, datasourceUid = "prometheus", model = { refId = "A", expr = b.expr, instant = true } },
        { refId = "C", datasourceUid = "__expr__", model = { refId = "C", type = "threshold", expression = "A", conditions = [{ evaluator = { type = "gt", params = [0.8] } }] } },
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
      { langsmith = { url = local.dashboard_url }, capacity = { json = jsonencode(local.capacity_dashboard) } },
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
      auth               = { enabled = true, existingSecret = "mission-control-auth", jwtSecretKey = "jwt-secret" }
      discoverNamespaces = "${local.ns.langsmith},${local.ns.data}"
      features = {
        fixIssue       = false
        adopt          = false
        alerts         = false
        configSave     = false
        valuesOverride = false
        deploy         = false
        contention     = false
        diagnostics    = true
        discover       = true
        dbTools        = true
        chat           = true
      }
    }
    backend  = { resources = try(local.k8s["mission-control-backend"], null) }
    frontend = { resources = try(local.k8s["mission-control-frontend"], null) }
  }
}
