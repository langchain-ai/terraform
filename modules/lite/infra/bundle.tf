#------------------------------------------------------------------------------
# The bundle: every file the box needs, as one sensitive output. make up and
# make install stream it over ssh and box/install.sh installs it with k3s's own
# controllers: k3s applies whatever sits in its manifests directory, and its
# helm-controller installs each HelmChart. The box installs itself; nothing
# on the laptop talks to its Kubernetes API.
#
#   lite.env               what box/install.sh checks and installs (versions, the machine)
#   k3s-config.yaml        /etc/rancher/k3s/config.yaml
#   secrets.yaml           applied with kubectl, then deleted from the box
#   lite-00-base.yaml      namespaces, the Retain storage class, Traefik's settings
#   lite-10-datastores.yaml   Postgres, Redis, RustFS
#   lite-20-langsmith.yaml    LangSmith
#   lite-30-observe.yaml      Prometheus, Grafana, the exporters
#   lite-40-mission-control.yaml
#   lite-50-tunnel.yaml    cloudflared, with access = tunnel
#------------------------------------------------------------------------------

locals {
  releases = {
    datastores = {
      namespace = local.ns.data
      # Served by k3s from /var/lib/rancher/k3s/server/static/charts, where box/install.sh puts the package.
      source = { chart = "https://%%{KUBERNETES_API}%/static/charts/${local.datastores_tgz}" }
      values = local.datastores_values
    }
    langsmith           = { namespace = local.ns.langsmith, source = local.chart_source.langsmith, values = local.langsmith_values }
    prometheus          = { namespace = local.ns.observe, source = local.chart_source.prometheus, values = local.prometheus_values }
    grafana             = { namespace = local.ns.observe, source = local.chart_source.grafana, values = local.grafana_values }
    "redis-exporter"    = { namespace = local.ns.observe, source = local.chart_source["redis-exporter"], values = local.redis_exporter_values }
    "postgres-exporter" = { namespace = local.ns.observe, source = local.chart_source["postgres-exporter"], values = local.postgres_exporter_values }
    "mission-control"   = { namespace = local.ns.langsmith, source = local.chart_source["mission-control"], values = local.mission_control_values }
  }

  helm_chart = {
    for name, r in local.releases : name => yamlencode({
      apiVersion = "helm.cattle.io/v1"
      kind       = "HelmChart"
      metadata   = { name = name, namespace = "kube-system" }
      spec = merge(r.source, {
        targetNamespace = r.namespace
        valuesContent   = yamlencode(r.values)
        # LangSmith's hook Jobs (the migrations) run inside the install; a first install pulls every image.
        timeout = "20m0s"
        # abort, not reinstall: on a failed upgrade helm-controller would otherwise uninstall the
        # release, and with it the stores' StatefulSets.
        failurePolicy = "abort"
      })
    })
  }

  chart_source = {
    for name, c in local.pins.charts : name => { repo = c.repo, chart = c.chart, version = local.chart_version[name] }
  }

  namespaces = [
    { name = local.ns.langsmith, labels = {} },
    # The stores need baseline (Postgres and Redis run as their images' own users); the datastores
    # chart would set the same label, but it does not create a namespace the Secrets already need.
    { name = local.ns.data, labels = { "pod-security.kubernetes.io/enforce" = "baseline" } },
    { name = local.ns.observe, labels = {} },
  ]

  base = concat(
    [for n in local.namespaces : {
      apiVersion = "v1"
      kind       = "Namespace"
      metadata   = { name = n.name, labels = n.labels }
    }],
    [
      # k3s's local-path class deletes a volume with its claim; the stores' volumes must outlive it
      # (the bare-metal module refuses a Delete class for them for the same reason).
      {
        apiVersion        = "storage.k8s.io/v1"
        kind              = "StorageClass"
        metadata          = { name = "local-path-retain" }
        provisioner       = "rancher.io/local-path"
        reclaimPolicy     = "Retain"
        volumeBindingMode = "WaitForFirstConsumer"
      },
      {
        apiVersion = "helm.cattle.io/v1"
        kind       = "HelmChartConfig"
        metadata   = { name = "traefik", namespace = "kube-system" }
        spec       = { valuesContent = yamlencode(local.traefik_values) }
      },
    ],
  )

  secret_manifests = {
    for s in concat(
      [
        {
          name = "langsmith-config", namespace = local.ns.langsmith, data = {
            langsmith_license_key          = var.langsmith_license_key
            api_key_salt                   = local.secret.api_key_salt
            jwt_secret                     = local.secret.jwt_secret
            initial_org_admin_password     = local.secret.admin
            blob_storage_access_key        = local.secret.rustfs_access_key
            blob_storage_access_key_secret = local.secret.rustfs_secret_key
          }
        },
        # The chart's format: no scheme for Postgres, a scheme for Redis (bare-metal module, main.tf).
        { name = "langsmith-postgres", namespace = local.ns.langsmith, data = {
          connection_url = "${local.postgres.user}:${local.secret.postgres}@${local.postgres.host}:${local.postgres.port}/${local.postgres.database}"
        } },
        { name = "langsmith-redis", namespace = local.ns.langsmith, data = {
          connection_url = "redis://:${local.secret.redis}@${local.redis_host}:6379/0"
        } },
        { name = "smithdb-config", namespace = local.ns.langsmith, data = {
          smithdb_metastore_host     = local.postgres.host
          smithdb_metastore_db       = local.postgres.metastore
          smithdb_metastore_user     = local.postgres.user
          smithdb_metastore_password = local.secret.postgres
          smithdb_s3_access_key      = local.secret.rustfs_access_key
          smithdb_s3_secret_key      = local.secret.rustfs_secret_key
        } },
        { name = "mission-control-auth", namespace = local.ns.langsmith, data = {
          username   = "admin"
          password   = local.secret.mission_control
          jwt-secret = local.secret.mission_control_jwt
        } },
        # The datastores chart's own Secrets, with existingSecrets (its values.yaml lists the keys).
        { name = "postgres-langsmith-credentials", namespace = local.ns.data, data = {
          POSTGRES_USER     = local.postgres.user
          POSTGRES_PASSWORD = local.secret.postgres
          POSTGRES_DB       = local.postgres.database
        } },
        { name = "redis-langsmith-credentials", namespace = local.ns.data, data = {
          password    = local.secret.redis
          "auth.conf" = "requirepass ${local.secret.redis}"
        } },
        { name = "rustfs-credentials", namespace = local.ns.data, data = {
          access-key      = local.secret.rustfs_access_key
          secret-key      = local.secret.rustfs_secret_key
          aws-credentials = "[default]\naws_access_key_id = ${local.secret.rustfs_access_key}\naws_secret_access_key = ${local.secret.rustfs_secret_key}\n"
        } },
        { name = "grafana-admin", namespace = local.ns.observe, data = {
          admin-user     = "admin"
          admin-password = local.secret.grafana_admin
        } },
        { name = "redis-exporter", namespace = local.ns.observe, data = { password = local.secret.redis } },
        { name = "postgres-exporter", namespace = local.ns.observe, data = { password = local.secret.postgres } },
      ],
      var.access == "tunnel" ? [{ name = "cloudflared", namespace = local.ns.langsmith, data = { token = var.tunnel_token } }] : [],
      ) : "${s.namespace}/${s.name}" => {
      apiVersion = "v1"
      kind       = "Secret"
      type       = "Opaque"
      metadata   = { name = s.name, namespace = s.namespace }
      stringData = s.data
    }
  }

  # cloudflared connects out to Cloudflare and hands every request to Traefik; the public hostname and
  # its service (http://traefik.kube-system.svc.cluster.local:80) are set on the tunnel in Cloudflare.
  tunnel = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "cloudflared", namespace = local.ns.langsmith }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "cloudflared" } }
      template = {
        metadata = { labels = { app = "cloudflared" } }
        spec = {
          containers = [{
            name            = "cloudflared"
            image           = local.pins.images.cloudflared
            args            = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]
            env             = [{ name = "TUNNEL_TOKEN", valueFrom = { secretKeyRef = { name = "cloudflared", key = "token" } } }]
            resources       = try(local.k8s.cloudflared, {})
            livenessProbe   = { httpGet = { path = "/ready", port = 2000 }, initialDelaySeconds = 10, periodSeconds = 10 }
            securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, runAsNonRoot = true, runAsUser = 65532 }
          }]
        }
      }
    }
  }

  k3s_config = {
    "write-kubeconfig-mode" = "0600"
    "node-name"             = var.name
    # Secrets are encrypted in k3s's datastore, not only base64 in it.
    "secrets-encryption" = true
    "kubelet-arg" = [
      "system-reserved=cpu=${local.preset.reserved.cpu_m}m,memory=${local.preset.reserved.mem_mi}Mi",
    ]
  }

  lite_env = {
    NAME            = var.name
    K3S_VERSION     = local.pins.k3s
    MACHINE_CPU     = tostring(local.machine.cpu)
    MACHINE_MEM_GI  = tostring(local.machine.memory_gi)
    MACHINE_DISK_GI = tostring(local.machine.disk_gi)
    ACCESS          = var.access
    DATASTORES_TGZ  = local.datastores_tgz
  }
}

