# Outputs for LangSmith GKE Terraform Configuration

#------------------------------------------------------------------------------
# Naming Information
#------------------------------------------------------------------------------
output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "environment" {
  description = "Environment name"
  value       = var.environment
}

output "langsmith_namespace" {
  description = "Kubernetes namespace for LangSmith"
  value       = var.langsmith_namespace
}

output "name_prefix" {
  description = "Name prefix used for all resources"
  value       = var.name_prefix
}

output "resource_suffix" {
  description = "Random suffix appended to resource names"
  value       = var.unique_suffix ? random_id.suffix.hex : "none"
}

output "naming_convention" {
  description = "Naming convention used"
  value       = "${var.name_prefix}-${var.environment}-{resource}${var.unique_suffix ? "-${random_id.suffix.hex}" : ""}"
}

#------------------------------------------------------------------------------
# GKE Cluster Outputs
#------------------------------------------------------------------------------
output "cluster_name" {
  description = "GKE cluster name"
  value       = module.gke_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "GKE cluster endpoint"
  value       = module.gke_cluster.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "GKE cluster CA certificate"
  value       = module.gke_cluster.ca_certificate
  sensitive   = true
}

output "get_credentials_command" {
  description = "Command to get cluster credentials"
  value       = "gcloud container clusters get-credentials ${module.gke_cluster.cluster_name} --region ${var.region} --project ${var.project_id}"
}

#------------------------------------------------------------------------------
# Database Outputs
#------------------------------------------------------------------------------
output "postgres_source" {
  description = "PostgreSQL deployment type"
  value       = var.postgres_source
}

output "postgres_instance_name" {
  description = "Cloud SQL instance name (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].instance_name : null
}

output "postgres_connection_ip" {
  description = "Cloud SQL private IP address (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].connection_ip : null
}

output "postgres_private_ip" {
  description = "Cloud SQL private IP address (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].private_ip : null
}

output "postgres_database" {
  description = "PostgreSQL database name (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].database_name : null
}

output "postgres_username" {
  description = "PostgreSQL username (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].username : null
}

output "postgres_password" {
  description = "PostgreSQL password (null if using in-cluster PostgreSQL)"
  value       = var.postgres_source == "external" ? module.cloudsql[0].password : null
  sensitive   = true
}

#------------------------------------------------------------------------------
# Redis Outputs
#------------------------------------------------------------------------------
output "redis_source" {
  description = "Redis deployment type"
  value       = var.redis_source
}

output "redis_instance_name" {
  description = "Redis instance name (null if using in-cluster Redis)"
  value       = var.redis_source == "external" ? module.redis[0].instance_name : null
}

output "redis_host" {
  description = "Redis host address (null if using in-cluster Redis)"
  value       = var.redis_source == "external" ? module.redis[0].host : null
}

output "redis_port" {
  description = "Redis port (null if using in-cluster Redis)"
  value       = var.redis_source == "external" ? module.redis[0].port : null
}

#------------------------------------------------------------------------------
# ClickHouse Outputs
#------------------------------------------------------------------------------
output "clickhouse_source" {
  description = "ClickHouse deployment type: in-cluster, langsmith-managed, or external"
  value       = var.clickhouse_source
}

output "clickhouse_host" {
  description = "ClickHouse host (null if in-cluster)"
  value       = var.clickhouse_source != "in-cluster" ? var.clickhouse_host : null
}

output "uses_external_clickhouse" {
  description = "Whether using external ClickHouse (managed or self-hosted)"
  value       = module.k8s_bootstrap.uses_external_clickhouse
}

#------------------------------------------------------------------------------
# Storage Outputs
#------------------------------------------------------------------------------
output "storage_bucket_name" {
  description = "Cloud Storage bucket name for traces"
  value       = module.storage.bucket_name
}

output "storage_bucket_url" {
  description = "Cloud Storage bucket URL"
  value       = module.storage.bucket_url
}

#------------------------------------------------------------------------------
# IAM / Secrets / DNS Outputs
#------------------------------------------------------------------------------
output "workload_identity_service_account_email" {
  description = "GCP service account email used for Workload Identity (null when IAM module is disabled)"
  value       = var.enable_gcp_iam_module ? module.iam[0].service_account_email : null
}

output "workload_identity_annotation" {
  description = "Kubernetes annotation value for iam.gke.io/gcp-service-account (null when IAM module is disabled)"
  value       = var.enable_gcp_iam_module ? module.iam[0].workload_identity_annotation : null
}

output "secret_manager_secret_id" {
  description = "Secret Manager secret ID created by secrets module (null when disabled)"
  value       = var.enable_secret_manager_module ? module.secrets[0].secret_id : null
}

output "dns_zone_name" {
  description = "Cloud DNS managed zone name (null when DNS module is disabled)"
  value       = var.enable_dns_module ? module.dns[0].zone_name : null
}

