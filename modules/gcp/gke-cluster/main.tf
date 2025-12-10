# GKE Cluster Module - Kubernetes Cluster Infrastructure

locals {
  node_pool_name = var.node_pool_name != "" ? var.node_pool_name : "${var.cluster_name}-nodepool"
}

#------------------------------------------------------------------------------
# GKE Cluster (Standard Mode)
#------------------------------------------------------------------------------
resource "google_container_cluster" "primary" {
  count = var.use_autopilot ? 0 : 1

  name                = var.cluster_name
  project             = var.project_id
  location            = var.region
  description         = "GKE cluster for LangSmith (${var.environment})"
  deletion_protection = var.deletion_protection

  # We manage node pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  # Network configuration
  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Master authorized networks
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "All networks"
    }
  }

  # Release channel for automatic upgrades
  release_channel {
    channel = var.release_channel
  }

  # Addons
  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  # Network policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Logging and monitoring
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  # Binary authorization
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Security
  enable_shielded_nodes = true

  # Resource labels
  resource_labels = var.labels

  lifecycle {
    ignore_changes = [
      node_pool,
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
# GKE Node Pool (Standard Mode)
#------------------------------------------------------------------------------
resource "google_container_node_pool" "primary_nodes" {
  count = var.use_autopilot ? 0 : 1

  name       = local.node_pool_name
  project    = var.project_id
  location   = var.region
  cluster    = google_container_cluster.primary[0].name
  node_count = var.node_count

  # Autoscaling
  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  # Node management
  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Node configuration
  node_config {
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb
    disk_type    = "pd-ssd"

    # OAuth scopes
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    # Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded instance
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Labels
    labels = merge(var.labels, {
      "node-pool" = local.node_pool_name
    })

    # Taints (optional)
    # taint {
    #   key    = "dedicated"
    #   value  = "langsmith"
    #   effect = "NO_SCHEDULE"
    # }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

#------------------------------------------------------------------------------
# GKE Autopilot Cluster
#------------------------------------------------------------------------------
resource "google_container_cluster" "autopilot" {
  count = var.use_autopilot ? 1 : 0

  name                = var.cluster_name
  project             = var.project_id
  location            = var.region
  description         = "GKE Autopilot cluster for LangSmith (${var.environment})"
  deletion_protection = var.deletion_protection

  # Enable Autopilot
  enable_autopilot = true

  # Network configuration
  network    = var.network_id
  subnetwork = var.subnet_id

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity (always enabled in Autopilot)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # Master authorized networks
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "All networks"
    }
  }

  # Release channel
  release_channel {
    channel = var.release_channel
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  # Resource labels
  resource_labels = var.labels

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
