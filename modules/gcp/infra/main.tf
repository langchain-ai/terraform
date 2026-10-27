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

# The dedicated sandbox cluster (sandbox_deployment_mode = "separate_cluster").
# Only its namespace and two Secrets are managed here; deploy.sh installs the
# langsmith-sandbox chart. try() keeps the provider configurable when the
# cluster does not exist.
provider "kubernetes" {
  alias                  = "sandbox"
  host                   = try("https://${module.sandbox_gke[0].endpoint}", null)
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = try(base64decode(module.sandbox_gke[0].ca_certificate), null)
}

#------------------------------------------------------------------------------
# Data Sources
#------------------------------------------------------------------------------
data "google_client_config" "default" {}

# Wait for GKE API server to be fully ready after cluster creation.
# The google_container_cluster resource waits until RUNNING state, but the
# API server needs a short additional window before accepting requests.
# time_sleep works in CI environments without gcloud/kubectl in PATH.
resource "time_sleep" "wait_for_cluster" {
  create_duration = "90s"

  depends_on = [module.gke_cluster]
}

resource "time_sleep" "wait_for_sandbox_cluster" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  create_duration = "90s"

  depends_on = [module.sandbox_gke]
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

  redis_connection_url = var.redis_source == "external" ? "redis://${module.redis[0].host}:${module.redis[0].port}" : ""

  # DB 0 is reserved for the main LangSmith install.
  redis_db_fleet    = 1
  redis_db_polly    = 2
  redis_db_insights = 3
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

    precondition {
      condition     = !var.enable_smithdb || var.smithdb_metastore_source == "create" || (var.smithdb_external_metastore_host != null && var.smithdb_external_metastore_username != null)
      error_message = "smithdb_external_metastore_host and smithdb_external_metastore_username are required when smithdb_metastore_source = 'external'."
    }

    precondition {
      condition     = var.enable_smithdb || !(var.smithdb_ingestion_enabled || var.smithdb_migration_enabled || var.smithdb_query_enabled)
      error_message = "SmithDB integration gates require enable_smithdb = true."
    }

    precondition {
      condition     = !var.smithdb_migration_enabled || var.smithdb_ingestion_enabled
      error_message = "smithdb_migration_enabled requires smithdb_ingestion_enabled = true."
    }

    # The proxy takes the instance's connection name as its only positional
    # argument, and that is knowable only for an instance this module created.
    precondition {
      condition     = !local.smithdb_metastore_use_auth_proxy || var.smithdb_metastore_source == "create"
      error_message = "smithdb_metastore_use_auth_proxy requires smithdb_metastore_source = 'create'. For an external instance, including AlloyDB, configure the proxy sidecar directly in the Helm values - see the metastore TLS section of SMITHDB.md."
    }

    # The hop the proxy terminates is the one to Cloud SQL. SmithDB's own hop is
    # to 127.0.0.1 inside the Pod, where a TLS handshake has no server to meet
    # and the connection fails outright rather than degrading.
    precondition {
      condition     = !local.smithdb_metastore_use_auth_proxy || !local.smithdb_metastore_use_ssl
      error_message = "smithdb_metastore_use_auth_proxy requires smithdb_metastore_use_ssl = false. The proxy holds the TLS session to Cloud SQL; the SmithDB-to-proxy hop is Pod loopback and is plaintext by design. The proxy is the default for a created metastore, so remove smithdb_metastore_use_ssl = true."
    }

    # Without the proxy, a created metastore works only in mode 2. Direct TLS
    # from SmithDB fails with UnknownIssuer, and ENCRYPTED_ONLY refuses plaintext.
    precondition {
      condition = !var.enable_smithdb || var.smithdb_metastore_source != "create" || local.smithdb_metastore_use_auth_proxy || (
        !local.smithdb_metastore_use_ssl && var.smithdb_metastore_ssl_mode == "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
      )
      error_message = "smithdb_metastore_use_auth_proxy = false on a created metastore requires smithdb_metastore_use_ssl = false and smithdb_metastore_ssl_mode = 'ALLOW_UNENCRYPTED_AND_ENCRYPTED' (mode 2, test and staging only). Direct TLS from SmithDB to Cloud SQL fails with UnknownIssuer. See the metastore TLS section of SMITHDB.md."
    }

    # minimal has no SmithDB node pools, so no node has Local SSD for the cache.
    precondition {
      condition     = !var.enable_smithdb || !local.smithdb_minimal || local.smithdb_network_disk
      error_message = "smithdb_sizing = 'minimal' requires smithdb_cache_storage = 'network-disk'. Leave smithdb_cache_storage unset, or select a larger smithdb_sizing."
    }

    # network-disk cache volumes are Hyperdisk Balanced. E2, N1, N2, and N2D
    # cannot attach them, and C4 and N4 need a Hyperdisk boot disk, which the
    # SmithDB pools do not use. A C3 type without -lssd also rejects Local SSD.
    precondition {
      condition     = !local.smithdb_create_cache_storage_class || (can(regex("^c3d?-", local.smithdb_instance_store_machine_type)) && local.smithdb_instance_store_local_ssd_count == 0)
      error_message = "smithdb_cache_storage = 'network-disk' requires a C3 or C3D cache machine type and smithdb_instance_store_local_ssd_count = 0. The resolved pool is ${local.smithdb_instance_store_machine_type} with ${local.smithdb_instance_store_local_ssd_count} Local SSD. Remove the smithdb_instance_store_* shape variables from terraform.tfvars to use the defaults."
    }

    # In network-disk mode, the backfill Job takes its 100Gi of ephemeral
    # storage from the cache pool boot disk.
    precondition {
      condition     = !local.smithdb_create_cache_storage_class || !var.smithdb_migration_enabled || local.smithdb_instance_store_disk_size >= 300
      error_message = "smithdb_cache_storage = 'network-disk' with smithdb_migration_enabled = true requires smithdb_instance_store_disk_size >= 300 for the 100Gi backfill Job. The resolved boot disk is ${local.smithdb_instance_store_disk_size} GB."
    }

    # local-ssd puts each cache in an emptyDir, so the cache pool needs Local SSD
    # ephemeral storage. That is an explicit count, or a type that bundles it.
    precondition {
      condition     = !local.smithdb_dedicated_pools || local.smithdb_network_disk || local.smithdb_instance_store_local_ssd_count > 0 || endswith(local.smithdb_instance_store_machine_type, "lssd")
      error_message = "smithdb_cache_storage = 'local-ssd' requires Local SSD on the cache pool: smithdb_instance_store_local_ssd_count > 0, or a machine type that ends in lssd. The resolved pool is ${local.smithdb_instance_store_machine_type} with ${local.smithdb_instance_store_local_ssd_count} Local SSD. Remove the smithdb_instance_store_* shape variables from terraform.tfvars to use the defaults."
    }

    precondition {
      condition     = !var.smithdb_query_enabled || var.smithdb_ingestion_enabled
      error_message = "smithdb_query_enabled requires smithdb_ingestion_enabled = true."
    }

    # Autopilot manages node pools itself, so the dedicated SmithDB pools this
    # module creates do not exist there and the sizing file's nodeSelector would
    # never match — SmithDB pods would stay Pending indefinitely. Autopilot needs
    # the cloud.google.com/gke-ephemeral-storage-local-ssd nodeSelector instead.
    precondition {
      condition     = !var.enable_smithdb || !var.gke_use_autopilot
      error_message = "enable_smithdb is not supported with gke_use_autopilot = true. SmithDB needs the dedicated SmithDB node pools this module creates on GKE Standard. See the SmithDB section of README.md."
    }

    precondition {
      condition     = !var.enable_sandboxes || !var.gke_use_autopilot
      error_message = "enable_sandboxes requires Standard GKE because sandbox-host needs a dedicated nested-virtualization node pool."
    }

    precondition {
      condition     = !local.same_cluster_sandboxes || var.enable_gcp_iam_module
      error_message = "enable_sandboxes requires enable_gcp_iam_module = true so the juicefs-format Job can reach the shared GCS bucket through the langsmith-sandbox-host Workload Identity binding."
    }

    precondition {
      condition     = !var.enable_sandboxes || var.sandbox_host_max_node_count >= var.sandbox_host_min_node_count
      error_message = "sandbox_host_max_node_count must be greater than or equal to sandbox_host_min_node_count."
    }

    # Workload Identity trusts a namespace and ServiceAccount name in every
    # cluster of the project, so a sandbox-cluster pod in the LangSmith
    # namespace could take on the LangSmith service account.
    precondition {
      condition     = !local.separate_cluster_sandboxes || var.sandbox_namespace != var.langsmith_namespace
      error_message = "sandbox_deployment_mode = \"separate_cluster\" requires sandbox_namespace to differ from langsmith_namespace. GKE Workload Identity trusts a namespace and ServiceAccount name across every cluster in the project."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || can(regex(local.separate_cluster_chart_version_pattern, var.langsmith_helm_chart_version))
      error_message = "sandbox_deployment_mode = \"separate_cluster\" requires langsmith_helm_chart_version to be an exact langsmith chart version on 0.18 or later, such as \"0.18.0\". The default 0.17 line has no separate-cluster support, and the langsmith-sandbox chart is paired with that exact chart by appVersion."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || length(var.sandbox_service_auth_secret) >= 32
      error_message = "sandbox_deployment_mode = \"separate_cluster\" requires sandbox_service_auth_secret (at least 32 characters). Run: source ./scripts/setup-env.sh, which generates it and stores it in Secret Manager."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || var.sandbox_service_auth_secret != var.langsmith_api_key_salt
      error_message = "sandbox_service_auth_secret must differ from langsmith_api_key_salt: the separate sandbox cluster must not hold the API key salt. Delete the sandbox-service-auth-secret secret in Secret Manager, unset TF_VAR_sandbox_service_auth_secret, and re-run: source ./scripts/setup-env.sh."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || var.sandbox_callback_signing_jwk != ""
      error_message = "sandbox_deployment_mode = \"separate_cluster\" requires sandbox_callback_signing_jwk, which Terraform writes into the sandbox cluster. Run: source ./scripts/setup-env.sh."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || length(local.sandbox_cidr_overlaps) == 0
      error_message = "sandbox_subnet_cidr, sandbox_pods_cidr and sandbox_services_cidr must not overlap each other or subnet_cidr, pods_cidr and services_cidr. Overlapping: ${join(", ", local.sandbox_cidr_overlaps)}."
    }

    # The LangSmith cluster's control plane uses 172.17.0.0/28.
    precondition {
      condition     = !local.separate_cluster_sandboxes || cidrhost(var.sandbox_gke_master_ipv4_cidr, 0) != "172.17.0.0"
      error_message = "sandbox_gke_master_ipv4_cidr must differ from 172.17.0.0/28, the LangSmith cluster's control-plane range."
    }

    precondition {
      condition     = !local.separate_cluster_sandboxes || length(local.sandbox_juicefs_bucket_name) <= 63
      error_message = "The sandbox JuiceFS bucket name ${local.sandbox_juicefs_bucket_name} is longer than 63 characters. Shorten name_prefix or environment."
    }

    # Sandbox hosts call https://<langsmith_domain>/api (or http:// without
    # TLS) through the Envoy Gateway. An external load balancer without TLS
    # would carry their service-auth tokens across the internet in plaintext.
    precondition {
      condition = (
        !local.separate_cluster_sandboxes
        || !var.install_ingress
        || var.gateway_load_balancer_type == "internal"
        || var.tls_certificate_source != "none"
      )
      error_message = "sandbox_deployment_mode = \"separate_cluster\" with an external gateway and tls_certificate_source = \"none\" would send the sandbox cluster's calls to the LangSmith API across the internet without TLS. Set gateway_load_balancer_type = \"internal\" or configure TLS (tls_certificate_source = \"letsencrypt\" or \"existing\")."
    }

    precondition {
      condition     = var.gateway_load_balancer_type == "external" || (var.install_ingress && var.ingress_type == "envoy")
      error_message = "gateway_load_balancer_type = \"internal\" applies to the Envoy Gateway this module installs (install_ingress = true, ingress_type = \"envoy\")."
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
# Sandbox-host Node Service Account
#------------------------------------------------------------------------------
resource "google_service_account" "sandbox_host_node" {
  count = var.enable_sandboxes ? 1 : 0

  project      = var.project_id
  account_id   = local.sandbox_host_node_sa_account_id
  display_name = "LangSmith sandbox-host node service account"
  description  = "Restricted GKE node identity for LangSmith sandbox-host nodes."

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "sandbox_host_node" {
  for_each = var.enable_sandboxes ? local.sandbox_host_node_sa_project_roles : toset([])

  project = var.project_id
  role    = each.value
  member  = google_service_account.sandbox_host_node[0].member
}

# The sandbox cluster's system pool (separate_cluster only) gets its own node
# identity with the default node roles and nothing else: no bucket access.
resource "google_service_account" "sandbox_system_node" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  project      = var.project_id
  account_id   = local.sandbox_system_node_sa_account_id
  display_name = "LangSmith sandbox cluster system node service account"
  description  = "GKE node identity for the system pool of the dedicated LangSmith sandbox cluster."

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "sandbox_system_node" {
  for_each = local.separate_cluster_sandboxes ? local.sandbox_system_node_sa_project_roles : toset([])

  project = var.project_id
  role    = each.value
  member  = google_service_account.sandbox_system_node[0].member
}

# sandbox-host runs with hostNetwork: true, and GKE does not give Workload
# Identity to host-network pods. Their metadata requests reach the Compute
# Engine metadata server and get this node service account. The JuiceFS mount
# in sandbox-host therefore reads and writes the bucket as this identity, not
# as langsmith-sandbox-host. The juicefs-format Job uses the pod network, so it
# still needs the Workload Identity binding in module.iam.
#
# Sandbox nodes run untrusted code, and the bucket also holds trace data. The
# condition limits this identity to the JuiceFS prefix: object access under
# <sandbox_juicefs_name>/ and list calls with that prefix. The expression uses
# local.bucket_name, the name module.storage creates, so the plan can show it.
resource "google_storage_bucket_iam_member" "sandbox_host_node_juicefs" {
  count = local.same_cluster_sandboxes ? 1 : 0

  bucket = module.storage.bucket_name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.sandbox_host_node[0].member

  condition {
    title       = "juicefs-prefix-only"
    description = "Sandbox node access limited to the JuiceFS prefix."
    expression = join(" || ", [
      "resource.name.startsWith(\"projects/_/buckets/${local.bucket_name}/objects/${var.sandbox_juicefs_name}/\")",
      "api.getAttribute(\"storage.googleapis.com/objectListPrefix\", \"\").startsWith(\"${var.sandbox_juicefs_name}/\")",
    ])
  }
}

# separate_cluster gives JuiceFS a bucket of its own. Cloud Storage checks a
# list call against the bucket, so a prefix-only grant would block JuiceFS's
# format check and backup cleanup; on a JuiceFS-only bucket the grant needs no
# condition and sandbox nodes never reach trace data. With
# workloadIdentity.provider = gcp the chart runs the JuiceFS formatter on the
# host network as well, so this one grant covers both runtime pods.
resource "google_storage_bucket" "sandbox_juicefs" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  name     = local.sandbox_juicefs_bucket_name
  project  = var.project_id
  location = var.region

  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  labels = merge(local.common_labels, {
    "component" = "sandbox-juicefs"
  })

  force_destroy = var.storage_force_destroy

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "sandbox_host_node_juicefs_bucket" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  bucket = google_storage_bucket.sandbox_juicefs[0].name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.sandbox_host_node[0].member
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

  # The dedicated sandbox cluster's subnet (separate_cluster only)
  create_sandbox_subnet = local.separate_cluster_sandboxes
  sandbox_subnet_cidr   = var.sandbox_subnet_cidr
  sandbox_pods_cidr     = var.sandbox_pods_cidr
  sandbox_services_cidr = var.sandbox_services_cidr

  # Private service connection (requires servicenetworking.networksAdmin role).
  # Needed by external PostgreSQL and Redis, by the SmithDB metastore, which is
  # private-IP only, and by the Memorystore instance backing sandbox JuiceFS
  # metadata.
  enable_private_service_connection = var.postgres_source == "external" || var.redis_source == "external" || var.enable_sandboxes || (var.enable_smithdb && var.smithdb_metastore_source == "create")

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
  use_autopilot              = var.gke_use_autopilot
  node_count                 = var.gke_node_count
  min_node_count             = var.gke_min_nodes
  max_node_count             = var.gke_max_nodes
  machine_type               = var.gke_machine_type
  spot                       = var.gke_spot
  disk_size_gb               = var.gke_disk_size
  node_service_account_email = var.gke_node_service_account_email
  release_channel            = var.gke_release_channel
  deletion_protection        = var.gke_deletion_protection
  network_policy_provider    = var.gke_network_policy_provider

  # Dedicated sandbox-host nodes. Sandboxes run Firecracker through nested
  # virtualization and are isolated from the default LangSmith workload pool.
  # With separate_cluster they live in module.sandbox_gke instead.
  enable_sandbox_host_node_pool          = local.same_cluster_sandboxes
  sandbox_host_node_count                = var.sandbox_host_node_count
  sandbox_host_min_node_count            = var.sandbox_host_min_node_count
  sandbox_host_max_node_count            = var.sandbox_host_max_node_count
  sandbox_host_machine_type              = local.sandbox_host_machine_type
  sandbox_host_disk_size_gb              = var.sandbox_host_disk_size_gb
  sandbox_host_ephemeral_local_ssd_count = var.sandbox_host_ephemeral_local_ssd_count
  sandbox_host_node_service_account_email = (
    local.same_cluster_sandboxes ? google_service_account.sandbox_host_node[0].email : null
  )

  # Master authorized networks — empty list keeps the master publicly reachable
  # for Terraform-driven Helm/kubectl steps. Populate var.gke_master_authorized_cidrs
  # in terraform.tfvars to restrict to operator/CI CIDRs.
  master_authorized_cidrs = var.gke_master_authorized_cidrs

  # Labels
  labels = local.common_labels

  depends_on = [
    module.networking,
    google_project_iam_member.sandbox_host_node,
  ]
}

#------------------------------------------------------------------------------
# Sandbox GKE Cluster (sandbox_deployment_mode = "separate_cluster")
#------------------------------------------------------------------------------
# A second Standard cluster in the same VPC, on its own subnet and control-plane
# range. Its primary pool is a small untainted system pool for GKE's add-ons;
# sandbox-host runs on the tainted nested-virtualization pool. Workload
# Identity stays on (the module always enables it) so pod-network pods cannot
# read the node service account from the metadata server. No binding is made
# for the runtime: sandbox-host and its JuiceFS formatter use the host network
# and the sandbox node service account.
module "sandbox_gke" {
  source = "./modules/k8s-cluster"
  count  = local.separate_cluster_sandboxes ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  zone        = var.zone
  environment = var.environment

  cluster_name   = local.sandbox_cluster_name
  node_pool_name = "${local.sandbox_cluster_name}-system"

  network_id             = module.networking.vpc_id
  subnet_id              = module.networking.sandbox_subnet_id
  pods_range_name        = module.networking.sandbox_pods_range_name
  services_range_name    = module.networking.sandbox_services_range_name
  master_ipv4_cidr_block = var.sandbox_gke_master_ipv4_cidr

  # System pool: one node per zone, scaling up for add-ons only.
  node_count                 = 1
  min_node_count             = 1
  max_node_count             = var.sandbox_system_node_max_count
  machine_type               = var.sandbox_system_node_machine_type
  node_service_account_email = google_service_account.sandbox_system_node[0].email
  release_channel            = var.gke_release_channel
  deletion_protection        = var.gke_deletion_protection
  network_policy_provider    = var.gke_network_policy_provider

  enable_sandbox_host_node_pool           = true
  sandbox_host_node_count                 = var.sandbox_host_node_count
  sandbox_host_min_node_count             = var.sandbox_host_min_node_count
  sandbox_host_max_node_count             = var.sandbox_host_max_node_count
  sandbox_host_machine_type               = local.sandbox_host_machine_type
  sandbox_host_disk_size_gb               = var.sandbox_host_disk_size_gb
  sandbox_host_ephemeral_local_ssd_count  = var.sandbox_host_ephemeral_local_ssd_count
  sandbox_host_node_service_account_email = google_service_account.sandbox_host_node[0].email

  master_authorized_cidrs = var.gke_master_authorized_cidrs

  labels = merge(local.common_labels, {
    "component" = "sandbox-cluster"
  })

  depends_on = [
    module.networking,
    google_project_iam_member.sandbox_host_node,
    google_project_iam_member.sandbox_system_node,
  ]
}

# What reaches the sandbox nodes. The VPC's allow-internal rule (priority 1000,
# no targets) admits the LangSmith ranges to every VM on every port. For the
# sandbox cluster's nodes these rules override it: platform-backend and the
# ingest queue may reach sandbox-host on TCP 19190 (plain HTTP with signed
# service keys), other sandbox nodes may too (hosts forward requests, dial
# sandbox links and stream live migrations to each other), and nothing else from
# the LangSmith ranges gets through. GKE's own rules for the sandbox cluster
# admit only its subnet, pod range and control plane.
resource "google_compute_firewall" "sandbox_host_from_langsmith" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  name        = "${local.vpc_name}-sbox-allow-host"
  project     = var.project_id
  network     = module.networking.vpc_name
  description = "LangSmith pods and other sandbox nodes to sandbox-host on TCP 19190"
  direction   = "INGRESS"
  priority    = 900

  allow {
    protocol = "tcp"
    ports    = ["19190"]
  }

  # LangSmith pods reach other VPC addresses with their pod IPs (GKE does not
  # masquerade RFC 1918 destinations); the node range covers a cluster where
  # masquerading was turned on.
  source_ranges           = [var.subnet_cidr, var.pods_cidr, var.sandbox_subnet_cidr]
  target_service_accounts = [google_service_account.sandbox_host_node[0].email]
}

