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
    gcloud container clusters get-credentials ${var.cluster_name} \
      --region ${var.region} --project ${var.project_id} --quiet || exit 1
  EOT
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

  # The headroom is doubled on the limits side. SmithDB sets requests equal to
  # limits, so the requests side binds first, but a feature admitted on requests
  # must not then be rejected on limits. Doubling also keeps the same 2x
  # requests-to-limits ratio the base figures use.
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
# The JuiceFS CSI driver the sandbox feature depends on uses both: the
# juicefs-csi-node DaemonSet is system-node-critical and the
# juicefs-csi-controller StatefulSet is system-cluster-critical. Without this
# quota neither is ever created — the DaemonSet reports desired N, current 0
# with the rejection recorded only on the controller object, csi.juicefs.com
# never registers on any node, and sandbox-host sits in ContainerCreating on a
# FailedMount that names a missing CSI driver rather than a quota.
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
# cert-manager - Automatic TLS Certificate Management
# Provisions Let's Encrypt certificates automatically
# Reference: https://cert-manager.io/docs/
#------------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  values = [
    yamlencode({
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
    })
  ]

  wait    = true
  timeout = 600
}

#------------------------------------------------------------------------------
# Let's Encrypt ClusterIssuer
#------------------------------------------------------------------------------
locals {
  letsencrypt_issuer_yaml = var.install_cert_manager && var.letsencrypt_email != "" ? yamlencode({
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
                    name      = var.gateway_name
                    namespace = "envoy-gateway-system"
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
  count = var.install_cert_manager && var.letsencrypt_email != "" ? 1 : 0

  filename = "${path.module}/letsencrypt-issuer.yaml"
  content  = local.letsencrypt_issuer_yaml
}

resource "time_sleep" "wait_for_cert_manager" {
  count = var.install_cert_manager && var.letsencrypt_email != "" ? 1 : 0

  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

resource "null_resource" "apply_letsencrypt_issuer" {
  count = var.install_cert_manager && var.letsencrypt_email != "" ? 1 : 0

  triggers = {
    issuer_content     = local_file.letsencrypt_issuer[0].content
    cert_manager_ready = helm_release.cert_manager[0].status
  }

  provisioner "local-exec" {
    command    = <<-EOT
      ${local.kubectl_creds}
      # Wait for cert-manager CRDs to be available
      for i in {1..30}; do
        if kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for cert-manager CRDs... ($i/30)"
        sleep 2
      done
      
      # Apply the ClusterIssuer with retry
      for i in {1..5}; do
        if kubectl apply -f ${local_file.letsencrypt_issuer[0].filename}; then
          echo "ClusterIssuer applied successfully"
          exit 0
        fi
        echo "Retrying ClusterIssuer apply... ($i/5)"
        sleep 3
      done
      
      echo "ERROR: Failed to apply ClusterIssuer after 5 attempts"
      exit 1
    EOT
    on_failure = continue
  }

  depends_on = [time_sleep.wait_for_cert_manager, local_file.letsencrypt_issuer, helm_release.cert_manager]
}

#------------------------------------------------------------------------------
# Let's Encrypt Certificate
#------------------------------------------------------------------------------
locals {
  certificate_yaml = var.tls_certificate_source == "letsencrypt" && var.langsmith_domain != "" && var.tls_secret_name != "" ? yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = var.tls_secret_name
      namespace = kubernetes_namespace.langsmith.metadata[0].name
    }
    spec = {
      secretName = var.tls_secret_name
      issuerRef = {
        name = "letsencrypt-prod"
        kind = "ClusterIssuer"
      }
      dnsNames = [
        var.langsmith_domain
      ]
    }
  }) : ""
}

resource "local_file" "certificate" {
  count = var.tls_certificate_source == "letsencrypt" && var.langsmith_domain != "" && var.tls_secret_name != "" ? 1 : 0

  filename = "${path.module}/certificate.yaml"
  content  = local.certificate_yaml
}

resource "time_sleep" "wait_for_cluster_issuer" {
  count = var.tls_certificate_source == "letsencrypt" && var.langsmith_domain != "" && var.tls_secret_name != "" ? 1 : 0

  depends_on      = [null_resource.apply_letsencrypt_issuer]
  create_duration = "10s"
}

resource "null_resource" "apply_certificate" {
  count = var.tls_certificate_source == "letsencrypt" && var.langsmith_domain != "" && var.tls_secret_name != "" ? 1 : 0

  triggers = {
    certificate_content  = local_file.certificate[0].content
    cluster_issuer_ready = null_resource.apply_letsencrypt_issuer[0].id
  }

  provisioner "local-exec" {
    command    = <<-EOT
      ${local.kubectl_creds}
      # Wait for Certificate CRD to be available
      for i in {1..30}; do
        if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
          break
        fi
        echo "Waiting for Certificate CRD... ($i/30)"
        sleep 2
      done
      
      # Apply the Certificate with retry
      for i in {1..5}; do
        if kubectl apply -f ${local_file.certificate[0].filename}; then
          echo "Certificate applied successfully"
          exit 0
        fi
        echo "Retrying Certificate apply... ($i/5)"
        sleep 3
      done
      
      echo "ERROR: Failed to apply Certificate after 5 attempts"
      exit 1
    EOT
    on_failure = continue
  }

  depends_on = [time_sleep.wait_for_cluster_issuer, local_file.certificate, null_resource.apply_letsencrypt_issuer]
}
