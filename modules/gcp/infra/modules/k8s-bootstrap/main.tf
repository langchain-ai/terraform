# K8s Bootstrap Module - Namespaces, Service Accounts, Secrets, and KEDA

locals {
  # The kubectl provisioners further down fetch their own cluster credentials
  # instead of trusting the operator's current context, which may point at an
  # unrelated cluster or be empty on a first run. The credentials land in a temp
  # file that dies with the provisioner's shell, leaving ~/.kube/config alone.
  # Deliberately no `set -e`: those scripts tolerate non-zero exits in their retry
  # loops, so only the credential fetch is fail-fast.
  kubectl_creds = <<-EOT
    KUBECONFIG="$(mktemp -t ls-kubeconfig.XXXXXX)"
    export KUBECONFIG
    trap 'rm -f "$KUBECONFIG"' EXIT
    gcloud container clusters get-credentials "$LS_CLUSTER_NAME" \
      --region "$LS_REGION" --project "$LS_PROJECT_ID" --quiet || exit 1
  EOT

  # Input values reach these scripts only through the environment, never as
  # script text, so the shell cannot run a value as a command. Each provisioner
  # that uses kubectl_creds sets environment = local.kubectl_env, merged with
  # any values of its own.
  kubectl_env = {
    LS_CLUSTER_NAME = var.cluster_name
    LS_REGION       = var.region
    LS_PROJECT_ID   = var.project_id
  }
}

#------------------------------------------------------------------------------
# LangSmith Namespace
#------------------------------------------------------------------------------
resource "kubernetes_namespace" "langsmith" {
  metadata {
    name = var.langsmith_namespace

    labels = merge(var.labels, {
      "name" = var.langsmith_namespace
    })
  }
}

#------------------------------------------------------------------------------
# Kubernetes Service Account
#------------------------------------------------------------------------------
resource "kubernetes_service_account" "langsmith" {
  metadata {
    name      = "langsmith-ksa"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    annotations = var.workload_identity_gsa_email != "" ? {
      "iam.gke.io/gcp-service-account" = var.workload_identity_gsa_email
    } : {}

    labels = merge(var.labels, {
      "component" = "service-account"
    })
  }
}

#------------------------------------------------------------------------------
# PostgreSQL Credentials Secret
#------------------------------------------------------------------------------
resource "kubernetes_secret" "postgres_credentials" {
  count = var.use_external_postgres ? 1 : 0

  metadata {
    name      = "langsmith-postgres-credentials"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "database"
    })
  }

  data = {
    connection_url = var.postgres_connection_url
  }

  type = "Opaque"
}

#------------------------------------------------------------------------------
# Redis Credentials Secret
#------------------------------------------------------------------------------
resource "kubernetes_secret" "redis_credentials" {
  count = var.use_managed_redis ? 1 : 0

  metadata {
    name      = "langsmith-redis-credentials"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "cache"
    })
  }

  data = {
    connection_url = var.redis_connection_url
  }

  type = "Opaque"
}

#------------------------------------------------------------------------------
# LangSmith License Secret
#------------------------------------------------------------------------------
resource "kubernetes_secret" "langsmith_license" {
  count = var.langsmith_license_key != "" ? 1 : 0

  metadata {
    name      = "langsmith-license"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "license"
    })
  }

  data = {
    license-key = var.langsmith_license_key
  }

  type = "Opaque"
}

#------------------------------------------------------------------------------
# ClickHouse Credentials Secret (for external/managed ClickHouse)
#------------------------------------------------------------------------------
resource "kubernetes_secret" "clickhouse_credentials" {
  count = var.clickhouse_source != "in-cluster" && var.clickhouse_host != "" ? 1 : 0

  metadata {
    name      = "langsmith-clickhouse-credentials"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "clickhouse"
    })
  }

  data = {
    host          = var.clickhouse_host
    port          = tostring(var.clickhouse_port)
    http_port     = tostring(var.clickhouse_http_port)
    user          = var.clickhouse_user
    password      = var.clickhouse_password
    database      = var.clickhouse_database
    tls           = var.clickhouse_tls ? "true" : "false"
    native_secure = var.clickhouse_tls ? "true" : "false"
  }

  type = "Opaque"
}

