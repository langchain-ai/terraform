#------------------------------------------------------------------------------
# RustFS: S3-compatible object storage (Apache 2.0), standing in for MinIO,
# whose community edition is no longer maintained (no public images).
#
# Single node, single drive: objects live on one Retain PVC at /data.
# Credentials are files mounted from a Secret (RUSTFS_*_KEY_FILE): never the
# image's default "rustfsadmin", never in env values or on the command line.
# Runs as the image's non-root user (uid 10001) under the restricted Pod
# Security level.
#------------------------------------------------------------------------------

locals {
  name      = "rustfs"
  labels    = merge({ "app.kubernetes.io/name" = local.name }, var.datastore_label)
  endpoint  = "http://${local.name}.${var.namespace}.svc.cluster.local:9000"
  uid       = 10001
  creds_dir = "/run/secrets/rustfs"

  restricted_container = {
    allow_privilege_escalation = false
    run_as_non_root            = true
    drop                       = ["ALL"]
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

resource "random_password" "access_key" {
  length  = 20
  special = false
}

resource "random_password" "secret_key" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "rustfs-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    "access-key" = random_password.access_key.result
    "secret-key" = random_password.secret_key.result
    # Same keys in AWS CLI format, for the bucket Job (AWS_SHARED_CREDENTIALS_FILE).
    "aws-credentials" = join("\n", [
      "[default]",
      "aws_access_key_id = ${random_password.access_key.result}",
      "aws_secret_access_key = ${random_password.secret_key.result}",
      "",
    ])
  }
  type = "Opaque"
}

# Headless, S3 API only. The web console (9001) isn't exposed; reach it with
# kubectl port-forward when needed.
resource "kubernetes_service_v1" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector   = { "app.kubernetes.io/name" = local.name }
    cluster_ip = "None"
    port {
      name        = "s3"
      port        = 9000
      target_port = 9000
    }
  }
}

resource "kubernetes_stateful_set_v1" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    service_name = kubernetes_service_v1.this.metadata[0].name
    replicas     = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = local.name }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        termination_grace_period_seconds = 30

        security_context {
          run_as_user     = local.uid
          run_as_group    = local.uid
          fs_group        = local.uid
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = var.datastore_label
                }
                namespace_selector {}
              }
            }
          }
        }

        container {
          name  = local.name
          image = var.image

          env {
            name  = "RUSTFS_VOLUMES"
            value = "/data"
          }
          env {
            name  = "RUSTFS_ACCESS_KEY_FILE"
            value = "${local.creds_dir}/access-key"
          }
          env {
            name  = "RUSTFS_SECRET_KEY_FILE"
            value = "${local.creds_dir}/secret-key"
          }
          # Empty = log to stdout (kubectl logs) instead of files under /logs.
          env {
            name  = "RUSTFS_OBS_LOG_DIRECTORY"
            value = ""
          }

          port {
            name           = "s3"
            container_port = 9000
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          security_context {
            allow_privilege_escalation = local.restricted_container.allow_privilege_escalation
            run_as_non_root            = local.restricted_container.run_as_non_root
            capabilities {
              drop = local.restricted_container.drop
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "credentials"
            mount_path = local.creds_dir
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "s3"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = "s3"
            }
            initial_delay_seconds = 60
            period_seconds        = 20
            failure_threshold     = 3
          }
        }

        volume {
          name = "credentials"
          secret {
            secret_name = kubernetes_secret_v1.this.metadata[0].name
            items {
              key  = "access-key"
              path = "access-key"
            }
            items {
              key  = "secret-key"
              path = "secret-key"
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class
        resources {
          requests = { storage = var.storage_size }
        }
      }
    }
  }

  wait_for_rollout = true
}

#------------------------------------------------------------------------------
# Buckets: one one-shot Job each (head-bucket first, so reruns are no-ops).
# No lifecycle rules: SmithDB manages its own retention and deletion.
#------------------------------------------------------------------------------
resource "kubernetes_job_v1" "bucket" {
  for_each = toset(concat([var.bucket], var.extra_buckets))

  metadata {
    name      = "create-bucket-${each.key}"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "${local.name}-bucket-init" }
      }

      spec {
        restart_policy = "OnFailure"

        security_context {
          run_as_user     = local.uid
          run_as_group    = local.uid
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "create-bucket"
          image   = var.aws_cli_image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            aws --endpoint-url "$S3_ENDPOINT" s3api head-bucket --bucket "$BUCKET" 2>/dev/null \
              && echo "bucket $BUCKET exists" \
              || { aws --endpoint-url "$S3_ENDPOINT" s3api create-bucket --bucket "$BUCKET" && echo "bucket $BUCKET created"; }
          EOT
          ]

          env {
            name  = "S3_ENDPOINT"
            value = local.endpoint
          }
          env {
            name  = "BUCKET"
            value = each.key
          }
          env {
            name  = "AWS_SHARED_CREDENTIALS_FILE"
            value = "${local.creds_dir}/aws-credentials"
          }
          # Any region works for a single-node S3 endpoint; the CLI needs one.
          env {
            name  = "AWS_DEFAULT_REGION"
            value = "us-east-1"
          }
          # aws-cli writes a cache under $HOME; the non-root user has none.
          env {
            name  = "HOME"
            value = "/tmp"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          security_context {
            allow_privilege_escalation = local.restricted_container.allow_privilege_escalation
            run_as_non_root            = local.restricted_container.run_as_non_root
            capabilities {
              drop = local.restricted_container.drop
            }
          }

          volume_mount {
            name       = "credentials"
            mount_path = local.creds_dir
            read_only  = true
          }
        }

        volume {
          name = "credentials"
          secret {
            secret_name = kubernetes_secret_v1.this.metadata[0].name
            items {
              key  = "aws-credentials"
              path = "aws-credentials"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
  }

  depends_on = [kubernetes_stateful_set_v1.this]
}

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-ingress"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_clients" {
  metadata {
    name      = "allow-s3-clients"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = local.name }
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = toset(concat([var.namespace], var.allowed_namespaces))
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
      ports {
        port     = "9000"
        protocol = "TCP"
      }
    }
  }
}