resource "google_compute_firewall" "sandbox_deny_from_langsmith" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  name        = "${local.vpc_name}-sbox-deny-langsmith"
  project     = var.project_id
  network     = module.networking.vpc_name
  description = "Nothing else from the LangSmith ranges reaches the sandbox cluster's nodes"
  direction   = "INGRESS"
  priority    = 950

  deny {
    protocol = "all"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
  target_service_accounts = [
    google_service_account.sandbox_host_node[0].email,
    google_service_account.sandbox_system_node[0].email,
  ]
}

# What the sandbox cluster's nodes reach. They run untrusted code, and Cloud
# SQL and the LangSmith Redis sit in the private services range, which every
# subnet in the VPC can reach. Sandbox-host nodes need only the JuiceFS Redis
# there, and the system pool nothing.
resource "google_compute_firewall" "sandbox_host_to_juicefs_redis" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  name        = "${local.vpc_name}-sbox-allow-jfs-redis"
  project     = var.project_id
  network     = module.networking.vpc_name
  description = "Sandbox nodes to the JuiceFS metadata Redis"
  direction   = "EGRESS"
  priority    = 900

  allow {
    protocol = "tcp"
    ports    = [tostring(module.sandbox_juicefs_redis[0].port)]
  }

  destination_ranges      = ["${module.sandbox_juicefs_redis[0].host}/32"]
  target_service_accounts = [google_service_account.sandbox_host_node[0].email]
}

