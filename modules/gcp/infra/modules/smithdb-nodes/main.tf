# Dedicated GKE node pools for SmithDB.
#
# Both pools are tainted, so nothing else lands on them and the cluster
# autoscaler can hold them at zero until SmithDB pods with matching tolerations
# appear. The labels and taints intentionally mirror the AWS Karpenter NodePools
# (smithdb-local/instance-store and smithdb-local/compute) so one Helm values
# overlay works on both clouds.

locals {
  instance_store_pool_name = "${var.name_prefix}-smithdb-lssd"
  compute_pool_name        = "${var.name_prefix}-smithdb-compute"

  common_node_labels = merge(var.labels, {
    "langsmith-component" = "smithdb"
  })
}

#------------------------------------------------------------------------------
# Instance-store pool: query, ingestion, and compactionWorker.
#
# ephemeral_storage_local_ssd_config is the mode that matters. It combines the
# Local SSDs into the filesystem kubelet uses, so the capacity shows up as node
# allocatable ephemeral-storage and backs emptyDir. Local SSD-backed *raw block*
# storage does not do this, and a disk mounted at some other host path does not
# back emptyDir at all — SmithDB's cache would silently fall back to the boot
# disk.
#------------------------------------------------------------------------------
resource "google_container_node_pool" "instance_store" {
  name           = local.instance_store_pool_name
  project        = var.project_id
  location       = var.region
  cluster        = var.cluster_name
  node_locations = length(var.node_locations) > 0 ? var.node_locations : null

  initial_node_count = var.instance_store_min_nodes

  autoscaling {
    min_node_count = var.instance_store_min_nodes
    max_node_count = var.instance_store_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = var.release_channel_auto_upgrade
  }

  node_config {
    machine_type    = var.instance_store_machine_type
    disk_size_gb    = var.instance_store_disk_size_gb
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = var.node_service_account_email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    dynamic "ephemeral_storage_local_ssd_config" {
      for_each = var.instance_store_local_ssd_count > 0 ? [1] : []
      content {
        local_ssd_count = var.instance_store_local_ssd_count
      }
    }

    # Required for the SmithDB pods to assume their GCP service account.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = merge(local.common_node_labels, {
      "node-pool"                    = local.instance_store_pool_name
      "smithdb-local/instance-store" = "true"
    })

    taint {
      key    = "smithdb-local/instance-store"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

#------------------------------------------------------------------------------
# Compute pool: compaction and clusterManager. No Local SSD — these components
# coordinate work rather than serving from the cache.
#------------------------------------------------------------------------------
resource "google_container_node_pool" "compute" {
  name           = local.compute_pool_name
  project        = var.project_id
  location       = var.region
  cluster        = var.cluster_name
  node_locations = length(var.node_locations) > 0 ? var.node_locations : null

  initial_node_count = var.compute_min_nodes

  autoscaling {
    min_node_count = var.compute_min_nodes
    max_node_count = var.compute_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = var.release_channel_auto_upgrade
  }

  node_config {
    machine_type    = var.compute_machine_type
    disk_size_gb    = var.compute_disk_size_gb
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = var.node_service_account_email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = merge(local.common_node_labels, {
      "node-pool"             = local.compute_pool_name
      "smithdb-local/compute" = "true"
    })

    taint {
      key    = "smithdb-local/compute"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
    ]
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