# ClickHouse CA Certificate Secret (optional, for custom CA)
resource "kubernetes_secret" "clickhouse_ca_cert" {
  count = var.clickhouse_source != "in-cluster" && var.clickhouse_ca_cert != "" ? 1 : 0

  metadata {
    name      = "langsmith-clickhouse-ca"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "clickhouse"
    })
  }

  data = {
    "ca.crt" = var.clickhouse_ca_cert
  }

  type = "Opaque"
}

#------------------------------------------------------------------------------
# TLS Certificate Secret (when using existing certificates)
#------------------------------------------------------------------------------
resource "kubernetes_secret" "tls_certificate" {
  count = var.tls_certificate_source == "existing" && var.tls_certificate_crt != "" && var.tls_certificate_key != "" ? 1 : 0

  metadata {
    name      = var.tls_secret_name
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    labels = merge(var.labels, {
      "component" = "tls"
    })

    annotations = {
      "description" = "TLS certificate for LangSmith ingress"
    }
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = var.tls_certificate_crt
    "tls.key" = var.tls_certificate_key
  }
}

#------------------------------------------------------------------------------
# Resource Quotas
#------------------------------------------------------------------------------
locals {
  # Base figures sized for LangSmith itself. Optional features that add large
  # pods contribute through the resource_quota_extra_* variables rather than by
  # editing these, so a plain install keeps the exact same quota it always had.
  langsmith_resource_quota_base_cpu       = 50
  langsmith_resource_quota_base_memory_gi = 120
  langsmith_resource_quota_base_pods      = 100

  # The limits side is not simply twice the requests side, so carry it as its own
  # pair of figures rather than deriving it.
  langsmith_resource_quota_base_limit_cpu       = 100
  langsmith_resource_quota_base_limit_memory_gi = 200

  langsmith_resource_quota_requests = {
    "requests.cpu"    = tostring(local.langsmith_resource_quota_base_cpu + var.resource_quota_extra_cpu)
    "requests.memory" = "${local.langsmith_resource_quota_base_memory_gi + var.resource_quota_extra_memory_gi}Gi"
    "pods"            = tostring(local.langsmith_resource_quota_base_pods + var.resource_quota_extra_pods)
  }

  # The headroom is doubled on the limits side, so a feature admitted on
  # requests is not then rejected on limits. Doubling also keeps the same 2x
  # requests-to-limits ratio the base figures use. The root sizes the SmithDB
  # extra for both sides, because some SmithDB pods have limits above requests.
  langsmith_resource_quota_limits = {
    "limits.cpu"    = tostring(local.langsmith_resource_quota_base_limit_cpu + (var.resource_quota_extra_cpu * 2))
    "limits.memory" = "${local.langsmith_resource_quota_base_limit_memory_gi + (var.resource_quota_extra_memory_gi * 2)}Gi"
  }

  langsmith_resource_quota_hard = merge(
    local.langsmith_resource_quota_requests,
    var.resource_quota_include_limits ? local.langsmith_resource_quota_limits : {},
  )
}

resource "kubernetes_resource_quota" "langsmith" {
  metadata {
    name      = "langsmith-quota"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    hard = local.langsmith_resource_quota_hard
  }
}

# GKE configures the apiserver's ResourceQuota admission plugin with
# limitedResources over the PriorityClass scope, so a pod requesting
# system-node-critical or system-cluster-critical is admitted only where a
# quota with a matching scopeSelector already exists — which is how GKE keeps
# those classes inside kube-system (see its own gcp-critical-pods quota).
#
# The chart 0.16 JuiceFS CSI driver for sandboxes uses both: the
# juicefs-csi-node DaemonSet is system-node-critical and the
# juicefs-csi-controller StatefulSet is system-cluster-critical. Without this
# quota neither is ever created — the DaemonSet reports desired N, current 0
# with the rejection recorded only on the controller object, csi.juicefs.com
# never registers on any node, and sandbox-host sits in ContainerCreating on a
# FailedMount that names a missing CSI driver rather than a quota. Chart 0.17
# has no CSI driver; the quota stays for the upgrade from chart 0.16.
#
# The pod ceiling matches GKE's own quota for these classes: this object exists
# to grant the capability, not to cap it. The unscoped langsmith-quota above
# still counts these pods against the namespace CPU and memory budget.
resource "kubernetes_resource_quota_v1" "langsmith_critical_pods" {
  count = var.allow_critical_priority_pods ? 1 : 0

  metadata {
    name      = "langsmith-critical-pods"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    hard = {
      pods = "1G"
    }

    scope_selector {
      match_expression {
        scope_name = "PriorityClass"
        operator   = "In"
        values     = ["system-node-critical", "system-cluster-critical"]
      }
    }
  }
}

