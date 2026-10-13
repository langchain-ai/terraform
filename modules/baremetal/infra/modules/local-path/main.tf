#------------------------------------------------------------------------------
# Rancher local-path-provisioner, translated from the upstream manifest
# (deploy/local-path-storage.yaml at the pinned tag) into Terraform resources.
#
# How it works: when a PVC that uses one of these StorageClasses gets a pod,
# the provisioner starts a short-lived helper pod on that pod's node, which
# runs `setup` (mkdir) under node_path. The PV is a hostPath-style volume
# pinned to that node. Deleting the PVC runs `teardown` (rm -rf) only when the
# class's reclaimPolicy is Delete.
#------------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = "local-path-storage"
    labels = {
      # The helper pod mounts a hostPath, which the baseline and restricted
      # Pod Security levels forbid. Say so explicitly for this namespace.
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubernetes_service_account_v1" "this" {
  metadata {
    name      = "local-path-provisioner-service-account"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
}

# Helper pods are created and deleted in this namespace only.
resource "kubernetes_role_v1" "this" {
  metadata {
    name      = "local-path-provisioner-role"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "patch", "update", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "this" {
  metadata {
    name      = "local-path-provisioner-bind"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.this.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this.metadata[0].name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
}

# Cluster-wide: watch PVCs everywhere, create the PVs that satisfy them.
resource "kubernetes_cluster_role_v1" "this" {
  metadata {
    name = "local-path-provisioner-role"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumeclaims", "configmaps", "pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = [""]
    resources  = ["persistentvolumes"]
    verbs      = ["get", "list", "watch", "create", "patch", "update", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  metadata {
    name = "local-path-provisioner-bind"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this.metadata[0].name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
}

resource "kubernetes_config_map_v1" "this" {
  metadata {
    name      = "local-path-config"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    "config.json" = jsonencode({
      nodePathMap = [{
        node  = "DEFAULT_PATH_FOR_NON_LISTED_NODES"
        paths = [var.node_path]
      }]
    })
    setup    = <<-EOT
      #!/bin/sh
      set -eu
      mkdir -m 0777 -p "$VOL_DIR"
    EOT
    teardown = <<-EOT
      #!/bin/sh
      set -eu
      rm -rf "$VOL_DIR"
    EOT
    "helperPod.yaml" = yamlencode({
      apiVersion = "v1"
      kind       = "Pod"
      metadata   = { name = "helper-pod" }
      spec = {
        priorityClassName = "system-node-critical"
        tolerations       = [{ key = "node.kubernetes.io/disk-pressure", operator = "Exists", effect = "NoSchedule" }]
        containers = [{
          name            = "helper-pod"
          image           = var.helper_image
          imagePullPolicy = "IfNotPresent"
        }]
      }
    })
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = "local-path-provisioner"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "local-path-provisioner" }
    }

    template {
      metadata {
        labels = { app = "local-path-provisioner" }
        annotations = {
          # Roll the pod when the config changes; the provisioner reads it at start.
          "checksum/config" = sha256(jsonencode(kubernetes_config_map_v1.this.data))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.this.metadata[0].name

        container {
          name              = "local-path-provisioner"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["local-path-provisioner", "--debug", "start", "--config", "/etc/config/config.json"]

          port {
            name           = "health"
            container_port = 8080
          }

          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref {
                field_path = "metadata.namespace"
              }
            }
          }
          env {
            name  = "CONFIG_MOUNT_PATH"
            value = "/etc/config/"
          }
          env {
            name  = "HEALTH_PORT"
            value = "8080"
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          startup_probe {
            http_get {
              path = "/health"
              port = "health"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            failure_threshold     = 12
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = "health"
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/ready"
              port = "health"
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/config/"
          }
        }

        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map_v1.this.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_cluster_role_binding_v1.this, kubernetes_role_binding_v1.this]
}

#------------------------------------------------------------------------------
# StorageClasses. WaitForFirstConsumer: the PV is created only once a pod is
# scheduled, on that pod's node, so the scheduler (not the provisioner) picks
# where the data lives.
#------------------------------------------------------------------------------

# Default class: deleting the PVC deletes the data (rm -rf on the node).
# For caches and anything rebuildable.
resource "kubernetes_storage_class_v1" "delete" {
  metadata {
    name = "local-path"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner = "rancher.io/local-path"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"
  # local-path can't resize volumes (it doesn't enforce size at all). The
  # provider defaults this to true, unlike Kubernetes, so set it explicitly.
  allow_volume_expansion = false
}

# Datastores: deleting the PVC keeps the PV and its directory (Released).
# Recover or clean up by hand. Postgres, Redis, and MinIO use this class.
resource "kubernetes_storage_class_v1" "retain" {
  metadata {
    name = "local-path-retain"
  }
  storage_provisioner    = "rancher.io/local-path"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = false
}
