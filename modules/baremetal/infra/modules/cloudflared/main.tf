#------------------------------------------------------------------------------
# Cloudflare Tunnel connector (cloudflared) for a remotely-managed tunnel.
#
# The tunnel and its public hostname -> service rules live in the Cloudflare
# dashboard; this module only runs the connector. The pods dial out to the
# Cloudflare edge (QUIC 7844/udp, fallback HTTP/2 443/tcp): nothing listens on
# the LAN, no router port-forward, and the home IP never appears in DNS.
#
# Two replicas on different workers: each holds its own edge connections, so a
# drain or reboot doesn't take the site down. Runs as the image's nonroot user
# (65532) under the restricted Pod Security level.
#------------------------------------------------------------------------------

locals {
  name   = "cloudflared"
  labels = { "app.kubernetes.io/name" = local.name }
  uid    = 65532
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = { "pod-security.kubernetes.io/enforce" = "restricted" }
  }
}

resource "kubernetes_secret_v1" "token" {
  metadata {
    name      = "cloudflared-token"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    token = var.tunnel_token
  }
  type = "Opaque"
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
        # Roll the pods when the token changes; env from a Secret is read once.
        annotations = { "checksum/token" = sha256(var.tunnel_token) }
      }

      spec {
        # cloudflared never calls the Kubernetes API.
        automount_service_account_token = false

        security_context {
          run_as_user     = local.uid
          run_as_group    = local.uid
          run_as_non_root = true
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              topology_key = "kubernetes.io/hostname"
              label_selector {
                match_labels = local.labels
              }
            }
          }
        }

        container {
          name  = local.name
          image = var.image
          # --no-autoupdate: Kubernetes rolls the image, the binary must not
          # replace itself. /ready and /metrics serve the probes on :2000.
          args = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]

          # Read by `tunnel run`; keeps the token off the command line.
          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.token.metadata[0].name
                key  = "token"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 2000
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          # /ready is 200 once at least one edge connection is up.
          readiness_probe {
            http_get {
              path = "/ready"
              port = "metrics"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/ready"
              port = "metrics"
            }
            initial_delay_seconds = 30
            period_seconds        = 10
            failure_threshold     = 3
          }
        }
      }
    }
  }

  wait_for_rollout = true
}

# Voluntary evictions (drains, upgrades) must leave one connector running.
resource "kubernetes_pod_disruption_budget_v1" "this" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = local.labels
    }
  }
}