# ResourceQuota request tracking requires every admitted container to declare
# requests. Supply conservative defaults for third-party sandbox containers that
# omit them, but deliberately do not inject limits: sandbox-host creates per-VM
# child cgroups beneath its pod cgroup and needs access to dedicated node capacity.
resource "kubernetes_limit_range_v1" "langsmith_default_requests" {
  count = length(var.default_container_requests) > 0 ? 1 : 0

  metadata {
    name      = "langsmith-default-requests"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    limit {
      type            = "Container"
      default_request = var.default_container_requests
    }
  }
}

#------------------------------------------------------------------------------
# SmithDB cache StorageClass (network-disk mode)
# The chart gives each SmithDB cache pod a PVC from smithdb.cache.storageClassName.
# Hyperdisk Balanced sets IOPS and throughput apart from capacity, so each volume
# gets 7000 IOPS and 1000 MiB/s. WaitForFirstConsumer puts each disk in the zone
# of its pod.
#------------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "smithdb_cache" {
  count = var.create_smithdb_cache_storage_class ? 1 : 0

  metadata {
    name   = var.smithdb_cache_storage_class_name
    labels = merge(var.labels, { "component" = "smithdb-cache" })
  }

  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type                             = "hyperdisk-balanced"
    provisioned-iops-on-create       = "7000"
    provisioned-throughput-on-create = "1000Mi"
  }
}

#------------------------------------------------------------------------------
# Network Policy (restrict traffic)
#------------------------------------------------------------------------------
# Default-deny-style ingress: only the langsmith and envoy-gateway namespaces may
# reach LangSmith pods. Always created. When default_deny_excluded_component is set
# (GKE Dataplane V2 + sandboxes), that one component (platform-backend) is excluded
# from the selector so the host-networked, node-sourced sandbox-host can reach it —
# a standard NetworkPolicy can't authorize node traffic on Cilium (an ipBlock does
# not match it and the CiliumNetworkPolicy CRD is not exposed). Every other pod
# keeps the default-deny. CALICO instead keeps the full default-deny and admits the
# node subnet via kubernetes_network_policy.sandbox_host_ingress.
resource "kubernetes_network_policy" "langsmith_default" {
  metadata {
    name      = "langsmith-default"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    pod_selector {
      dynamic "match_expressions" {
        for_each = var.default_deny_excluded_component != "" ? [1] : []
        content {
          key      = "app.kubernetes.io/component"
          operator = "NotIn"
          values   = [var.default_deny_excluded_component]
        }
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            name = var.langsmith_namespace
          }
        }
      }
      from {
        namespace_selector {
          match_labels = {
            name = "envoy-gateway-system"
          }
        }
      }
      # The GKE Gateway's load balancer and its health checks reach pods directly
      # from Google's front-end ranges, not from a namespace. A regional class
      # sends requests from its proxy-only subnet instead, which is not admitted
      # here; the root accepts only the global class.
      dynamic "from" {
        for_each = var.allow_gke_gateway_traffic ? ["130.211.0.0/22", "35.191.0.0/16"] : []
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }

    egress {}

    policy_types = ["Ingress"]
  }
}

