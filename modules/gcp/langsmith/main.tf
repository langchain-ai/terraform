# LangSmith on GKE - Main Terraform Configuration
# This configuration creates all required GCP infrastructure for LangSmith
#
# Naming Convention: {prefix}-{environment}-{resource}-{suffix}
# Example: myco-prod-gke-a1b2c3d4
#
# Usage:
#   terraform init
#   terraform plan -var="project_id=your-project-id" -var="name_prefix=mycompany"
#   terraform apply -var="project_id=your-project-id" -var="name_prefix=mycompany"

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }

  # Uncomment to use remote state (RECOMMENDED for production and teams)
  # backend "gcs" {
  #   bucket = "your-terraform-state-bucket"
  #   prefix = "langsmith/state"
  # }
}

#------------------------------------------------------------------------------
# Providers
#------------------------------------------------------------------------------
provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = local.common_labels
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  default_labels = local.common_labels
}

# Configure Kubernetes provider
# Uses try() to fallback to module outputs if data source isn't available yet
# This allows plan to work even when cluster doesn't exist
provider "kubernetes" {
  host                   = try("https://${data.google_container_cluster.gke.endpoint}", "https://${module.gke_cluster.endpoint}")
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = try(base64decode(data.google_container_cluster.gke.master_auth[0].cluster_ca_certificate), base64decode(module.gke_cluster.ca_certificate))
}

# Configure Helm provider
provider "helm" {
  kubernetes {
    host                   = try("https://${data.google_container_cluster.gke.endpoint}", "https://${module.gke_cluster.endpoint}")
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = try(base64decode(data.google_container_cluster.gke.master_auth[0].cluster_ca_certificate), base64decode(module.gke_cluster.ca_certificate))
  }
}

#------------------------------------------------------------------------------
# Data Sources
#------------------------------------------------------------------------------
data "google_client_config" "default" {}

# Get project information
data "google_project" "current" {
  project_id = var.project_id
}

# Wait for GKE cluster to be fully ready and API server accessible
resource "null_resource" "wait_for_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for GKE cluster to be ready..."
      
      # Wait for cluster to be in RUNNING state
      for i in {1..60}; do
        STATUS=$(gcloud container clusters describe ${module.gke_cluster.cluster_name} \
          --region ${var.region} \
          --project ${var.project_id} \
          --format="value(status)" 2>/dev/null || echo "UNKNOWN")
        if [ "$STATUS" = "RUNNING" ]; then
          echo "Cluster status: RUNNING"
          break
        fi
        echo "Waiting for cluster status... ($i/60) - Current: $STATUS"
        sleep 10
      done
      
      # Wait for API server to be accessible
      echo "Waiting for API server to be accessible..."
      for i in {1..30}; do
        if gcloud container clusters get-credentials ${module.gke_cluster.cluster_name} \
          --region ${var.region} \
          --project ${var.project_id} >/dev/null 2>&1; then
          if kubectl cluster-info >/dev/null 2>&1; then
            echo "API server is accessible!"
            exit 0
          fi
        fi
        echo "Waiting for API server... ($i/30)"
        sleep 5
      done
      
      echo "ERROR: API server did not become accessible in time"
      exit 1
    EOT
  }

  depends_on = [module.gke_cluster]
}

# Get GKE cluster information (after it's ready)
data "google_container_cluster" "gke" {
  name     = module.gke_cluster.cluster_name
  location = var.region
  project  = var.project_id

  depends_on = [null_resource.wait_for_cluster]
}

#------------------------------------------------------------------------------
# Random Resources
#------------------------------------------------------------------------------
# Random suffix for unique resource names (prevents collisions)
resource "random_id" "suffix" {
  byte_length = 4

  keepers = {
    # Regenerate suffix if project or prefix changes
    project_id  = var.project_id
    name_prefix = var.name_prefix
    environment = var.environment
  }
}

#------------------------------------------------------------------------------
# Enable Required APIs
#------------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",            # GKE
    "compute.googleapis.com",              # Compute Engine
    "sqladmin.googleapis.com",             # Cloud SQL
    "redis.googleapis.com",                # Memorystore
    "storage.googleapis.com",              # Cloud Storage
    "servicenetworking.googleapis.com",    # Service Networking (VPC peering)
    "cloudresourcemanager.googleapis.com", # Resource Manager
    "iam.googleapis.com",                  # IAM
    "secretmanager.googleapis.com",        # Secret Manager
    "certificatemanager.googleapis.com",   # Certificate Manager
    "logging.googleapis.com",              # Cloud Logging
    "monitoring.googleapis.com",           # Cloud Monitoring
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false

  timeouts {
    create = "10m"
    update = "10m"
  }
}

#------------------------------------------------------------------------------
# Networking Module
#------------------------------------------------------------------------------
module "networking" {
  source = "../networking"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  # Use centralized naming
  vpc_name    = local.vpc_name
  subnet_name = local.subnet_name
  router_name = local.router_name
  nat_name    = local.nat_name

  # CIDR ranges
  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  # Private service connection (requires servicenetworking.networksAdmin role)
  # Always enable private service connection for external PostgreSQL and Redis
  enable_private_service_connection = var.postgres_source == "external" || var.redis_source == "external"

  # Labels
  labels = local.common_labels

  depends_on = [google_project_service.apis]
}

#------------------------------------------------------------------------------
# GKE Cluster Module
#------------------------------------------------------------------------------
module "gke_cluster" {
  source = "../gke-cluster"