resource "google_compute_firewall" "sandbox_host_deny_private_services" {
  count = local.separate_cluster_sandboxes ? 1 : 0

  name        = "${local.vpc_name}-sbox-deny-private-services"
  project     = var.project_id
  network     = module.networking.vpc_name
  description = "The sandbox cluster's nodes reach nothing else in the private services range (Cloud SQL, LangSmith Redis)"
  direction   = "EGRESS"
  priority    = 950

  deny {
    protocol = "all"
  }

  # Both pools: the system pool needs nothing in that range either, and pod
  # traffic on it follows the node's targeting.
  destination_ranges = [module.networking.private_service_range_cidr]
  target_service_accounts = [
    google_service_account.sandbox_host_node[0].email,
    google_service_account.sandbox_system_node[0].email,
  ]
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
  maxmemory_policy  = "allkeys-lru"

  # Network
  network_id = module.networking.vpc_id

  # Labels
  labels = local.common_labels

  depends_on = [module.networking]
}

module "sandbox_juicefs_redis" {
  source = "./modules/redis"
  count  = var.enable_sandboxes ? 1 : 0

  project_id  = var.project_id
  region      = var.region
  environment = var.environment

  # Use centralized naming
  instance_name = local.sandbox_juicefs_redis_instance_name

  # Configuration
  memory_size_gb      = var.sandbox_juicefs_redis_memory_size
  redis_version       = var.redis_version
  high_availability   = var.sandbox_juicefs_redis_high_availability
  prevent_destroy     = var.sandbox_juicefs_redis_prevent_destroy
  maxmemory_policy    = "noeviction"
  rdb_snapshot_period = var.sandbox_juicefs_redis_rdb_snapshot_period
  # A second cluster reaches this Redis over the VPC, so require AUTH there.
  auth_enabled = local.separate_cluster_sandboxes

