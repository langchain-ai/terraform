# Networking Module - VPC, Subnets, and Private Service Connection

locals {
  # Use provided names or derive from vpc_name
  subnet_name = var.subnet_name != "" ? var.subnet_name : "${var.vpc_name}-subnet"
  router_name = var.router_name != "" ? var.router_name : "${var.vpc_name}-router"
  nat_name    = var.nat_name != "" ? var.nat_name : "${var.vpc_name}-nat"
}

#------------------------------------------------------------------------------
# VPC Network
#------------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "VPC network for LangSmith (${var.environment})"
}

#------------------------------------------------------------------------------
# Subnet with Secondary Ranges for GKE
#------------------------------------------------------------------------------
resource "google_compute_subnetwork" "subnet" {
  name                     = local.subnet_name
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
  description              = "Subnet for LangSmith GKE cluster (${var.environment})"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

#------------------------------------------------------------------------------
# Cloud Router for NAT
#------------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name        = local.router_name
  project     = var.project_id
  region      = var.region
  network     = google_compute_network.vpc.id
  description = "Cloud Router for LangSmith NAT (${var.environment})"
}

#------------------------------------------------------------------------------
# Cloud NAT for outbound internet access
#------------------------------------------------------------------------------
resource "google_compute_router_nat" "nat" {
  name                               = local.nat_name
  project                            = var.project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

#------------------------------------------------------------------------------
# Private Service Connection for Cloud SQL and Redis
# Only created when enable_private_service_connection = true
# Requires servicenetworking.networksAdmin role
#------------------------------------------------------------------------------
resource "google_compute_global_address" "private_ip_range" {
  count = var.enable_private_service_connection ? 1 : 0

  name          = "${var.vpc_name}-private-ip"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
  description   = "Private IP range for VPC peering (${var.environment})"
}

resource "google_service_networking_connection" "private_vpc_connection" {
  count = var.enable_private_service_connection ? 1 : 0

  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range[0].name]

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

#------------------------------------------------------------------------------
# Firewall Rules
#------------------------------------------------------------------------------
resource "google_compute_firewall" "allow_internal" {
  name        = "${var.vpc_name}-allow-internal"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow internal traffic within VPC"

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
}

resource "google_compute_firewall" "allow_health_checks" {
  name        = "${var.vpc_name}-allow-health-checks"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow GCP health check probes"

  allow {
    protocol = "tcp"
  }

  # GCP health check ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

# Allow IAP for SSH (optional but useful for debugging)
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "${var.vpc_name}-allow-iap-ssh"
  project     = var.project_id
  network     = google_compute_network.vpc.name
  description = "Allow SSH via Identity-Aware Proxy"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP's TCP forwarding IP range
  source_ranges = ["35.235.240.0/20"]
}
