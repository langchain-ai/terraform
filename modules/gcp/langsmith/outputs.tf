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
output "postgres_instance_name" {
  description = "Cloud SQL instance name"
  value       = module.cloudsql.instance_name
}

output "postgres_connection_ip" {
  description = "Cloud SQL connection IP (private or public based on use_private_networking)"
  value       = module.cloudsql.connection_ip
}

output "postgres_private_ip" {
  description = "Cloud SQL private IP address"
  value       = module.cloudsql.private_ip
}

output "postgres_public_ip" {
  description = "Cloud SQL public IP address"
  value       = module.cloudsql.public_ip
}

output "postgres_uses_private_ip" {
  description = "Whether Cloud SQL is using private IP"
  value       = module.cloudsql.uses_private_ip
}

output "postgres_database" {
  description = "PostgreSQL database name"
  value       = module.cloudsql.database_name
}

output "postgres_username" {
  description = "PostgreSQL username"
  value       = module.cloudsql.username
}

output "postgres_password" {
  description = "PostgreSQL password"
  value       = module.cloudsql.password
  sensitive   = true
}

#------------------------------------------------------------------------------
# Redis Outputs
#------------------------------------------------------------------------------
output "redis_instance_name" {
  description = "Redis instance name (null if using in-cluster Redis)"
  value       = var.use_private_networking ? module.redis[0].instance_name : null
}

output "redis_host" {
  description = "Redis host address (null if using in-cluster Redis)"
  value       = var.use_private_networking ? module.redis[0].host : null
}

output "redis_port" {
  description = "Redis port (null if using in-cluster Redis)"
  value       = var.use_private_networking ? module.redis[0].port : null
}