  # Network
  network_id = module.networking.vpc_id

  # Labels
  labels = merge(local.common_labels, {
    "component" = "sandbox-juicefs-cache"
  })

  depends_on = [module.networking, module.redis]
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
# SmithDB Module (Optional, enable_smithdb)
#
# SmithDB is the in-chart columnar store/query engine (chart 0.17). It needs
# three things from the cloud: a dedicated Postgres metastore, its own object
# store, and cache capacity (node Local SSD or network disk). This module owns
# the first two plus the Workload Identity binding; the node pools are in
# module.smithdb_nodes, and the network-disk StorageClass is in k8s-bootstrap.
#------------------------------------------------------------------------------
module "smithdb" {
  source = "./modules/smithdb"
  count  = var.enable_smithdb ? 1 : 0

  name       = local.smithdb_name
  project_id = var.project_id
  region     = var.region
  labels     = local.common_labels

  namespace    = var.langsmith_namespace
  release_name = var.langsmith_release_name

  network_id                 = module.networking.vpc_id
  private_network_connection = module.networking.private_service_connection

  # Metastore — dedicated Cloud SQL instance, or bring your own (AlloyDB).
  metastore_source            = var.smithdb_metastore_source
  metastore_instance_name     = local.smithdb_metastore_instance_name
  metastore_database_version  = var.smithdb_metastore_database_version
  metastore_tier              = local.smithdb_metastore_tier
  metastore_disk_size         = var.smithdb_metastore_disk_size
  metastore_high_availability = var.smithdb_metastore_high_availability