# The plan fails here, before any machine exists, when the box is too small for what it would run.
resource "terraform_data" "fit" {
  input = { requested = local.requested, ceiling = local.ceiling, disk_needed_gi = local.disk_needed_gi }

  lifecycle {
    precondition {
      condition     = length(local.fit_problems) == 0
      error_message = "The box does not fit: ${join("; ", local.fit_problems)}. Use a bigger box, a lower runs_per_second, or smaller volumes (SIZING.md)."
    }
    precondition {
      condition     = length(local.unknown_overrides) == 0
      error_message = "resources names pods Lite does not run: ${join(", ", local.unknown_overrides)}. The plan output's pods lists the names."
    }
    precondition {
      condition     = !local.named_access || var.domain != ""
      error_message = "access = ${var.access} needs domain."
    }
    precondition {
      condition     = var.access != "dns" || can(regex("^[^@\\s]+@[^@\\s]+$", var.acme_email))
      error_message = "access = dns needs acme_email, the address Let's Encrypt registers the certificate to."
    }
    precondition {
      condition     = var.access != "tunnel" || var.tunnel_token != ""
      error_message = "access = tunnel needs the tunnel's token: make secrets saves it."
    }
    precondition {
      condition     = var.langsmith_license_key != ""
      error_message = "No license key: run make secrets."
    }
    # Without the resolved versions the plan would install each chart's bare line, and a tag such as
    # 1.2.0 for Mission Control that is not a release. make plan resolves them first.
    precondition {
      condition     = var.resolved != null
      error_message = "The chart versions are not resolved: plan with make plan, not terraform directly."
    }
  }
}