  project_id  = var.project_id
  region      = var.region
  zone        = var.zone
  environment = var.environment

  # Use centralized naming
  cluster_name   = local.cluster_name
  node_pool_name = local.node_pool_name

  # Network configuration
  network_id          = module.networking.vpc_id
  subnet_id           = module.networking.subnet_id
  pods_range_name     = module.networking.pods_range_name
  services_range_name = module.networking.services_range_name

  # Cluster configuration
  use_autopilot           = var.gke_use_autopilot
  node_count              = var.gke_node_count
  min_node_count          = var.gke_min_nodes
  max_node_count          = var.gke_max_nodes
  machine_type            = var.gke_machine_type
  disk_size_gb            = var.gke_disk_size
  release_channel         = var.gke_release_channel
  deletion_protection     = var.gke_deletion_protection
  network_policy_provider = var.gke_network_policy_provider

  # Labels
  labels = local.common_labels

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Cloud SQL Module (only created when using external PostgreSQL)
#------------------------------------------------------------------------------
module "cloudsql" {
  source = "../cloudsql"
  count  = var.postgres_source == "external" ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  # Use centralized naming
  instance_name = local.postgres_instance_name
  database_name = local.postgres_database_name
  username      = local.postgres_user_name
  password      = var.postgres_password

  # Configuration
  database_version    = var.postgres_version
  tier                = var.postgres_tier
  disk_size           = var.postgres_disk_size
  high_availability   = var.postgres_high_availability
  deletion_protection = local.deletion_protection
  database_flags      = var.postgres_database_flags

  network_id                 = module.networking.vpc_id
  private_network_connection = module.networking.private_service_connection

  # Labels
  labels = local.common_labels

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Redis Module (only created when using external Redis)
# Memorystore Redis requires private service access
#------------------------------------------------------------------------------
module "redis" {
  source = "../redis"
  count  = var.redis_source == "external" ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  # Use centralized naming
  instance_name = local.redis_instance_name

  # Configuration
  memory_size_gb    = var.redis_memory_size
  redis_version     = var.redis_version
  high_availability = var.redis_high_availability

  # Network
  network_id = module.networking.vpc_id

  # Labels
  labels = local.common_labels

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Storage Module
#------------------------------------------------------------------------------
module "storage" {
  source = "../storage"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  # Use centralized naming
  bucket_name = local.bucket_name

  # Configuration
  ttl_short_days = var.storage_ttl_short_days
  ttl_long_days  = var.storage_ttl_long_days
  force_destroy  = var.storage_force_destroy

  # Labels
  labels = local.common_labels
}

#------------------------------------------------------------------------------
# K8s Bootstrap Module
#------------------------------------------------------------------------------
module "k8s_bootstrap" {
  source = "../k8s-bootstrap"

  project_id  = var.project_id
  environment = var.environment

  # Namespace configuration
  langsmith_namespace = var.langsmith_namespace

  # PostgreSQL connection - only when using external PostgreSQL
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/${module.cloudsql[0].database_name}" : ""

  # Redis connection - only when using external Redis
  use_managed_redis    = var.redis_source == "external"
  redis_connection_url = var.redis_source == "external" ? "redis://${module.redis[0].host}:${module.redis[0].port}" : ""

  # KEDA for LangSmith Deployment feature
  install_keda = var.enable_langsmith_deployment

  # TLS Configuration
  tls_certificate_source = var.tls_certificate_source
  install_cert_manager   = var.install_cert_manager || var.tls_certificate_source == "letsencrypt"
  letsencrypt_email      = var.letsencrypt_email

  # Existing TLS certificates (when tls_certificate_source = "existing")
  tls_certificate_crt = var.tls_certificate_crt
  tls_certificate_key = var.tls_certificate_key
  tls_secret_name     = var.tls_secret_name
  langsmith_domain    = var.langsmith_domain

  # Gateway name for cert-manager HTTP01 challenges
  gateway_name = var.install_ingress && var.ingress_type == "envoy" ? "${local.base_name}-gateway" : "langsmith-gateway"

  # License key (optional)
  langsmith_license_key = var.langsmith_license_key

  # ClickHouse configuration
  clickhouse_source    = var.clickhouse_source
  clickhouse_host      = var.clickhouse_host
  clickhouse_port      = var.clickhouse_port
  clickhouse_http_port = var.clickhouse_http_port
  clickhouse_user      = var.clickhouse_user
  clickhouse_password  = var.clickhouse_password
  clickhouse_database  = var.clickhouse_database
  clickhouse_tls       = var.clickhouse_tls
  clickhouse_ca_cert   = var.clickhouse_ca_cert

  # Labels
  labels = local.common_labels

  depends_on = [null_resource.wait_for_cluster, module.cloudsql]
}

#------------------------------------------------------------------------------
# Ingress Module (Optional)
#------------------------------------------------------------------------------
module "ingress" {
  source = "../ingress"
  count  = var.install_ingress ? 1 : 0

  ingress_type        = var.ingress_type
  langsmith_domain    = var.langsmith_domain
  langsmith_namespace = var.langsmith_namespace

  # Use centralized naming for gateway
  gateway_name = "${local.base_name}-gateway"

  # TLS configuration for Gateway HTTPS listener
  tls_certificate_source = var.tls_certificate_source
  tls_secret_name        = var.tls_secret_name

  depends_on = [null_resource.wait_for_cluster, module.k8s_bootstrap]
}