  metastore_deletion_protection = var.smithdb_metastore_deletion_protection
  metastore_ssl_mode            = var.smithdb_metastore_ssl_mode
  metastore_use_auth_proxy      = local.smithdb_metastore_use_auth_proxy
  metastore_master_username     = var.smithdb_metastore_master_username
  metastore_master_password     = var.smithdb_metastore_master_password

  external_metastore_host     = var.smithdb_external_metastore_host
  external_metastore_port     = var.smithdb_external_metastore_port
  external_metastore_database = var.smithdb_external_metastore_database
  external_metastore_username = var.smithdb_external_metastore_username
  external_metastore_password = var.smithdb_external_metastore_password

  # Object store
  bucket_name               = local.smithdb_bucket_name
  bucket_kms_key            = var.smithdb_bucket_kms_key
  bucket_versioning_enabled = var.smithdb_bucket_versioning_enabled
  bucket_force_destroy      = var.smithdb_bucket_force_destroy

  # The backfill reads offloaded run payloads out of the traces bucket, so it
  # needs a read grant there. Passed unconditionally; the module only creates the
  # binding when the migration gate is on.
  traces_bucket_name = module.storage.bucket_name
  migration_enabled  = var.smithdb_migration_enabled

  service_account_email = var.smithdb_service_account_email