output "uses_managed_redis" {
  description = "Whether using managed Redis (Memorystore) or in-cluster Redis"
  value       = var.use_private_networking
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

output "use_private_networking" {
  description = "Whether private networking is enabled (affects Cloud SQL and Redis)"
  value       = var.use_private_networking
}

#------------------------------------------------------------------------------
# Ingress Outputs
#------------------------------------------------------------------------------
output "ingress_type" {
  description = "Type of ingress installed"
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
    postgres_instance    = module.cloudsql.instance_name
    postgres_ip_type     = var.use_private_networking ? "private" : "public"
    redis_instance       = var.use_private_networking ? module.redis[0].instance_name : "in-cluster (Helm)"
    clickhouse           = var.clickhouse_source == "in-cluster" ? "in-cluster (Helm)" : "${var.clickhouse_source} (${var.clickhouse_host})"
    storage_bucket       = module.storage.bucket_name
    service_account      = module.iam.service_account_email
    kubernetes_namespace = var.langsmith_namespace
    networking_mode      = var.use_private_networking ? "private" : "public"
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
    Networking Mode: ${var.use_private_networking ? "Private (VPC peering)" : "Public IPs"}
    
    Resources Created:
    - VPC: ${module.networking.vpc_name}
    - GKE Cluster: ${module.gke_cluster.cluster_name}
    - Cloud SQL: ${module.cloudsql.instance_name} (${var.use_private_networking ? "private IP" : "public IP"})
    - Redis: ${var.use_private_networking ? module.redis[0].instance_name : "In-cluster (via Helm)"}
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
       
       # For NGINX Ingress (default):
       helm install langsmith langchain/langsmith \
         -f langsmith-values.yaml \
         -n ${var.langsmith_namespace} \
         --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
         --set config.apiKeySalt="$API_KEY_SALT" \
         --set config.basicAuth.jwtSecret="$JWT_SECRET" \
         --set config.hostname="${var.langsmith_domain}" \
         --set blobStorage.gcs.bucket="${module.storage.bucket_name}" \
         --set blobStorage.gcs.projectId="${var.project_id}" \
         --set ingress.className=nginx${var.use_private_networking ? "" : " \\\n         --set redis.internal.enabled=true --set redis.external.enabled=false"}${var.tls_certificate_source == "letsencrypt" ? " \\\n         --set 'ingress.annotations.cert-manager\\.io/cluster-issuer=letsencrypt-prod' \\\n         --set-string 'ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true' \\\n         --set 'ingress.hosts[0].host=${var.langsmith_domain}' \\\n         --set 'ingress.tls[0].secretName=${var.tls_secret_name}' \\\n         --set 'ingress.tls[0].hosts[0]=${var.langsmith_domain}'" : var.tls_certificate_source == "existing" ? " \\\n         --set-string 'ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true' \\\n         --set 'ingress.hosts[0].host=${var.langsmith_domain}' \\\n         --set 'ingress.tls[0].secretName=${var.tls_secret_name}' \\\n         --set 'ingress.tls[0].hosts[0]=${var.langsmith_domain}'" : ""}
       
       # For Envoy Gateway (add these flags):
       --set ingress.enabled=false --set gateway.enabled=true
    
    4. Configure DNS:
       ${var.langsmith_domain} -> ${var.install_ingress ? try(module.ingress[0].external_ip, "PENDING") : "YOUR_LOAD_BALANCER_IP"}
    
    5. Access LangSmith:
       https://${var.langsmith_domain}
       Login: Use the credentials from langsmith-values.yaml (YOUR_ADMIN_EMAIL / YOUR_ADMIN_PASSWORD)
    ${var.use_private_networking ? "" : "\n    NOTE: Using public networking mode. Cloud SQL uses public IP with SSL.\n    Redis will be deployed in-cluster via Helm chart."}
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
    
    # Then install (NGINX Ingress by default):
    helm install langsmith langchain/langsmith \
      -f langsmith-values.yaml \
      -n ${var.langsmith_namespace} \
      --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
      --set config.apiKeySalt="$API_KEY_SALT" \
      --set config.basicAuth.jwtSecret="$JWT_SECRET" \
      --set config.hostname="${var.langsmith_domain}" \
      --set blobStorage.gcs.bucket="${module.storage.bucket_name}" \
      --set blobStorage.gcs.projectId="${var.project_id}" \
      --set ingress.className=nginx
    
    # For Envoy Gateway, add: --set ingress.enabled=false --set gateway.enabled=true
  EOT
}

output "helm_tls_upgrade_command" {
  description = "Helm upgrade command to enable HTTPS (varies by TLS source)"
  value = var.tls_certificate_source == "letsencrypt" ? join("\n", [
    "# Enable HTTPS with Let's Encrypt (run after DNS is configured):",
    "helm upgrade langsmith langchain/langsmith \\",
    "  -f langsmith-values.yaml \\",
    "  -n ${var.langsmith_namespace} \\",
    "  --set config.langsmithLicenseKey=\"$LANGSMITH_LICENSE_KEY\" \\",
    "  --set config.apiKeySalt=\"$API_KEY_SALT\" \\",
    "  --set config.basicAuth.jwtSecret=\"$JWT_SECRET\" \\",
    "  --set config.hostname=\"${var.langsmith_domain}\" \\",
    "  --set ingress.className=nginx \\",
    "  --set 'ingress.annotations.cert-manager\\.io/cluster-issuer=letsencrypt-prod' \\",
    "  --set-string 'ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true' \\",
    "  --set 'ingress.hosts[0].host=${var.langsmith_domain}' \\",
    "  --set 'ingress.tls[0].secretName=${var.tls_secret_name}' \\",
    "  --set 'ingress.tls[0].hosts[0]=${var.langsmith_domain}' \\",
    "  --set blobStorage.gcs.bucket=\"${module.storage.bucket_name}\" \\",
    "  --set blobStorage.gcs.projectId=\"${var.project_id}\""
  ]) : var.tls_certificate_source == "existing" ? join("\n", [
    "# Enable HTTPS with existing certificate (secret already created by Terraform):",
    "helm upgrade langsmith langchain/langsmith \\",
    "  -f langsmith-values.yaml \\",
    "  -n ${var.langsmith_namespace} \\",
    "  --set config.langsmithLicenseKey=\"$LANGSMITH_LICENSE_KEY\" \\",
    "  --set config.apiKeySalt=\"$API_KEY_SALT\" \\",
    "  --set config.basicAuth.jwtSecret=\"$JWT_SECRET\" \\",
    "  --set config.hostname=\"${var.langsmith_domain}\" \\",
    "  --set ingress.className=nginx \\",
    "  --set-string 'ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/ssl-redirect=true' \\",
    "  --set 'ingress.hosts[0].host=${var.langsmith_domain}' \\",
    "  --set 'ingress.tls[0].secretName=${var.tls_secret_name}' \\",
    "  --set 'ingress.tls[0].hosts[0]=${var.langsmith_domain}' \\",
    "  --set blobStorage.gcs.bucket=\"${module.storage.bucket_name}\" \\",
    "  --set blobStorage.gcs.projectId=\"${var.project_id}\""
  ]) : "TLS not configured. Set tls_certificate_source = 'letsencrypt' or 'existing' to enable."
}
