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
    
    Next Steps:
    
    1. Get cluster credentials:
       gcloud container clusters get-credentials ${module.gke_cluster.cluster_name} --region ${var.region} --project ${var.project_id}
    
    2. Generate required secrets:
       export API_KEY_SALT=$(openssl rand -base64 32)
       export JWT_SECRET=$(openssl rand -base64 32)
       export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
       export INSIGHTS_ENCRYPTION_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
    
    3. Configure GCS HMAC credentials for blob storage:
       - Go to GCP Console: Storage > Settings > Interoperability
       - Create a service account (or use existing) with "Storage Admin" role
       - Create HMAC key for the service account
       - Export the access key and secret:
         export GCS_ACCESS_KEY="your-hmac-access-key"
         export GCS_ACCESS_SECRET="your-hmac-secret"
       - Note: The bucket ${module.storage.bucket_name} must be accessible by this service account
    
    4. (Optional) Set admin credentials for injection via Helm --set:
       export ADMIN_EMAIL="admin@example.com"
       export ADMIN_PASSWORD="YourSecurePassword123!"

    5. Install LangSmith via Helm:
       helm repo add langchain https://langchain-ai.github.io/helm
       helm upgrade --install langsmith langchain/langsmith \
         ${var.langsmith_helm_chart_version != "" ? "--version ${var.langsmith_helm_chart_version} \\" : ""}
         -f ../helm/values/values.yaml \
         -f ../helm/values/values-overrides.yaml \
         -n ${var.langsmith_namespace} \
         --set config.langsmithLicenseKey="$(terraform output -raw langsmith_license_key)" \
         --set config.apiKeySalt="$API_KEY_SALT" \
         --set config.basicAuth.jwtSecret="$JWT_SECRET" \
         --set config.hostname="${var.langsmith_domain}" \
         --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
         --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
         --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
         --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
         --set config.blobStorage.bucketName="${module.storage.bucket_name}" \
         --set config.blobStorage.accessKey="$GCS_ACCESS_KEY" \
         --set config.blobStorage.accessKeySecret="$GCS_ACCESS_SECRET" \
         --set gateway.enabled=true \
         --set gateway.name="${var.install_ingress && var.ingress_type == "envoy" ? module.ingress[0].gateway_name : "langsmith-gateway"}" \
         --set gateway.namespace="envoy-gateway-system" \
         --set ingress.enabled=false${var.postgres_source == "in-cluster" ? " \\\n         --set postgres.internal.enabled=true --set postgres.external.enabled=false" : ""}${var.redis_source == "in-cluster" ? " \\\n         --set redis.internal.enabled=true --set redis.external.enabled=false" : ""}
    
    6. Configure DNS:
       ${var.langsmith_domain} -> ${var.install_ingress ? try(module.ingress[0].external_ip, "PENDING") : "YOUR_LOAD_BALANCER_IP"}
    
    7. Access LangSmith:
       https://${var.langsmith_domain}
       Login: Use ADMIN_EMAIL / ADMIN_PASSWORD (or values from ../helm/values/values.yaml)
    ${var.postgres_source == "in-cluster" ? "\n    NOTE: PostgreSQL is deployed in-cluster via Helm chart." : "\n    NOTE: PostgreSQL is external (Cloud SQL) with private IP connection."}
    ${var.redis_source == "in-cluster" ? "\n    NOTE: Redis is deployed in-cluster via Helm chart." : "\n    NOTE: Redis is external (Memorystore) with private IP connection."}
    \n    NOTE: GCS blob storage requires HMAC credentials. Create them in GCP Console (Storage > Settings > Interoperability) and export as GCS_ACCESS_KEY and GCS_ACCESS_SECRET before running the Helm command.
    ${var.tls_certificate_source == "none" ? "\n    NOTE: TLS is not configured. To enable HTTPS:\n    - Set tls_certificate_source = 'letsencrypt' for automatic certificates\n    - Set tls_certificate_source = 'existing' to use your own certificates\n    - Then run: terraform apply" : ""}
  EOT
}

