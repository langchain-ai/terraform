# Outputs for LangSmith GKE Terraform Configuration

#------------------------------------------------------------------------------
# Naming Information
#------------------------------------------------------------------------------
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
# IAM Outputs
#------------------------------------------------------------------------------
output "service_account_email" {
  description = "LangSmith service account email"
  value       = module.iam.service_account_email
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
    service_account      = module.iam.service_account_email
    kubernetes_namespace = var.langsmith_namespace
  }
}

#------------------------------------------------------------------------------
# Next Steps
#------------------------------------------------------------------------------
output "next_steps" {
  description = "Next steps after Terraform apply"
  value       = <<-EOT
    
    ============================================
    LangSmith Infrastructure Created Successfully!
    ============================================
    
    Naming Convention: ${var.name_prefix}-${var.environment}-{resource}${var.unique_suffix ? "-${random_id.suffix.hex}" : ""}
    
    Resources Created:
    - VPC: ${module.networking.vpc_name}
    - GKE Cluster: ${module.gke_cluster.cluster_name}
    - PostgreSQL: ${var.postgres_source == "external" ? "${module.cloudsql[0].instance_name} (Cloud SQL, private IP)" : "In-cluster (via Helm)"}
    - Redis: ${var.redis_source == "external" ? "${module.redis[0].instance_name} (Memorystore, private IP)" : "In-cluster (via Helm)"}
    - ClickHouse: ${var.clickhouse_source == "in-cluster" ? "In-cluster (via Helm)" : "${var.clickhouse_source} (${var.clickhouse_host})"}
    - Storage: ${module.storage.bucket_name}
    - Service Account: ${module.iam.service_account_email}
    
    Next Steps:
    
    1. Get cluster credentials:
       gcloud container clusters get-credentials ${module.gke_cluster.cluster_name} --region ${var.region} --project ${var.project_id}
    
    2. Generate required secrets:
       export API_KEY_SALT=$(openssl rand -base64 32)
       export JWT_SECRET=$(openssl rand -base64 32)
    
    3. Install LangSmith via Helm:
       helm repo add langchain https://langchain-ai.github.io/helm
       
       # For Envoy Gateway (default):
       helm install langsmith langchain/langsmith \
         -f langsmith-values.yaml \
         -n ${var.langsmith_namespace} \
         --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
         --set config.apiKeySalt="$API_KEY_SALT" \
         --set config.basicAuth.jwtSecret="$JWT_SECRET" \
         --set config.hostname="${var.langsmith_domain}" \
         --set blobStorage.gcs.bucket="${module.storage.bucket_name}" \
         --set blobStorage.gcs.projectId="${var.project_id}" \
         --set gateway.enabled=true \
         --set ingress.enabled=false \
         --set gateway.name="${var.install_ingress && var.ingress_type == "envoy" ? module.ingress[0].gateway_name : "langsmith-gateway"}" \
         --set gateway.namespace="envoy-gateway-system"${var.postgres_source == "in-cluster" ? " \\\n         --set postgres.internal.enabled=true --set postgres.external.enabled=false" : ""}${var.redis_source == "in-cluster" ? " \\\n         --set redis.internal.enabled=true --set redis.external.enabled=false" : ""}
    
    4. Configure DNS:
       ${var.langsmith_domain} -> ${var.install_ingress ? try(module.ingress[0].external_ip, "PENDING") : "YOUR_LOAD_BALANCER_IP"}
    
    5. Access LangSmith:
       https://${var.langsmith_domain}
       Login: Use the credentials from langsmith-values.yaml (YOUR_ADMIN_EMAIL / YOUR_ADMIN_PASSWORD)
    ${var.postgres_source == "in-cluster" ? "\n    NOTE: PostgreSQL is deployed in-cluster via Helm chart." : "\n    NOTE: PostgreSQL is external (Cloud SQL) with private IP connection."}
    ${var.redis_source == "in-cluster" ? "\n    NOTE: Redis is deployed in-cluster via Helm chart." : "\n    NOTE: Redis is external (Memorystore) with private IP connection."}
    ${var.tls_certificate_source == "none" ? "\n    NOTE: TLS is not configured. To enable HTTPS:\n    - Set tls_certificate_source = 'letsencrypt' for automatic certificates\n    - Set tls_certificate_source = 'existing' to use your own certificates\n    - Then run: terraform apply" : ""}
  EOT
}

#------------------------------------------------------------------------------
# Helm Install Command (Copy-Paste Ready)
#------------------------------------------------------------------------------
output "helm_install_command" {
  description = "Ready-to-use Helm install command (replace YOUR_LICENSE_KEY)"
  value       = <<-EOT
    # Generate secrets first:
    export API_KEY_SALT=$(openssl rand -base64 32)
    export JWT_SECRET=$(openssl rand -base64 32)
    
    # Then install (Envoy Gateway by default):
    helm install langsmith langchain/langsmith \
      -f langsmith-values.yaml \
      -n ${var.langsmith_namespace} \
      --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
      --set config.apiKeySalt="$API_KEY_SALT" \
      --set config.basicAuth.jwtSecret="$JWT_SECRET" \
      --set config.hostname="${var.langsmith_domain}" \
      --set blobStorage.gcs.bucket="${module.storage.bucket_name}" \
      --set blobStorage.gcs.projectId="${var.project_id}" \
      --set gateway.enabled=true \
      --set ingress.enabled=false \
      --set gateway.name="${var.install_ingress && var.ingress_type == "envoy" ? module.ingress[0].gateway_name : "langsmith-gateway"}" \
      --set gateway.namespace="envoy-gateway-system"
  EOT
}

output "helm_tls_upgrade_command" {
  description = "Helm upgrade command (TLS is configured in Gateway, not via Helm)"
  value = var.tls_certificate_source != "none" ? join("\n", [
    "# TLS is configured in the Gateway resource via Terraform.",
    "# The Gateway uses HTTPS only (port 443) - TLS is required.",
    "# No additional Helm flags needed for TLS when using Envoy Gateway.",
    "#",
    "# To upgrade LangSmith with current configuration:",
    "helm upgrade langsmith langchain/langsmith \\",
    "  -f langsmith-values.yaml \\",
    "  -n ${var.langsmith_namespace} \\",
    "  --set config.langsmithLicenseKey=\"$LANGSMITH_LICENSE_KEY\" \\",
    "  --set config.apiKeySalt=\"$API_KEY_SALT\" \\",
    "  --set config.basicAuth.jwtSecret=\"$JWT_SECRET\" \\",
    "  --set config.hostname=\"${var.langsmith_domain}\" \\",
    "  --set gateway.enabled=true \\",
    "  --set ingress.enabled=false \\",
    "  --set gateway.name=\"${var.install_ingress && var.ingress_type == "envoy" ? module.ingress[0].gateway_name : "langsmith-gateway"}\" \\",
    "  --set gateway.namespace=\"envoy-gateway-system\" \\",
    "  --set blobStorage.gcs.bucket=\"${module.storage.bucket_name}\" \\",
    "  --set blobStorage.gcs.projectId=\"${var.project_id}\""
  ]) : "TLS not configured. The Gateway uses HTTPS only (port 443). Set tls_certificate_source = 'letsencrypt' or 'existing' in terraform.tfvars before running terraform apply."
}
