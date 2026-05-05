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

# Configure Kubernetes provider.
# Use module outputs directly so first plan works before cluster creation.
provider "kubernetes" {
  host                   = "https://${module.gke_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke_cluster.ca_certificate)
}

# Configure Helm provider
provider "helm" {
  kubernetes {
    host                   = "https://${module.gke_cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke_cluster.ca_certificate)
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

# Wait for GKE API server to be fully ready after cluster creation.
# The google_container_cluster resource waits until RUNNING state, but the
# API server needs a short additional window before accepting requests.
# time_sleep works in CI environments without gcloud/kubectl in PATH.
resource "time_sleep" "wait_for_cluster" {
  create_duration = "90s"

  depends_on = [module.gke_cluster]
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

locals {
  # Must match modules/iam account_id format.
  workload_identity_gsa_account_id = "${var.name_prefix}-langsmith"
  workload_identity_gsa_email      = "${local.workload_identity_gsa_account_id}@${var.project_id}.iam.gserviceaccount.com"
}

#------------------------------------------------------------------------------
# Input Validation
# Cross-variable checks that can't be expressed in variable validation blocks.
# These fire at plan time with a clear error message.
#------------------------------------------------------------------------------
resource "terraform_data" "validate_inputs" {
  depends_on = [google_project_service.apis]

  lifecycle {
    precondition {
      condition     = var.postgres_source != "external" || var.postgres_password != ""
      error_message = "postgres_password is required when postgres_source = 'external'. Set TF_VAR_postgres_password in your environment."
    }

    precondition {
      condition     = var.tls_certificate_source != "letsencrypt" || var.letsencrypt_email != ""
      error_message = "letsencrypt_email is required when tls_certificate_source = 'letsencrypt'."
    }

    precondition {
      condition     = var.tls_certificate_source != "existing" || (var.tls_certificate_crt != "" && var.tls_certificate_key != "")
      error_message = "tls_certificate_crt and tls_certificate_key are required when tls_certificate_source = 'existing'."
    }

    precondition {
      condition     = !var.enable_agent_builder || var.enable_deployments
      error_message = "enable_agent_builder requires enable_deployments = true. Agent Builder depends on the Deployments feature."
    }

    precondition {
      condition     = var.clickhouse_source == "in-cluster" || var.clickhouse_host != ""
      error_message = "clickhouse_host is required when clickhouse_source is 'langsmith-managed' or 'external'."
    }

    precondition {
      condition     = var.clickhouse_source == "in-cluster" || var.clickhouse_password != ""
      error_message = "clickhouse_password is required when clickhouse_source is 'langsmith-managed' or 'external'."
    }

    precondition {
      condition     = !var.enable_dns_module || var.dns_create_zone || var.dns_existing_zone_name != ""
      error_message = "dns_existing_zone_name is required when enable_dns_module = true and dns_create_zone = false."
    }

    precondition {
      condition     = !var.enable_polly || var.enable_deployments
      error_message = "enable_polly requires enable_deployments = true. Polly depends on the Deployments feature."
    }
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
  source = "./modules/networking"

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
  source = "./modules/k8s-cluster"

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

  # Master authorized networks — empty list keeps the master publicly reachable
  # for Terraform-driven Helm/kubectl steps. Populate var.gke_master_authorized_cidrs
  # in terraform.tfvars to restrict to operator/CI CIDRs.
  master_authorized_cidrs = var.gke_master_authorized_cidrs

  # Labels
  labels = local.common_labels

  depends_on = [module.networking]
}

#------------------------------------------------------------------------------
# Cloud SQL Module (only created when using external PostgreSQL)
#------------------------------------------------------------------------------
module "cloudsql" {
  source = "./modules/postgres"
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
  deletion_protection = var.postgres_deletion_protection
  database_flags      = var.postgres_database_flags
  ssl_mode            = var.postgres_ssl_mode

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
  source = "./modules/redis"
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
  prevent_destroy   = var.redis_prevent_destroy

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
  source = "./modules/storage"

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
# IAM Module (Optional)
#------------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"
  count  = var.enable_gcp_iam_module ? 1 : 0

  gcp_project = var.project_id
  project     = var.name_prefix
  environment = var.environment

  namespace            = var.langsmith_namespace
  service_account_name = "langsmith-ksa"
  workload_identity_service_accounts = [
    "langsmith-ksa",
    "langsmith-backend",
    "langsmith-platform-backend",
    "langsmith-host-backend",
    "langsmith-queue",
    "langsmith-ingest-queue",
    "langsmith-listener",
    "langsmith-agent-builder-tool-server",
    "langsmith-agent-builder-trigger-server",
    "langsmith-ace-backend",
    "langsmith-frontend",
    "langsmith-playground",
    "langsmith-operator",
  ]
  gcs_bucket_name = module.storage.bucket_name
}

#------------------------------------------------------------------------------
# Secret Manager Module (Optional)
#------------------------------------------------------------------------------
module "secrets" {
  source = "./modules/secrets"
  count  = var.enable_secret_manager_module ? 1 : 0

  gcp_project = var.project_id
  project     = var.name_prefix
  environment = var.environment

  postgres_password = var.postgres_source == "external" ? module.cloudsql[0].password : var.postgres_password
  redis_password    = ""
}

#------------------------------------------------------------------------------
# DNS Module (Optional)
#------------------------------------------------------------------------------
module "dns" {
  source = "./modules/dns"
  count  = var.enable_dns_module ? 1 : 0

  gcp_project = var.project_id
  project     = var.name_prefix
  environment = var.environment

  domain_name        = var.langsmith_domain
  create_zone        = var.dns_create_zone
  existing_zone_name = var.dns_existing_zone_name
  create_certificate = var.dns_create_certificate
}

#------------------------------------------------------------------------------
# K8s Bootstrap Module
#------------------------------------------------------------------------------
module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"

  project_id  = var.project_id
  environment = var.environment

  # Namespace configuration
  langsmith_namespace         = var.langsmith_namespace
  workload_identity_gsa_email = var.enable_gcp_iam_module ? local.workload_identity_gsa_email : ""

  # PostgreSQL connection - only when using external PostgreSQL
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/${module.cloudsql[0].database_name}?sslmode=require" : ""

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

  depends_on = [time_sleep.wait_for_cluster, module.cloudsql, module.iam]
}

#------------------------------------------------------------------------------
# Ingress Module (Optional)
#------------------------------------------------------------------------------
module "ingress" {
  source = "./modules/ingress"
  count  = var.install_ingress ? 1 : 0

  ingress_type        = var.ingress_type
  langsmith_domain    = var.langsmith_domain
  langsmith_namespace = var.langsmith_namespace

  # Use centralized naming for gateway
  gateway_name = "${local.base_name}-gateway"

  # TLS configuration for Gateway HTTPS listener
  tls_certificate_source = var.tls_certificate_source
  tls_secret_name        = var.tls_secret_name

  depends_on = [time_sleep.wait_for_cluster, module.k8s_bootstrap]
}
