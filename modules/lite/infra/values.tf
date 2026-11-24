#------------------------------------------------------------------------------
# The Helm values of every release on the box, as data. No credential is in
# any of them: each release reads a Secret by name (bundle.tf), so the values
# can be read, diffed and tested freely.
#------------------------------------------------------------------------------

locals {
  # How Traefik (k3s's own ingress) carries LangSmith in each access mode.
  # localhost and tunnel: plain HTTP inside the box, reached through ssh or the tunnel, which encrypt it.
  # ip: HTTPS with Traefik's default self-signed certificate. dns: HTTPS with Let's Encrypt.
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

  # localhost and tunnel take the Traefik Service off the host's ports (ClusterIP), so nothing but ssh
  # listens; ip and dns keep k3s's servicelb on 80 and 443 and send 80 to 443.
  https_redirect = {
    ports = { web = { redirections = { entryPoint = { to = "websecure", scheme = "https", permanent = true } } } }
  }
  traefik_values = {
    localhost = { service = { type = "ClusterIP" } }
    tunnel    = { service = { type = "ClusterIP" } }
    ip        = local.https_redirect
    dns = merge(local.https_redirect, {
      certificatesResolvers = { le = { acme = {
        email         = var.acme_email
        storage       = "/data/acme.json"
        httpChallenge = { entryPoint = "web" }
      } } }
      # The account and certificates survive a Traefik restart, so Let's Encrypt's rate limit is not spent.
      persistence = { enabled = true, size = "128Mi", storageClass = "local-path-retain" }
    })
  }[var.access]

  # frontend and backend take more than their size, below.
  app_components = ["platformBackend", "ingestQueue", "queue", "playground", "aceBackend"]

  langsmith_values = merge(
    { for c in local.app_components : c => { deployment = { resources = local.k8s[c] } } },
    {
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
        # One pair of TTLs drives LangSmith, SmithDB's long-term retention (the chart reads longlived)
        # and the blob bucket's expiry rules (datastores_values below).
        ttl = {
          enabled = true
          ttl_period_seconds = {
            longlived  = tostring(var.long_ttl_days * 86400)
            shortlived = tostring(var.short_ttl_days * 86400)
          }
        }
        settings = { redisRunsExpirySeconds = tostring(var.redis_runs_expiry_hours * 3600) }
      }
      backend = {
        # The e2e test Job is the chart's smoke test for its CI; on one box it is a pod nobody reads.
        e2eTest    = { enabled = false }
        deployment = { resources = local.k8s.backend }
      }
      frontend = {
        maxBodySize = "${var.max_payload_mb}M"
        deployment  = { resources = local.k8s.frontend }
      }
      postgres = { external = { enabled = true, existingSecretName = "langsmith-postgres" } }
      redis    = { external = { enabled = true, existingSecretName = "langsmith-redis" } }
      # Tracing only: every product beyond it is off, and ClickHouse is the store SmithDB replaces.
      clickhouse         = { enabled = false }
      insights           = { enabled = false }
      polly              = { enabled = false }
      operator           = { enabled = false }
      fleetToolServer    = { enabled = false }
      fleetTriggerServer = { enabled = false }
      ingress = {
        enabled          = true
        ingressClassName = "traefik"
        annotations      = local.ingress_annotations
      }
      smithdb = {
        enabled  = true
        topology = "unified"
        langsmith = {
          ingestion = { enabled = true }
          query     = { enabled = true }
        }
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
          resources = local.k8s.smithdb
          # The query cache is disposable, so it sits on local-path (reclaim Delete), sized here rather
          # than at the tier's 100 GiB.
          volumes = [{ name = "cache", ephemeral = { volumeClaimTemplate = { spec = {
            accessModes      = ["ReadWriteOnce"]
            storageClassName = "local-path"
            resources        = { requests = { storage = "${local.volumes.smithdb_cache}Gi" } }
          } } } }]
        } }
      }
    },
  )

  # The bare-metal module's datastores chart: one Postgres holding LangSmith's database and SmithDB's
  # metastore, one Redis, one RustFS with both buckets.
  datastores_values = {
    runtime          = "statefulset"
    storageClass     = "local-path-retain"
    namespace        = local.ns.data
    createNamespaces = false
    existingSecrets  = true
    # The exporters read the stores from the observe namespace.
    allowedNamespaces = [local.ns.langsmith, local.ns.observe]
    postgres = { instances = {
      langsmith = {
        enabled        = true
        namespace      = local.ns.data
        database       = local.postgres.database
        username       = local.postgres.user
        databases      = [local.postgres.metastore]
        maxConnections = var.postgres_max_connections
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
        resources       = local.k8s.redis
        volumeSize      = "${local.volumes.redis}Gi"
      }
      juicefs = { enabled = false }
    } }
    rustfs = {
      enabled    = true
      namespace  = local.ns.data
      buckets    = [local.s3.smithdb, local.s3.blobs]
      ttlBuckets = [local.s3.blobs]
      ttlDays    = { short = var.short_ttl_days, long = var.long_ttl_days }
      resources  = local.k8s.rustfs
      volumeSize = "${local.volumes.object_store}Gi"
    }
  }

  # Prometheus finds LangSmith's metrics from the chart's own scrape annotations (the HelmChartConfig in
  # bundle.tf), through the prometheus chart's default pod job; its other default jobs add the kubelet's
  # cAdvisor (CPU, memory, throttling per container) and every Service annotated prometheus.io/scrape
  # (the two exporters). No port of LangSmith's is written here.
  prometheus_values = {
    alertmanager             = { enabled = false }
    "prometheus-pushgateway" = { enabled = false }
    "kube-state-metrics"     = { resources = local.k8s["kube-state-metrics"] }
    # Off the host's network: the chart's default (hostNetwork) served node metrics, unauthenticated, on
    # port 9100 of every address the box has.
    "prometheus-node-exporter" = { resources = local.k8s["node-exporter"], hostNetwork = false }
    server = {
      retention = "${var.prometheus_retention_days}d"
      # And by size: local-path volumes are not quotas, so metrics could otherwise fill the box's disk.
      retentionSize    = "${floor(local.volumes.prometheus * 0.8)}GB"
      resources        = local.k8s.prometheus
      persistentVolume = { enabled = true, size = "${local.volumes.prometheus}Gi", storageClass = "local-path" }
      global           = { scrape_interval = "15s", evaluation_interval = "15s" }
    }
  }

  redis_exporter_values = {
    redisAddress = "redis://${local.redis_host}:6379"
    auth         = { enabled = true, secret = { name = "redis-exporter", key = "password" } }
    resources    = local.k8s["redis-exporter"]
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
    resources = local.k8s["postgres-exporter"]
    service   = { annotations = { "prometheus.io/scrape" = "true", "prometheus.io/port" = "9187" } }
  }

  grafana_dashboards = {
    for name, d in local.pins.dashboards : name => { gnetId = d.id, revision = d.revision, datasource = "Prometheus" }
  }

  grafana_values = {
    admin       = { existingSecret = "grafana-admin", userKey = "admin-user", passwordKey = "admin-password" }
    resources   = local.k8s.grafana
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
    dashboards = { lite = merge({ langsmith = { url = local.dashboard_url } }, local.grafana_dashboards) }
  }

  mission_control_values = {
    images = {
      # Its images are public: the chart's default regcred pull secret is not needed.
      imagePullSecrets = []
      backendImage     = { tag = local.mission_control_tag }
      frontendImage    = { tag = local.mission_control_tag }
    }
    config = {
      # A login made here (bundle.tf) replaces the first-run setup token: one place holds every login.
      auth               = { enabled = true, existingSecret = "mission-control-auth", jwtSecretKey = "jwt-secret" }
      discoverNamespaces = "${local.ns.langsmith},${local.ns.data}"
      # Read-only but for its diagnostics: the features that write (delete pods, patch ownership, save
      # drafts, alert config, value overrides, deploy) are off, and with them their RBAC verbs. Its
      # login is made here, so it never needs to write its own auth Secret.
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
    backend  = { resources = local.k8s["mission-control-backend"] }
    frontend = { resources = local.k8s["mission-control-frontend"] }
  }
}
