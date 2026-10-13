#------------------------------------------------------------------------------
# One Postgres instance in its own namespace: StatefulSet + PVC on the Retain
# class, a generated password, a headless Service, and a NetworkPolicy that
# only lets allowed namespaces reach 5432.
#
# Plain StatefulSet on the official image (no Bitnami, no operator), adapted
# from the OCP reference minus its OpenShift-only SCC / privileged settings.
#------------------------------------------------------------------------------

locals {
  name   = "postgres"
  labels = merge({ "app.kubernetes.io/name" = local.name }, var.datastore_label)

  # Size Postgres' own memory from the container limit (Lesson 00: memory
  # isn't compressible; exceed the limit and the kernel OOMKills the pod).
  shared_buffers_mb       = floor(var.memory_limit_mi / 4)
  effective_cache_size_mb = floor(var.memory_limit_mi / 2)
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = { "pod-security.kubernetes.io/enforce" = "baseline" }
  }
}

# URL-safe (no special characters) so it can sit inside a connection URL.
resource "random_password" "this" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "this" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    POSTGRES_USER     = var.username
    POSTGRES_PASSWORD = random_password.this.result
    POSTGRES_DB       = var.database
  }
  type = "Opaque"
}

# Headless: the StatefulSet gets a stable DNS name
# (postgres.<namespace>.svc.cluster.local) without load balancing.
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
      name        = "postgres"
      port        = 5432
      target_port = 5432
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
        # Clean shutdown flushes WAL; give it time before SIGKILL.
        termination_grace_period_seconds = 60

        # Prefer a node without another datastore (noisy-neighbor disks).
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
          args = [
            "-c", "shared_buffers=${local.shared_buffers_mb}MB",
            "-c", "effective_cache_size=${local.effective_cache_size_mb}MB",
            "-c", "max_connections=${var.max_connections}",
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.this.metadata[0].name
            }
          }

          port {
            name           = "postgres"
            container_port = 5432
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # Postgres 18 images keep data under /var/lib/postgresql/18/docker and
          # expect the volume at the parent; mounting .../data fails to start.
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql"
          }

          # No liveness probe on purpose: it could kill Postgres during a long
          # crash recovery. Startup waits for first init; readiness gates traffic.
          startup_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            }
            period_seconds    = 5
            failure_threshold = 60
          }
          readiness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""]
            }
            period_seconds = 10
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

  # A StatefulSet apply returns before the pod is ready; wait for it.
  wait_for_rollout = true
}

#------------------------------------------------------------------------------
# NetworkPolicy (enforced by Calico): nothing reaches this namespace except
# 5432 from the allowed namespaces and from inside the namespace itself.
#------------------------------------------------------------------------------
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
    name      = "allow-postgres-clients"
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
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}

#------------------------------------------------------------------------------
# Extra databases (one per standalone product on the shared instance, like
# google_sql_database in modules/gcp). A Job is the bare-metal stand-in for the
# cloud API: it creates only the databases that don't exist yet, so reruns are
# no-ops. The Job name hashes the list, so adding a database runs a new Job.
#
# Names reach SQL as a psql variable (:'dbs', quoted by psql) from an
# environment variable, never pasted into the SQL text, and are validated
# against ^[a-z_][a-z0-9_]*$ in variables.tf.
#------------------------------------------------------------------------------
locals {
  extra_databases_sorted = sort(var.extra_databases)
  extra_databases_hash   = substr(sha256(join(",", local.extra_databases_sorted)), 0, 8)
}

resource "kubernetes_job_v1" "create_databases" {
  count = length(var.extra_databases) > 0 ? 1 : 0

  metadata {
    name      = "create-databases-${local.extra_databases_hash}"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 86400

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "postgres-create-databases" }
      }

      spec {
        restart_policy = "OnFailure"

        security_context {
          run_as_user     = 999
          run_as_group    = 999
          run_as_non_root = true
        }

        container {
          name    = "psql"
          image   = var.image
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -v dbs="$DATABASES" <<'SQL'
            SELECT format('CREATE DATABASE %I OWNER %I', d, current_user)
            FROM unnest(string_to_array(:'dbs', ',')) AS d
            WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = d)
            \gexec
            SQL
            echo "databases present: $DATABASES"
          EOT
          ]

          env {
            name  = "PGHOST"
            value = "${kubernetes_service_v1.this.metadata[0].name}.${var.namespace}.svc.cluster.local"
          }
          env {
            name  = "PGUSER"
            value = var.username
          }
          env {
            name  = "PGDATABASE"
            value = var.database
          }
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.this.metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "DATABASES"
            value = join(",", local.extra_databases_sorted)
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
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
