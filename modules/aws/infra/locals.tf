# Centralized naming and computed values.
# Format: {name_prefix}-{environment}-{resource}
# Example with name_prefix="acme", environment="prod": acme-prod-eks

locals {
  base_name     = "${var.name_prefix}-${var.environment}"
  vpc_name      = "${local.base_name}-vpc"
  cluster_name  = "${local.base_name}-eks"
  redis_name    = "${local.base_name}-redis"
  bucket_name   = "${local.base_name}-traces"
  postgres_name = "${local.base_name}-pg"
  secret_name   = "${local.base_name}-langsmith"
  alb_name      = "${local.base_name}-alb"

  common_tags = merge(
    {
      app         = "langsmith"
      environment = var.environment
      managed-by  = "terraform"
      name-prefix = var.name_prefix
      owner       = var.owner
    },
    var.cost_center != "" ? { "cost-center" = var.cost_center } : {},
    var.tags
  )

  vpc_id          = var.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  private_subnets = var.create_vpc ? module.vpc[0].private_subnets : var.private_subnets
  public_subnets  = var.create_vpc ? module.vpc[0].public_subnets : var.public_subnets
  vpc_cidr_block  = var.create_vpc ? module.vpc[0].vpc_cidr_block : var.vpc_cidr_block
}