locals {
  bundle = merge(
    {
      "lite.env"                = join("", [for k, v in local.lite_env : "${k}=${v}\n"])
      "k3s-config.yaml"         = yamlencode(local.k3s_config)
      "secrets.yaml"            = join("", [for s in values(local.secret_manifests) : "---\n${yamlencode(s)}"])
      "lite-00-base.yaml"       = join("", [for d in local.base : "---\n${yamlencode(d)}"])
      "lite-10-datastores.yaml" = local.helm_chart.datastores
      "lite-20-langsmith.yaml" = join("", concat(
        ["---\n${local.helm_chart.langsmith}"],
        # helm-controller merges a HelmChartConfig of the same name into the HelmChart's values, as a
        # second -f layer.
        local.scrape_values == "" ? [] : ["---\n${yamlencode({
          apiVersion = "helm.cattle.io/v1"
          kind       = "HelmChartConfig"
          metadata   = { name = "langsmith", namespace = "kube-system" }
          spec       = { valuesContent = local.scrape_values }
        })}"],
      ))
      "lite-30-observe.yaml"         = join("", [for c in ["prometheus", "grafana", "redis-exporter", "postgres-exporter"] : "---\n${local.helm_chart[c]}"])
      "lite-40-mission-control.yaml" = local.helm_chart["mission-control"]
    },
    var.access == "tunnel" ? { "lite-50-tunnel.yaml" = yamlencode(local.tunnel) } : {},
  )
}
