#------------------------------------------------------------------------------
# How the releases reach a box: every file k3s needs, as one sensitive output.
# make up streams it over ssh; box/install.sh installs it with
# k3s's own controllers (k3s applies its manifests folder, and helm-controller
# installs each HelmChart there). Nothing on the laptop talks to the box's API.
#
#   lite.env                    what box/install.sh checks and uses
#   k3s-config.yaml             /etc/rancher/k3s/config.yaml
#   secrets.yaml                applied, then deleted from the box
#   lite-00-base.yaml           namespaces, the priority class, the storage class, Traefik's settings
#   lite-NN-<release>.yaml      one HelmChart a release, in install order (releases.tf)
#   lite-90-tunnel.yaml         cloudflared, with access = tunnel
#------------------------------------------------------------------------------

locals {
  helm_charts = {
    for name, r in local.releases : name => join("", concat(
      ["---\n${yamlencode({
        apiVersion = "helm.cattle.io/v1"
        kind       = "HelmChart"
        metadata   = { name = name, namespace = "kube-system", labels = local.instance_label }
        spec = merge(r.source, {
          targetNamespace = r.namespace
          valuesContent   = yamlencode(r.values)
          # A first install pulls every image, and LangSmith's migrations run inside it.
          timeout = "20m0s"
          # abort, not reinstall: on a failed upgrade helm-controller would otherwise uninstall the
          # release, and with it the stores' StatefulSets.
          failurePolicy = "abort"
        })
      })}"],
      # helm-controller merges a HelmChartConfig of the same name into the HelmChart's values, as a second
      # -f layer.
      r.layer == "" ? [] : ["---\n${yamlencode({
        apiVersion = "helm.cattle.io/v1"
        kind       = "HelmChartConfig"
        metadata   = { name = name, namespace = "kube-system" }
        spec       = { valuesContent = r.layer }
      })}"],
    ))
  }

  box_objects = concat(local.cluster_objects, [
    # k3s's local-path class deletes a volume with its claim; the stores' volumes must outlive it.
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
  ])

  # cloudflared connects out to Cloudflare and hands every request to Traefik; the public hostname and
  # its service (http://traefik.kube-system.svc.cluster.local:80) are set on the tunnel in Cloudflare.
  tunnel = {
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = "cloudflared", namespace = local.ns.langsmith, labels = local.instance_label }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "cloudflared" } }
      template = {
        metadata = { labels = merge({ app = "cloudflared" }, local.instance_label) }
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

  k3s_config = merge(
    {
      "write-kubeconfig-mode" = "0600"
      "node-name"             = var.name
      "node-label"            = ["langsmith-lite/instance=${var.name}"]
      # Secrets are encrypted in k3s's datastore, not only base64 in it.
      "secrets-encryption" = true
      "kubelet-arg" = [
        "system-reserved=cpu=${local.preset.reserved.cpu_m}m,memory=${local.preset.reserved.mem_mi}Mi",
        # Evict pods before a disk fills, rather than let a store fill the disk the system needs.
        "eviction-hard=memory.available<200Mi,nodefs.available<10%,imagefs.available<15%",
        "image-gc-high-threshold=80",
        "image-gc-low-threshold=70",
      ]
    },
    # A bare-metal data_path holds every volume; an AWS data volume is mounted at k3s's own folder.
    var.data_path != "" ? { "default-local-storage-path" = var.data_path } : {},
  )

  lite_env = {
    NAME            = var.name
    K3S_VERSION     = local.pins.k3s
    MACHINE_CPU     = tostring(local.machine.cpu)
    MACHINE_MEM_GI  = tostring(local.machine.memory_gi)
    MACHINE_DISK_GI = tostring(local.system_disk_gi)
    DATA_DISK_GI    = tostring(local.data_disk_gi)
    DATA_MOUNT      = local.data_mount
    # The AWS data volume's id: the install finds its device by it and mounts it at DATA_MOUNT.
    DATA_VOLUME_ID = try(module.aws[0].data_volume_id, "")
    ACCESS         = var.access
    NS             = local.ns.langsmith
    NS_DATA        = local.ns.data
    NS_OBSERVE     = local.ns.observe
    RELEASES       = join(" ", local.release_order)
    DATASTORES_TGZ = local.datastores_tgz
  }

  bundle = merge(
    {
      "lite.env"          = join("", [for k, v in local.lite_env : "${k}=${v}\n"])
      "k3s-config.yaml"   = yamlencode(local.k3s_config)
      "secrets.yaml"      = local.secrets_yaml
      "lite-00-base.yaml" = join("", [for d in local.box_objects : "---\n${yamlencode(d)}"])
    },
    { for i, name in local.release_order : format("lite-%02d-%s.yaml", 10 + i, name) => local.helm_charts[name] },
    local.features.tunnel ? { "lite-90-tunnel.yaml" = yamlencode(local.tunnel) } : {},
  )
}

# The plan fails here, before any machine exists, when the box cannot hold what it would run.
resource "terraform_data" "fit" {
  input = { requested = local.requested, allowed = local.allowed, volumes_gi = local.volumes_gi }

  lifecycle {
    precondition {
      condition     = length(local.fit_problems) == 0
      error_message = "The box does not fit: ${join("; ", local.fit_problems)}. Use a bigger box, a lower runs_per_second, shorter TTLs, or a larger disk (SIZING.md)."
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
      error_message = "access = tunnel needs the tunnel's token: make up asks for it, make secrets changes it."
    }
    precondition {
      condition     = var.langsmith_license_key != ""
      error_message = "No license key: make up asks for it, or set TF_VAR_langsmith_license_key."
    }
    # Without the resolved versions the plan would install each chart's bare line, and a tag such as
    # 1.2.0 for Mission Control that is not a release. make plan resolves them first.
    precondition {
      condition     = var.resolved != null
      error_message = "The chart versions are not resolved: plan with make plan, not terraform directly."
    }
    # A cluster of one's own has its own storage classes; k3s's local-path is not there.
    precondition {
      condition     = var.cloud != "cluster" || !startswith(var.storage_class, "local-path") && !startswith(var.scratch_storage_class, "local-path")
      error_message = "cloud = cluster needs storage_class and scratch_storage_class set to the cluster's own (gp3, for example): local-path is k3s's."
    }
    precondition {
      condition     = var.data_path == "" || try(local.machine.data_disk_gi, null) != null
      error_message = "data_path needs machine.data_disk_gi, the size of that disk, so the plan can check the volumes fit on it."
    }
  }
}
