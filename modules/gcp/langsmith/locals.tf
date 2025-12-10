# Locals - Centralized naming conventions and computed values
# This ensures consistent naming across all resources and prevents collisions

locals {
  #----------------------------------------------------------------------------
  # Naming Convention
  # Format: {prefix}-{environment}-{resource_type}-{suffix}
  # Example: myco-prod-vpc-a1b2c3d4
  #----------------------------------------------------------------------------

  # Random suffix for uniqueness (only if enabled)
  suffix = var.unique_suffix ? "-${random_id.suffix.hex}" : ""

  # Base name used as prefix for all resources
  base_name = "${var.name_prefix}-${var.environment}"

  #----------------------------------------------------------------------------
  # Resource Names (all derived from base_name)
  #----------------------------------------------------------------------------

  # Networking
  vpc_name    = "${local.base_name}-vpc"
  subnet_name = "${local.base_name}-subnet"
  router_name = "${local.base_name}-router"
  nat_name    = "${local.base_name}-nat"

  # GKE
  cluster_name   = "${local.base_name}-gke"
  node_pool_name = "${local.base_name}-nodepool"

  # Cloud SQL
  postgres_instance_name = "${local.base_name}-pg${local.suffix}"
  postgres_database_name = "langsmith"
  postgres_user_name     = "langsmith"

  # Redis
  redis_instance_name = "${local.base_name}-redis${local.suffix}"

  # Storage
  bucket_name = "${var.project_id}-${local.base_name}-traces${local.suffix}"

  # IAM
  service_account_name = "${local.base_name}-sa"
  service_account_id   = "${local.base_name}-sa"

  #----------------------------------------------------------------------------
  # Common Labels (applied to all resources)
  #----------------------------------------------------------------------------
  common_labels = merge(
    {
      # Standard labels
      "app"         = "langsmith"
      "environment" = var.environment
      "managed-by"  = "terraform"
      "project"     = var.project_id
      "name-prefix" = var.name_prefix

      # Optional labels (only if provided)
      "owner" = var.owner
    },
    # Add cost center if provided
    var.cost_center != "" ? { "cost-center" = var.cost_center } : {},
    # Merge custom labels
    var.labels
  )

  #----------------------------------------------------------------------------
  # Timeouts (for long-running operations)
  #----------------------------------------------------------------------------
  timeouts = {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  #----------------------------------------------------------------------------
  # Computed Values
  #----------------------------------------------------------------------------

  # Service account email (computed after creation)
  service_account_email = "${local.service_account_id}@${var.project_id}.iam.gserviceaccount.com"

  # Workload Identity pool
  workload_identity_pool = "${var.project_id}.svc.id.goog"

  #----------------------------------------------------------------------------
  # Feature Flags
  #----------------------------------------------------------------------------

  # Determine if this is a production environment (enables extra protections)
  is_production = contains(["prod", "production"], lower(var.environment))

  # Enable deletion protection for production
  deletion_protection = local.is_production ? true : var.postgres_deletion_protection
}