  depends_on = [module.networking, google_project_service.apis]
}

#------------------------------------------------------------------------------
# SmithDB Node Pools (Optional, enable_smithdb)
# A cache pool (Local SSD, or none in network-disk mode) plus a compute pool.
# Not created for smithdb_sizing = minimal, or on Autopilot, where Google
# manages node pools; see the SmithDB section of README.md for that path.
#------------------------------------------------------------------------------
module "smithdb_nodes" {
  source = "./modules/smithdb-nodes"
  count  = local.smithdb_dedicated_pools ? 1 : 0

  project_id   = var.project_id
  region       = var.region
  cluster_name = module.gke_cluster.cluster_name
  name_prefix  = local.base_name

  node_service_account_email = var.gke_node_service_account_email
  node_locations             = var.smithdb_node_locations

  instance_store_machine_type    = local.smithdb_instance_store_machine_type
  instance_store_local_ssd_count = local.smithdb_instance_store_local_ssd_count
  instance_store_disk_size_gb    = local.smithdb_instance_store_disk_size
  instance_store_min_nodes       = var.smithdb_instance_store_min_nodes
  instance_store_max_nodes       = var.smithdb_instance_store_max_nodes

  compute_machine_type = local.smithdb_compute_machine_type
  compute_disk_size_gb = var.smithdb_compute_disk_size
  compute_min_nodes    = var.smithdb_compute_min_nodes
  compute_max_nodes    = var.smithdb_compute_max_nodes

  labels = local.common_labels

  depends_on = [module.gke_cluster]
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
    # Chart 0.15 renamed these Deployments (agentBuilderToolServer/TriggerServer ->
    # fleetToolServer/fleetTriggerServer), which also renamed the ServiceAccount the
    # chart creates for them. Keep both old and new names — CHART_VERSION can still
    # be pinned below 0.15 (see deploy.sh), where the chart creates the old-named SA
    # instead. Harmless either way: WI binds only to whichever SA the chart actually
    # creates for the pinned version.
    "langsmith-agent-builder-tool-server",
    "langsmith-agent-builder-trigger-server",
    "langsmith-fleet-tool-server",
    "langsmith-fleet-trigger-server",
    "langsmith-ace-backend",
    "langsmith-frontend",
    "langsmith-playground",
    "langsmith-operator",
    # Standalone agent SAs (v0.15+) — created by the chart, harmless if features are off.
    "langsmith-standalone-fleet-api-server",
    "langsmith-standalone-fleet-queue",
    "langsmith-standalone-polly-api-server",
    "langsmith-standalone-polly-queue",
    "langsmith-standalone-insights-api-server",
    "langsmith-standalone-insights-queue",
    # The chart's juicefs-format Job runs as langsmith-sandbox-host on the pod
    # network. sandbox-host itself runs on the host network and uses the node
    # service account (see google_storage_bucket_iam_member.sandbox_host_node_juicefs).
    "langsmith-sandbox-host",
    # Chart 0.16 JuiceFS CSI node ServiceAccount. Keep it through the 0.16 to 0.17
    # upgrade: terraform apply runs before helm upgrade removes the driver, and the
    # old mount pods read the bucket until then.
    "juicefs-csi-node-sa",
  ]
  gcs_bucket_name               = module.storage.bucket_name
  grant_project_secret_accessor = var.grant_project_secret_accessor
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

  # The module's kubectl steps fetch their own credentials for this cluster.
  region       = var.region
  cluster_name = module.gke_cluster.cluster_name

  # Namespace configuration
  langsmith_namespace         = var.langsmith_namespace
  workload_identity_gsa_email = var.enable_gcp_iam_module ? local.workload_identity_gsa_email : ""

  # sandbox-host manages Firecracker VMs in child cgroups and must not receive
  # a namespace-injected parent limit. Keep request and pod-count governance,
  # and inject requests only for third-party containers that omit them.
  resource_quota_include_limits = !local.same_cluster_sandboxes
  default_container_requests = (
    local.same_cluster_sandboxes ? var.sandbox_default_container_requests : {}
  )

  # SmithDB does not fit inside the base namespace quota, and the failure mode is
  # opaque: a ReplicaSet reports FailedCreate and the backfill Job reports Running
  # with no pod, neither of which names SmithDB. Size the headroom here instead.
  resource_quota_extra_cpu       = local.smithdb_quota_extra_cpu
  resource_quota_extra_memory_gi = local.smithdb_quota_extra_memory_gi
  resource_quota_extra_pods      = local.smithdb_quota_extra_pods

  create_smithdb_cache_storage_class = local.smithdb_create_cache_storage_class
  smithdb_cache_storage_class_name   = local.smithdb_cache_storage_class

  # The chart 0.16 JuiceFS CSI driver runs at system-node-critical /
  # system-cluster-critical, which GKE admits only into a namespace holding a
  # PriorityClass-scoped quota. Chart 0.17 has no driver. Keep the quota through the
  # upgrade so a driver pod rescheduled before helm upgrade removes it is admitted.
  allow_critical_priority_pods = local.same_cluster_sandboxes