output "dns_name_servers" {
  description = "Name servers for Cloud DNS zone (empty when DNS module is disabled)"
  value       = var.enable_dns_module ? module.dns[0].name_servers : []
}

output "managed_certificate_name" {
  description = "Google-managed certificate name (null when DNS module is disabled)"
  value       = var.enable_dns_module ? module.dns[0].certificate_name : null
}

#------------------------------------------------------------------------------
# Networking Outputs
#------------------------------------------------------------------------------
output "vpc_name" {
  description = "VPC network name"
  value       = module.networking.vpc_name
}

output "subnet_name" {
  description = "Subnet name"
  value       = module.networking.subnet_name
}


#------------------------------------------------------------------------------
# Ingress Outputs
#------------------------------------------------------------------------------
output "ingress_type" {
  description = "Type of ingress/gateway installed"
  value       = var.install_ingress ? var.ingress_type : "not installed"
}

output "ingress_ip" {
  description = "Ingress external IP address"
  value       = var.install_ingress ? try(module.ingress[0].external_ip, "pending") : "not installed"
}

output "langsmith_url" {
  description = "LangSmith URL"
  value       = "https://${var.langsmith_domain}"
}

output "langsmith_domain" {
  description = "LangSmith domain"
  value       = var.langsmith_domain
}

output "langsmith_license_key" {
  description = "LangSmith license key"
  value       = var.langsmith_license_key
  sensitive   = true
}

output "langsmith_helm_chart_version" {
  description = "Pinned LangSmith Helm chart version (empty means latest)"
  value       = var.langsmith_helm_chart_version
}

#------------------------------------------------------------------------------
# LangSmith Deployment Outputs
#------------------------------------------------------------------------------
output "langsmith_deployment_enabled" {
  description = "Whether LangSmith Deployment feature is enabled"
  value       = var.enable_langsmith_deployment
}

output "keda_installed" {
  description = "Whether KEDA is installed (required for LangSmith Deployment)"
  value       = module.k8s_bootstrap.keda_installed
}

output "keda_namespace" {
  description = "Namespace where KEDA is installed"
  value       = module.k8s_bootstrap.keda_namespace
}

#------------------------------------------------------------------------------
# TLS / cert-manager Outputs
#------------------------------------------------------------------------------
output "tls_certificate_source" {
  description = "TLS certificate source: none, letsencrypt, or existing"
  value       = var.tls_certificate_source
}

output "tls_secret_name" {
  description = "Name of the TLS secret in Kubernetes"
  value       = module.k8s_bootstrap.tls_secret_name
}

output "tls_configured" {
  description = "Whether TLS is configured"
  value       = module.k8s_bootstrap.tls_configured
}

output "cert_manager_installed" {
  description = "Whether cert-manager is installed for automatic TLS"
  value       = module.k8s_bootstrap.cert_manager_installed
}

output "letsencrypt_issuer" {
  description = "Let's Encrypt ClusterIssuer name (use in ingress annotations)"
  value       = module.k8s_bootstrap.letsencrypt_issuer_name
}

#------------------------------------------------------------------------------
# Resource Summary
#------------------------------------------------------------------------------
output "resource_summary" {
  description = "Summary of created resources"
  value = {
    vpc                  = module.networking.vpc_name
    subnet               = module.networking.subnet_name
    gke_cluster          = module.gke_cluster.cluster_name
    postgres_source      = var.postgres_source
    postgres_instance    = var.postgres_source == "external" ? module.cloudsql[0].instance_name : "in-cluster (Helm)"
    postgres_ip_type     = var.postgres_source == "external" ? "private" : "N/A"
    redis_source         = var.redis_source
    redis_instance       = var.redis_source == "external" ? module.redis[0].instance_name : "in-cluster (Helm)"
    clickhouse_source    = var.clickhouse_source
    clickhouse           = var.clickhouse_source == "in-cluster" ? "in-cluster (Helm)" : "${var.clickhouse_source} (${var.clickhouse_host})"
    storage_bucket       = module.storage.bucket_name
    kubernetes_namespace = var.langsmith_namespace
  }
}

#------------------------------------------------------------------------------
# Next Steps
#------------------------------------------------------------------------------
output "next_steps" {
  description = "Next steps after Terraform apply"
  value       = <<-EOT

    LangSmith infrastructure provisioned.

    1. Generate Helm values from Terraform outputs:
         make init-values
         (or: ./helm/scripts/init-values.sh)

    2. Deploy LangSmith:
         make deploy
         (or: ./helm/scripts/deploy.sh)

    3. Configure DNS:
         Point ${var.langsmith_domain} → $(terraform output -raw ingress_ip)

    Cluster credentials:
         ${module.gke_cluster.cluster_name}
         gcloud container clusters get-credentials ${module.gke_cluster.cluster_name} --region ${var.region} --project ${var.project_id}

    GCS bucket: ${module.storage.bucket_name}
    (HMAC key required — create in GCP Console: Storage → Settings → Interoperability)
  EOT
}