# CALICO only: admit the node subnet so the host-networked sandbox-host (source =
# node IP) can reach platform-backend (default-blueprint-ensure,
# host-observations/report). Calico's ipBlock matches node IPs. On Dataplane V2 an
# ipBlock does NOT match node-sourced traffic, so there the root leaves
# sandbox_host_ingress_cidrs empty and scopes langsmith-default to exclude
# platform-backend instead. Created only when the list is non-empty (CALICO + sandboxes).
resource "kubernetes_network_policy" "sandbox_host_ingress" {
  count = length(var.sandbox_host_ingress_cidrs) > 0 ? 1 : 0

  metadata {
    name      = "langsmith-allow-sandbox-host"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}

    ingress {
      dynamic "from" {
        for_each = var.sandbox_host_ingress_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}

#------------------------------------------------------------------------------
# KEDA - Kubernetes Event-driven Autoscaling
#------------------------------------------------------------------------------
resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.14.0"
  namespace        = "keda"
  create_namespace = true

  values = [
    yamlencode({
      resources = {
        operator = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
        metricServer = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      prometheus = {
        metricServer = {
          enabled = true
        }
        operator = {
          enabled = true
        }
      }
    })
  ]

  wait    = true
  timeout = 600
}

#------------------------------------------------------------------------------
# cert-manager - TLS certificates from Let's Encrypt or your own issuer
# Installed for tls_certificate_source = "letsencrypt" or "cert-manager", or
# with install_cert_manager. Reference: https://cert-manager.io/docs/
#------------------------------------------------------------------------------
locals {
  cert_manager_minor = tonumber(regex("^v1\\.([0-9]+)\\.", var.cert_manager_version)[0])

  letsencrypt_enabled = var.install_cert_manager && var.tls_certificate_source == "letsencrypt" && var.letsencrypt_email != ""

  # One Certificate for both cert-manager sources. Only the issuer differs.
  certificate_enabled = (
    var.install_cert_manager &&
    contains(["letsencrypt", "cert-manager"], var.tls_certificate_source) &&
    var.langsmith_domain != "" && var.tls_secret_name != ""
  )
  certificate_issuer_ref = var.tls_certificate_source == "letsencrypt" ? {
    name = "letsencrypt-prod"
    kind = "ClusterIssuer"
    } : {
    name = var.cert_manager_issuer_name
    kind = var.cert_manager_issuer_kind
  }
}

# cert-manager with Gateway API support on exits at startup when the Gateway API
# CRDs are missing, and the Envoy Gateway path installs them only later, in the
# ingress module (which depends on this one). Apply the same bundle here first.
# kubectl apply is idempotent, so the ingress module's apply is then a no-op.
resource "null_resource" "gateway_api_crds_for_cert_manager" {
  count = var.install_cert_manager && var.cert_manager_enable_gateway_api ? 1 : 0

  triggers = {
    crds_url = var.gateway_api_crds_url
  }

  provisioner "local-exec" {
    environment = merge(local.kubectl_env, { LS_GATEWAY_API_CRDS_URL = var.gateway_api_crds_url })
    command     = <<-EOT
      ${local.kubectl_creds}
      kubectl apply --server-side --force-conflicts -f "$LS_GATEWAY_API_CRDS_URL" || exit 1
    EOT
  }
}

# cert-manager supports upgrades one minor version at a time. Helm itself would
# jump straight from an old release to cert_manager_version, so stop the apply
# before it when the installed release is more than one minor behind, and point
# at the stepwise upgrade. A cluster with no cert-manager passes.
resource "null_resource" "cert_manager_upgrade_guard" {
  count = var.install_cert_manager ? 1 : 0

  triggers = {
    target_version = var.cert_manager_version
  }

  provisioner "local-exec" {
    environment = merge(local.kubectl_env, {
      LS_CERT_MANAGER_VERSION   = var.cert_manager_version
      LS_CERT_MANAGER_MIN_MINOR = tostring(local.cert_manager_minor - 1)
    })
    command = <<-EOT
      ${local.kubectl_creds}
      current=$(kubectl get deployment cert-manager -n cert-manager \
        -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)
      if [ -z "$current" ]; then
        echo "cert-manager is not installed yet. Installing $LS_CERT_MANAGER_VERSION."
        exit 0
      fi
      current_minor=$(echo "$current" | sed -E 's/^v?1\.([0-9]+)\..*$/\1/')
      case "$current_minor" in
        ''|*[!0-9]*)
          echo "ERROR: cannot read the installed cert-manager version ('$current')." >&2
          exit 1 ;;
      esac
      if [ "$current_minor" -lt "$LS_CERT_MANAGER_MIN_MINOR" ]; then
        echo "ERROR: cert-manager $current is installed. cert-manager supports upgrades one" >&2
        echo "       minor version at a time, and this apply targets $LS_CERT_MANAGER_VERSION." >&2
        echo "       Run 'make cert-manager-upgrade' from modules/gcp first, then apply again." >&2
        exit 1
      fi
      echo "cert-manager $current -> $LS_CERT_MANAGER_VERSION: within one minor version."
    EOT
  }
}

resource "helm_release" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "oci://quay.io/jetstack/charts"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  values = [
    yamlencode(merge(
      {
        # crds.keep leaves the CRDs, and with them every Certificate and Issuer,
        # in place if the release is ever uninstalled.
        crds = {
          enabled = true
          keep    = true
        }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
        webhook = {
          resources = {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
        cainjector = {
          resources = {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }
      },
      # The Let's Encrypt HTTP-01 solver creates an HTTPRoute on the Gateway,
      # which cert-manager only does with Gateway API support on.
      var.cert_manager_enable_gateway_api ? {
        config = {
          apiVersion       = "controller.config.cert-manager.io/v1alpha1"
          kind             = "ControllerConfiguration"
          enableGatewayAPI = true
        }
      } : {},
    ))
  ]

  wait    = true
  timeout = 600

  depends_on = [null_resource.cert_manager_upgrade_guard, null_resource.gateway_api_crds_for_cert_manager]
}

#------------------------------------------------------------------------------
# Let's Encrypt ClusterIssuer (tls_certificate_source = "letsencrypt")
#------------------------------------------------------------------------------
locals {
  letsencrypt_issuer_yaml = local.letsencrypt_enabled ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.letsencrypt_email
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        solvers = [
          {
            http01 = {
              gatewayHTTPRoute = {
                parentRefs = [
                  {
                    name        = var.gateway_name
                    namespace   = "envoy-gateway-system"
                    sectionName = "http"
                  }
                ]
              }
            }
          }
        ]
      }
    }
  }) : ""
}