  # Host-networked sandbox-host must reach platform-backend, and the CNI dictates how:
  #  - CALICO: an ipBlock for the node subnet matches node-sourced traffic, so keep
  #    the full default-deny and admit the node subnet.
  #  - DATA_PLANE_V2 (Cilium): node-sourced traffic can't be authorized by a standard
  #    NetworkPolicy (ipBlock doesn't match it; the CiliumNetworkPolicy CRD isn't
  #    exposed), so keep the default-deny but exclude platform-backend from it.
  sandbox_host_ingress_cidrs = (
    local.same_cluster_sandboxes && var.gke_network_policy_provider == "CALICO" ? [var.subnet_cidr] : []
  )
  default_deny_excluded_component = (
    local.same_cluster_sandboxes && var.gke_network_policy_provider == "DATA_PLANE_V2" ? var.platform_backend_component_label : ""
  )

  # PostgreSQL connection - only when using external PostgreSQL
  use_external_postgres   = var.postgres_source == "external"
  postgres_connection_url = var.postgres_source == "external" ? "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/${module.cloudsql[0].database_name}?sslmode=require" : ""

  # Redis connection - only when using external Redis
  use_managed_redis    = var.redis_source == "external"
  redis_connection_url = local.redis_connection_url

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

resource "kubernetes_secret_v1" "sandbox_juicefs_csi_config" {
  count = local.same_cluster_sandboxes ? 1 : 0

  metadata {
    name      = var.sandbox_juicefs_csi_config_secret_name
    namespace = var.langsmith_namespace
  }

  type = "Opaque"

  data_wo = {
    name    = var.sandbox_juicefs_name
    metaurl = "redis://${module.sandbox_juicefs_redis[0].host}:${module.sandbox_juicefs_redis[0].port}/0"
    storage = "gs"
    bucket  = module.storage.bucket_url
  }

  data_wo_revision = var.sandbox_juicefs_csi_config_secret_revision

  depends_on = [module.k8s_bootstrap]
}

#------------------------------------------------------------------------------
# Sandbox Cluster Objects (sandbox_deployment_mode = "separate_cluster")
#------------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "sandbox" {
  provider = kubernetes.sandbox
  count    = local.separate_cluster_sandboxes ? 1 : 0

  metadata {
    name = var.sandbox_namespace
  }

  depends_on = [time_sleep.wait_for_sandbox_cluster]
}

# The runtime chart's minimal Secret: never a copy of langsmith-config. Its two
# keys are the langsmith-sandbox chart's defaults (serviceAuth.secretKey and
# serviceAuth.callbackSigningJwkSecretKey), and each value must equal the
# control plane's. The control plane reads its service-auth secret from the
# dedicated sandbox_service_auth_secret key in langsmith-config
# (init-values.sh sets sandboxes.serviceAuth.secretKey to it), never from
# api_key_salt, so the salt stays out of the sandbox cluster.
locals {
  # A local so the plan tests can check the wiring: data_wo is not readable,
  # not even in a plan.
  sandbox_runtime_secret_data = {
    sandbox_service_auth_secret  = var.sandbox_service_auth_secret
    sandbox_callback_signing_jwk = var.sandbox_callback_signing_jwk
  }

  # The AUTH string is URL-encoded because it sits in the URL's userinfo.
  sandbox_juicefs_separate_secret_data = local.separate_cluster_sandboxes ? {
    name    = var.sandbox_juicefs_name
    metaurl = "redis://:${urlencode(module.sandbox_juicefs_redis[0].auth_string)}@${module.sandbox_juicefs_redis[0].host}:${module.sandbox_juicefs_redis[0].port}/0"
    storage = "gs"
    bucket  = google_storage_bucket.sandbox_juicefs[0].url
  } : {}
}

# Write-only: neither value is stored in Terraform state. Bump
# sandbox_runtime_secret_revision to rewrite it.
resource "kubernetes_secret_v1" "sandbox_runtime" {
  provider = kubernetes.sandbox
  count    = local.separate_cluster_sandboxes ? 1 : 0

  metadata {
    name      = var.sandbox_runtime_secret_name
    namespace = kubernetes_namespace_v1.sandbox[0].metadata[0].name
  }

  type = "Opaque"

  data_wo = local.sandbox_runtime_secret_data

  data_wo_revision = var.sandbox_runtime_secret_revision
}

resource "kubernetes_secret_v1" "sandbox_juicefs_config" {
  provider = kubernetes.sandbox
  count    = local.separate_cluster_sandboxes ? 1 : 0

  metadata {
    name      = var.sandbox_juicefs_csi_config_secret_name
    namespace = kubernetes_namespace_v1.sandbox[0].metadata[0].name
  }

  type = "Opaque"

  data_wo = local.sandbox_juicefs_separate_secret_data

  data_wo_revision = var.sandbox_juicefs_csi_config_secret_revision
}

#------------------------------------------------------------------------------
# Standalone Agent Databases (chart v0.15+)
# Each standalone agent gets its own logical database on the shared Cloud SQL
# instance. K8s secrets are created here so they exist before Helm runs.
#------------------------------------------------------------------------------

resource "google_sql_database" "fleet" {
  count      = var.enable_fleet && var.postgres_source == "external" ? 1 : 0
  project    = var.project_id
  instance   = local.postgres_instance_name
  name       = "langsmith_fleet"
  depends_on = [module.cloudsql]
}