#------------------------------------------------------------------------------
# Helm Install Command (Copy-Paste Ready)
#------------------------------------------------------------------------------
output "helm_install_command" {
  description = "Ready-to-use Helm install/upgrade command"
  value       = <<-EOT
    # Generate secrets first:
    export API_KEY_SALT=$(openssl rand -base64 32)
    export JWT_SECRET=$(openssl rand -base64 32)
    export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
    export INSIGHTS_ENCRYPTION_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
    
    # Admin credentials (optional - or use values from ../helm/values/values.yaml):
    export ADMIN_EMAIL="admin@example.com"
    export ADMIN_PASSWORD="YourSecurePassword123!"
    
    # Configure GCS HMAC credentials (create in GCP Console: Storage > Settings > Interoperability):
    export GCS_ACCESS_KEY="your-hmac-access-key"
    export GCS_ACCESS_SECRET="your-hmac-secret"
    
    helm upgrade --install langsmith langchain/langsmith \
      ${var.langsmith_helm_chart_version != "" ? "--version ${var.langsmith_helm_chart_version} \\" : ""}
      -f ../helm/values/values.yaml \
      -f ../helm/values/values-overrides.yaml \
      -n ${var.langsmith_namespace} \
      --set config.langsmithLicenseKey="$(terraform output -raw langsmith_license_key)" \
      --set config.apiKeySalt="$API_KEY_SALT" \
      --set config.basicAuth.jwtSecret="$JWT_SECRET" \
      --set config.hostname="${var.langsmith_domain}" \
      --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
      --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
      --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
      --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
      --set config.blobStorage.bucketName="${module.storage.bucket_name}" \
      --set config.blobStorage.accessKey="$GCS_ACCESS_KEY" \
      --set config.blobStorage.accessKeySecret="$GCS_ACCESS_SECRET" \
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
    "# Generate secrets if not already set:",
    "#   export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\")",
    "#   export INSIGHTS_ENCRYPTION_KEY=$(python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\")",
    "#",
    "# To upgrade LangSmith with current configuration:",
    "helm upgrade langsmith langchain/langsmith \\",
    var.langsmith_helm_chart_version != "" ? "  --version ${var.langsmith_helm_chart_version} \\" : "",
    "  -f ../helm/values/values.yaml \\",
    "  -f ../helm/values/values-overrides.yaml \\",
    "  -n ${var.langsmith_namespace} \\",
    "  --set config.langsmithLicenseKey=\"$(terraform output -raw langsmith_license_key)\" \\",
    "  --set config.apiKeySalt=\"$API_KEY_SALT\" \\",
    "  --set config.basicAuth.jwtSecret=\"$JWT_SECRET\" \\",
    "  --set config.hostname=\"${var.langsmith_domain}\" \\",
    "  --set config.basicAuth.initialOrgAdminEmail=\"$ADMIN_EMAIL\" \\",
    "  --set config.basicAuth.initialOrgAdminPassword=\"$ADMIN_PASSWORD\" \\",
    "  --set config.agentBuilder.encryptionKey=\"$AGENT_BUILDER_ENCRYPTION_KEY\" \\",
    "  --set config.insights.encryptionKey=\"$INSIGHTS_ENCRYPTION_KEY\" \\",
    "  --set gateway.enabled=true \\",
    "  --set ingress.enabled=false \\",
    "  --set gateway.name=\"${var.install_ingress && var.ingress_type == "envoy" ? module.ingress[0].gateway_name : "langsmith-gateway"}\" \\",
    "  --set gateway.namespace=\"envoy-gateway-system\" \\",
    "  --set config.blobStorage.bucketName=\"${module.storage.bucket_name}\" \\",
    "  --set config.blobStorage.accessKey=\"$GCS_ACCESS_KEY\" \\",
    "  --set config.blobStorage.accessKeySecret=\"$GCS_ACCESS_SECRET\""
  ]) : "TLS not configured. The Gateway uses HTTPS only (port 443). Set tls_certificate_source = 'letsencrypt' or 'existing' in terraform.tfvars before running terraform apply."
}