resource "local_file" "letsencrypt_issuer" {
  count = local.letsencrypt_enabled ? 1 : 0

  filename = "${path.module}/letsencrypt-issuer.yaml"
  content  = local.letsencrypt_issuer_yaml
}

# A failed apply fails terraform apply. It used to continue silently, which left
# an install with no issuer and no certificate and nothing in the apply output.
resource "null_resource" "apply_letsencrypt_issuer" {
  count = local.letsencrypt_enabled ? 1 : 0

  triggers = {
    issuer_content     = local_file.letsencrypt_issuer[0].content
    cert_manager_ready = helm_release.cert_manager[0].status
  }

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      ${local.kubectl_creds}
      # helm waits for the deployments, but the webhook can take a few more
      # seconds to serve, so retry the apply rather than sleep a fixed time.
      for i in $(seq 1 20); do
        if kubectl apply -f "${local_file.letsencrypt_issuer[0].filename}"; then
          echo "ClusterIssuer applied"
          exit 0
        fi
        echo "Retrying ClusterIssuer apply... ($i/20)"
        sleep 6
      done
      echo "ERROR: could not apply the Let's Encrypt ClusterIssuer." >&2
      exit 1
    EOT
  }

  depends_on = [local_file.letsencrypt_issuer, helm_release.cert_manager]
}

#------------------------------------------------------------------------------
# Certificate (tls_certificate_source = "letsencrypt" or "cert-manager")
# cert-manager writes the key pair to tls_secret_name in the LangSmith namespace,
# where the Gateway HTTPS listener reads it. With "cert-manager", the issuer is
# yours: Terraform names it and does not create it.
#------------------------------------------------------------------------------
locals {
  certificate_yaml = local.certificate_enabled ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.tls_secret_name
      namespace = kubernetes_namespace.langsmith.metadata[0].name
    }
    spec = {
      secretName = var.tls_secret_name
      issuerRef  = local.certificate_issuer_ref
      dnsNames = [
        var.langsmith_domain
      ]
    }
  }) : ""
}

resource "local_file" "certificate" {
  count = local.certificate_enabled ? 1 : 0

  filename = "${path.module}/certificate.yaml"
  content  = local.certificate_yaml
}

resource "null_resource" "apply_certificate" {
  count = local.certificate_enabled ? 1 : 0

  triggers = {
    certificate_content = local_file.certificate[0].content
    cert_manager_ready  = helm_release.cert_manager[0].status
    issuer_ready        = local.letsencrypt_enabled ? null_resource.apply_letsencrypt_issuer[0].id : ""
  }

  provisioner "local-exec" {
    environment = merge(local.kubectl_env, { LS_TLS_SECRET_NAME = var.tls_secret_name })
    command     = <<-EOT
      ${local.kubectl_creds}
      for i in $(seq 1 20); do
        if kubectl apply -f "${local_file.certificate[0].filename}"; then
          echo "Certificate applied"
          exit 0
        fi
        echo "Retrying Certificate apply... ($i/20)"
        sleep 6
      done
      echo "ERROR: could not apply the Certificate $LS_TLS_SECRET_NAME." >&2
      exit 1
    EOT
  }

  depends_on = [local_file.certificate, helm_release.cert_manager, null_resource.apply_letsencrypt_issuer]
}
