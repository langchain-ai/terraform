# K8s Bootstrap Module - Namespaces, Service Accounts, Secrets, and KEDA

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
# Kubernetes Service Account with Workload Identity
#------------------------------------------------------------------------------
resource "kubernetes_service_account" "langsmith" {
  metadata {
    name      = "langsmith-ksa"
    namespace = kubernetes_namespace.langsmith.metadata[0].name

    annotations = {
      "iam.gke.io/gcp-service-account" = var.service_account_email
    }

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
resource "kubernetes_resource_quota" "langsmith" {
  metadata {
    name      = "langsmith-quota"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "20"
      "requests.memory" = "40Gi"
      "limits.cpu"      = "40"
      "limits.memory"   = "80Gi"
      "pods"            = "100"
    }
  }
}

#------------------------------------------------------------------------------
# Network Policy (restrict traffic)
#------------------------------------------------------------------------------
resource "kubernetes_network_policy" "langsmith_default" {
  metadata {
    name      = "langsmith-default"
    namespace = kubernetes_namespace.langsmith.metadata[0].name
  }

  spec {
    pod_selector {}

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