resource "kubernetes_secret" "fleet_postgres" {
  count = var.enable_fleet && var.postgres_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-fleet-postgres"
    namespace = var.langsmith_namespace
  }
  data = {
    postgres_connection_url = "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/langsmith_fleet?sslmode=require"
  }
  depends_on = [google_sql_database.fleet, module.k8s_bootstrap]
}

# Memorystore Cluster mode does not support logical DB numbers — see MIGRATION_NOTES_v15.md.
# For non-cluster Redis, DB 0 is reserved for the main LangSmith install,
# DB 1 for Fleet, DB 2 for Polly, and DB 3 for Insights.
resource "kubernetes_secret" "fleet_redis" {
  count = var.enable_fleet && var.redis_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-fleet-redis"
    namespace = var.langsmith_namespace
  }
  data = {
    redis_connection_url = "${local.redis_connection_url}/${local.redis_db_fleet}"
  }
  depends_on = [module.k8s_bootstrap]
}

resource "google_sql_database" "polly" {
  count      = var.enable_standalone_polly && var.postgres_source == "external" ? 1 : 0
  project    = var.project_id
  instance   = local.postgres_instance_name
  name       = "langsmith_polly"
  depends_on = [module.cloudsql]
}

resource "kubernetes_secret" "standalone_polly_postgres" {
  count = var.enable_standalone_polly && var.postgres_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-polly-postgres"
    namespace = var.langsmith_namespace
  }
  data = {
    postgres_connection_url = "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/langsmith_polly?sslmode=require"
  }
  depends_on = [google_sql_database.polly, module.k8s_bootstrap]
}

resource "kubernetes_secret" "standalone_polly_redis" {
  count = var.enable_standalone_polly && var.redis_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-polly-redis"
    namespace = var.langsmith_namespace
  }
  data = {
    redis_connection_url = "${local.redis_connection_url}/${local.redis_db_polly}"
  }
  depends_on = [module.k8s_bootstrap]
}

resource "google_sql_database" "insights" {
  count      = var.enable_standalone_insights && var.postgres_source == "external" ? 1 : 0
  project    = var.project_id
  instance   = local.postgres_instance_name
  name       = "langsmith_insights"
  depends_on = [module.cloudsql]
}

resource "kubernetes_secret" "standalone_insights_postgres" {
  count = var.enable_standalone_insights && var.postgres_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-insights-postgres"
    namespace = var.langsmith_namespace
  }
  data = {
    postgres_connection_url = "postgresql://${urlencode(module.cloudsql[0].username)}:${urlencode(module.cloudsql[0].password)}@${module.cloudsql[0].connection_ip}:5432/langsmith_insights?sslmode=require"
  }
  depends_on = [google_sql_database.insights, module.k8s_bootstrap]
}

resource "kubernetes_secret" "standalone_insights_redis" {
  count = var.enable_standalone_insights && var.redis_source == "external" ? 1 : 0
  metadata {
    name      = "langsmith-insights-redis"
    namespace = var.langsmith_namespace
  }
  data = {
    redis_connection_url = "${local.redis_connection_url}/${local.redis_db_insights}"
  }
  depends_on = [module.k8s_bootstrap]
}

#------------------------------------------------------------------------------
# SmithDB metastore Secret (chart 0.17)
# Created here so it exists before Helm runs. The chart reads it through
# smithdb.config.existingSecretName and the per-field *SecretKey mappings
# generated into the SmithDB values overrides.
#------------------------------------------------------------------------------
resource "kubernetes_secret" "smithdb_metastore" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name      = "smithdb-metastore"
    namespace = var.langsmith_namespace
  }

  # With the Auth Proxy the SmithDB containers dial the sidecar on the Pod
  # loopback, not the instance's private IP. Everything else is unchanged: the
  # proxy authenticates the transport, the password still authenticates the
  # database session.
  data = {
    smithdb_metastore_db_host     = local.smithdb_metastore_use_auth_proxy ? "127.0.0.1" : module.smithdb[0].metastore_host
    smithdb_metastore_db_name     = module.smithdb[0].metastore_database
    smithdb_metastore_db_username = module.smithdb[0].metastore_username
    smithdb_metastore_db_password = module.smithdb[0].metastore_password
  }

  depends_on = [module.k8s_bootstrap]
}

# Credential for the in-chart taskdb Postgres backing the historical
# ClickHouse-to-SmithDB migration. Created unconditionally with SmithDB so that
# smithdb_migration_enabled stays a values-only flip.
resource "kubernetes_secret" "smithdb_taskdb" {
  count = var.enable_smithdb ? 1 : 0

  metadata {
    name      = "smithdb-taskdb"
    namespace = var.langsmith_namespace
  }

  data = {
    postgres_password = module.smithdb[0].taskdb_password
  }

  depends_on = [module.k8s_bootstrap]
}

#------------------------------------------------------------------------------
# Ingress Module (Optional)
#------------------------------------------------------------------------------
module "ingress" {
  source = "./modules/ingress"
  count  = var.install_ingress ? 1 : 0

  # The module's kubectl steps fetch their own credentials for this cluster.
  project_id   = var.project_id
  region       = var.region
  cluster_name = module.gke_cluster.cluster_name

  ingress_type        = var.ingress_type
  load_balancer_type  = var.gateway_load_balancer_type
  langsmith_domain    = var.langsmith_domain
  langsmith_namespace = var.langsmith_namespace

  # Use centralized naming for gateway
  gateway_name = "${local.base_name}-gateway"

  # TLS configuration for Gateway HTTPS listener
  tls_certificate_source = var.tls_certificate_source
  tls_secret_name        = var.tls_secret_name

  depends_on = [time_sleep.wait_for_cluster, module.k8s_bootstrap]
}
