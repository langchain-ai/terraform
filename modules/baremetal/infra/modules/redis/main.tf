#------------------------------------------------------------------------------
# One Redis instance in its own namespace.
#
# The password lives in a rendered redis.conf (a Secret mounted as a file), not
# on the command line, where root on the node could read it in /proc.
#
# maxmemory is 75% of the container limit: an RDB save forks Redis, and every
# key written during the save is copied (copy-on-write), so memory briefly
# rises above the data size. noeviction makes a full Redis refuse writes
# (visible errors) instead of silently dropping queued work.
#------------------------------------------------------------------------------

locals {
  name         = "redis"
  labels       = merge({ "app.kubernetes.io/name" = local.name }, var.datastore_label)
  maxmemory_mb = floor(var.memory_limit_mi * 3 / 4)

  persistence_lines = var.persistence == "aof" ? [
    "appendonly yes",
    "appendfsync everysec",
    "save \"\"",
    ] : [
    "appendonly no",
    "save 900 1",
    "save 300 10",
    "save 60 10000",
  ]
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = { "pod-security.kubernetes.io/enforce" = "baseline" }
  }
}

resource "random_password" "this" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "redis-config"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    # Built from a list of lines: a <<- heredoc doesn't strip indentation from
    # interpolated multi-line text, so persistence_conf would keep stray spaces.
    "redis.conf" = join("\n", concat([
      "bind 0.0.0.0",
      "port 6379",
      "dir /data",
      "databases 16",
      "requirepass ${random_password.this.result}",
      "maxmemory ${local.maxmemory_mb}mb",
      "maxmemory-policy noeviction",
      # LangSmith writes ~2.5 short-TTL keys per run. With the defaults (hz 10,
      # active-expire-effort 1) expiry fell behind at ~800 runs/s: 23% of keys
      # were expired but not freed, ~1 GB of a 3 GiB Redis (measured under load).
      # These freed it in seconds for ~0.3 CPU.
      "hz 50",
      "active-expire-effort 5",
    ], local.persistence_lines, [""]))
    # Read by redis-cli in the probes only (REDISCLI_AUTH), never by redis-server.
    REDISCLI_AUTH = random_password.this.result
  }
  type = "Opaque"
}

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
      name        = "redis"
      port        = 6379
      target_port = 6379
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
        annotations = {
          # Restart Redis when its config changes.
          "checksum/config" = sha256(kubernetes_secret_v1.this.data["redis.conf"])
        }
      }

      spec {
        # SIGTERM makes Redis save (RDB) or fsync (AOF) before exiting.
        termination_grace_period_seconds = 30

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
          # args (not command): command would replace the image ENTRYPOINT
          # (docker-entrypoint.sh), which chowns /data and drops to the redis
          # user (uid 999). With command, redis-server runs as root.
          args = ["redis-server", "/usr/local/etc/redis/redis.conf"]

          env {
            name = "REDISCLI_AUTH"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.this.metadata[0].name
                key  = "REDISCLI_AUTH"
              }
            }
          }

          port {
            name           = "redis"
            container_port = 6379
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/redis"
            read_only  = true
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            period_seconds = 10
          }
          # Redis restarts fast and reloads from /data, so a liveness probe is
          # safe here (unlike Postgres crash recovery).
          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 30
            period_seconds        = 20
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          secret {
            secret_name = kubernetes_secret_v1.this.metadata[0].name
            items {
              key  = "redis.conf"
              path = "redis.conf"
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
    name      = "allow-redis-clients"
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
        port     = "6379"
        protocol = "TCP"
      }
    }
  }
}
