#------------------------------------------------------------------------------
# Naming
#------------------------------------------------------------------------------
output "name_prefix" {
  description = "Name prefix used for all resources"
  value       = var.name_prefix
}

output "naming_convention" {
  description = "Naming convention used: {name_prefix}-{environment}-{resource}"
  value       = "${var.name_prefix}-${var.environment}-{resource}"
}

#------------------------------------------------------------------------------
# EKS Cluster
#------------------------------------------------------------------------------
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "get_credentials_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

#------------------------------------------------------------------------------
# PostgreSQL (RDS)
#------------------------------------------------------------------------------
output "postgres_source" {
  description = "PostgreSQL deployment type: external (RDS) or in-cluster (Helm)"
  value       = var.postgres_source
}

output "postgres_connection_url" {
  description = "PostgreSQL connection URL (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.postgres[0].connection_url : null
  sensitive   = true
}

output "postgres_iam_connection_url" {
  description = "Connection URL for IAM authentication — no password (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.postgres[0].iam_connection_url : null
}

#------------------------------------------------------------------------------
# Redis (ElastiCache)
#------------------------------------------------------------------------------
output "redis_source" {
  description = "Redis deployment type: external (ElastiCache) or in-cluster (Helm)"
  value       = var.redis_source
}

output "redis_connection_url" {
  description = "Redis connection URL (null if using in-cluster Redis)"
  value       = var.redis_source == "external" ? module.redis[0].connection_url : null
  sensitive   = true
}

#------------------------------------------------------------------------------
# Storage (S3)
#------------------------------------------------------------------------------
output "bucket_name" {
  description = "S3 bucket name for blob storage"
  value       = local.bucket_name
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = module.storage.bucket_arn
}

#------------------------------------------------------------------------------
# Networking
#------------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = local.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = local.vpc_cidr_block
}

#------------------------------------------------------------------------------
# IAM / IRSA
#------------------------------------------------------------------------------
output "langsmith_irsa_role_arn" {
  description = "IAM role ARN for LangSmith pods (IRSA) — used for S3 access"
  value       = module.eks.langsmith_irsa_role_arn
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator — used to read SSM Parameter Store"
  value       = aws_iam_role.eso.arn
}

#------------------------------------------------------------------------------
# Secrets Manager
#------------------------------------------------------------------------------
output "secrets_manager_secret_arn" {
  description = "ARN of the Secrets Manager secret containing LangSmith credentials"
  value       = module.secrets.secret_arn
}

#------------------------------------------------------------------------------
# ALB
#------------------------------------------------------------------------------
output "alb_arn" {
  description = "ARN of the pre-provisioned ALB"
  value       = module.alb.alb_arn
}

output "alb_dns_name" {
  description = "ALB DNS hostname — use as config.hostname in Helm values"
  value       = module.alb.alb_dns_name
}

output "langsmith_url" {
  description = "LangSmith application URL. Uses custom domain if langsmith_domain is set, otherwise falls back to the ALB DNS name."
  value       = var.tls_certificate_source == "none" ? "http://${module.alb.alb_dns_name}" : (var.langsmith_domain != "" ? "https://${var.langsmith_domain}" : "https://${module.alb.alb_dns_name}")
}

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
output "langsmith_namespace" {
  description = "Kubernetes namespace where LangSmith is deployed"
  value       = var.langsmith_namespace
}

output "tls_certificate_source" {
  description = "TLS certificate source: acm, letsencrypt, or none"
  value       = var.tls_certificate_source
}

#------------------------------------------------------------------------------
# DNS / ACM (auto-provisioned)
#------------------------------------------------------------------------------
output "dns_name_servers" {
  description = "Route 53 NS records — delegate these from your registrar to enable your custom domain and ACM certificate validation"
  value       = local.dns_enabled ? module.dns[0].name_servers : []
}

output "dns_zone_id" {
  description = "Route 53 hosted zone ID (null when dns module is not used)"
  value       = local.dns_enabled ? module.dns[0].zone_id : null
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN (from dns module or provided directly)"
  value       = var.acm_certificate_arn != "" ? var.acm_certificate_arn : (local.dns_enabled ? module.dns[0].certificate_arn : null)
}

#------------------------------------------------------------------------------
# Resource Summary
#------------------------------------------------------------------------------
output "resource_summary" {
  description = "Summary of provisioned resources"
  value = {
    cluster         = module.eks.cluster_name
    postgres_source = var.postgres_source
    postgres        = var.postgres_source == "external" ? "external (RDS)" : "in-cluster (Helm)"
    redis_source    = var.redis_source
    redis           = var.redis_source == "external" ? "external (ElastiCache)" : "in-cluster (Helm)"
    storage_bucket  = local.bucket_name
    namespace       = var.langsmith_namespace
    tls             = var.tls_certificate_source
    alb             = module.alb.alb_dns_name
  }
}

#------------------------------------------------------------------------------
# Next Steps
#------------------------------------------------------------------------------
output "next_steps" {
  description = "Next steps after terraform apply"
  value       = <<-EOT

    ============================================
    LangSmith Infrastructure Provisioned (AWS)
    ============================================

    Naming: ${var.name_prefix}-${var.environment}-{resource}

    Resources:
    - EKS Cluster:  ${module.eks.cluster_name}
    - PostgreSQL:   ${var.postgres_source == "external" ? "external (RDS)" : "in-cluster (Helm)"}
    - Redis:        ${var.redis_source == "external" ? "external (ElastiCache)" : "in-cluster (Helm)"}
    - S3 Bucket:    ${local.bucket_name}
    - ALB:          ${module.alb.alb_dns_name}
    - TLS:          ${var.tls_certificate_source}${local.dns_enabled ? "\n    - Domain:       ${var.langsmith_domain} (Route 53 + ACM auto-provisioned)" : ""}

    Next Steps:

    1. Update kubeconfig:
       aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}
${local.dns_enabled && var.tls_certificate_source != "acm" ? <<-DNS

    2. DELEGATE DNS — required before enabling HTTPS
       Terraform created a Route 53 hosted zone for ${var.langsmith_domain}.
       Add NS records at your registrar (or parent zone) pointing to:

         terraform output dns_name_servers

       Once delegated, the ACM certificate validates automatically (~5-30 min).
       You can check certificate status in the AWS Console under Certificate Manager.

    3. ENABLE HTTPS — after NS delegation is complete
       In terraform.tfvars, change:
         tls_certificate_source = "acm"
       Then run: terraform apply
       This adds the HTTPS listener to the ALB and redirects HTTP → HTTPS.

    4. Run the Helm deployment:
       cd ../helm && source ../infra/setup-env.sh --deploy && ./scripts/deploy.sh

    5. Access LangSmith:
       http://${module.alb.alb_dns_name}  (HTTP — until you complete step 3)

DNS
: local.dns_enabled && var.tls_certificate_source == "acm" ? <<-ACMDONE

    2. Run the Helm deployment:
       cd ../helm && source ../infra/setup-env.sh --deploy && ./scripts/deploy.sh

    3. Access LangSmith:
       https://${var.langsmith_domain}

ACMDONE
: <<-NODNS

    2. Run the Helm deployment:
       cd ../helm && source ../infra/setup-env.sh --deploy && ./scripts/deploy.sh

    3. Access LangSmith:
       ${var.tls_certificate_source == "none" ? "http://${module.alb.alb_dns_name}" : (var.langsmith_domain != "" ? "https://${var.langsmith_domain}" : "https://${module.alb.alb_dns_name}")}

NODNS
}
  EOT
}
