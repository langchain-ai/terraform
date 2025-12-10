# LangSmith GCP - Quick Reference Guide

This guide provides step-by-step commands to deploy LangSmith on GCP using Terraform.

## Prerequisites and Setup Commands

### 1. Authenticate with GCP

```bash
# Login to GCP (opens browser for authentication)
gcloud auth login

# Set application default credentials for Terraform
gcloud auth application-default login

# Set your project (replace with your actual project ID)
gcloud config set project YOUR_PROJECT_ID

# Verify you're using the correct project
gcloud config get-value project
```

### 2. Navigate to the LangSmith Module Directory

```bash
cd terraform/modules/gcp/langsmith
```

### 3. Configure Terraform Variables

```bash
# Copy the example variables file
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values (at minimum, set project_id)
# You can use your preferred editor:
nano terraform.tfvars
# or
vim terraform.tfvars
```

### 4. Initialize Terraform

```bash
terraform init
```

### 5. Review Terraform Plan

```bash
# Review what will be created (recommended before applying)
terraform plan
```

### 6. Apply Terraform Configuration

```bash
# Apply the configuration (creates all resources)
terraform apply

# Or use auto-approve to skip confirmation (use with caution)
terraform apply -auto-approve
```

### 7. Get GKE Cluster Credentials

```bash
# Get cluster credentials (replace values from terraform output)
gcloud container clusters get-credentials $(terraform output -raw cluster_name) \
  --region us-west2 \
  --project $(gcloud config get-value project)

# Or manually (replace with actual values from terraform outputs):
gcloud container clusters get-credentials CLUSTER_NAME --region us-west2 --project YOUR_PROJECT_ID
```

### 8. Verify Cluster Access

```bash
# Verify kubectl is configured correctly
kubectl cluster-info

# Check nodes
kubectl get nodes
```

### 9. Prepare for Helm Installation

```bash
# Generate required secrets
export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)

# Add LangChain Helm repository
helm repo add langchain https://langchain-ai.github.io/helm
helm repo update
```

### 10. Get Terraform Outputs (for Helm values)

```bash
# View all outputs
terraform output

# Get specific values
terraform output -raw storage_bucket_name
terraform output -raw postgres_connection_ip
terraform output -raw redis_host
terraform output -raw cluster_name
```

### 11. Install LangSmith via Helm

#### Basic Installation (No TLS)

```bash
helm install langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith \
  --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="langsmith.example.com" \
  --set blobStorage.gcs.bucket="$(terraform output -raw storage_bucket_name)" \
  --set blobStorage.gcs.projectId="$(gcloud config get-value project)" \
  --set 'config.basicAuth.initialOrgAdminEmail=your-email@example.com' \
  --set 'config.basicAuth.initialOrgAdminPassword=YourSecurePassword123!'
```

#### Installation with Let's Encrypt TLS

```bash
helm install langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith \
  --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="langsmith.example.com" \
  --set blobStorage.gcs.bucket="$(terraform output -raw storage_bucket_name)" \
  --set blobStorage.gcs.projectId="$(gcloud config get-value project)" \
  --set 'config.basicAuth.initialOrgAdminEmail=your-email@example.com' \
  --set 'config.basicAuth.initialOrgAdminPassword=YourSecurePassword123!' \
  --set 'ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt-prod' \
  --set-string 'ingress.annotations.nginx\.ingress\.kubernetes\\.io/ssl-redirect=true' \
  --set 'ingress.hosts[0].host=langsmith.example.com' \
  --set 'ingress.tls[0].secretName=langsmith-tls' \
  --set 'ingress.tls[0].hosts[0]=langsmith.example.com'
```

#### Installation with Existing TLS Certificate

```bash
helm install langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith \
  --set config.langsmithLicenseKey="YOUR_LICENSE_KEY" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="langsmith.example.com" \
  --set blobStorage.gcs.bucket="$(terraform output -raw storage_bucket_name)" \
  --set blobStorage.gcs.projectId="$(gcloud config get-value project)" \
  --set 'config.basicAuth.initialOrgAdminEmail=your-email@example.com' \
  --set 'config.basicAuth.initialOrgAdminPassword=YourSecurePassword123!' \
  --set-string 'ingress.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect=true' \
  --set 'ingress.hosts[0].host=langsmith.example.com' \
  --set 'ingress.tls[0].secretName=langsmith-tls' \
  --set 'ingress.tls[0].hosts[0]=langsmith.example.com'
```

#### For Envoy Gateway (instead of NGINX)

Add these flags to any of the above commands:
```bash
  --set ingress.enabled=false --set gateway.enabled=true
```

### 12. Configure DNS

Point your domain to the ingress external IP:

```bash
# Get the external IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Or if using Envoy Gateway
kubectl get svc -n envoy-gateway-system envoy-envoy-gateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Then configure your DNS:
```
langsmith.example.com -> <EXTERNAL_IP>
```

## Quick Reference Commands

### View Terraform State

```bash
terraform show
```

### Upgrade LangSmith Helm Release

```bash
helm upgrade langsmith langchain/langsmith \
  -f langsmith-values.yaml \
  -n langsmith
```

### Uninstall LangSmith

```bash
helm uninstall langsmith -n langsmith
```

### Destroy All Resources (Use with Caution!)

```bash
# First uninstall Helm release
helm uninstall langsmith -n langsmith

# Then destroy Terraform resources
terraform destroy
```

## Troubleshooting

### Check Helm Release Status

```bash
helm status langsmith -n langsmith
```

### View LangSmith Pods

```bash
kubectl get pods -n langsmith
```

### View LangSmith Logs

```bash
# Backend logs
kubectl logs -n langsmith -l app=langsmith-backend --tail=100

# Frontend logs
kubectl logs -n langsmith -l app=langsmith-frontend --tail=100
```

### Check Ingress Configuration

```bash
kubectl get ingress -n langsmith
kubectl describe ingress -n langsmith
```

## Important Notes

- **TLS Configuration**: Set `tls_certificate_source` in `terraform.tfvars` to `"letsencrypt"` or `"existing"` before running `terraform apply` to enable TLS in the Helm install command output.
- **Private Networking**: When using private networking mode, Redis will be managed by Memorystore. When using public networking, Redis is deployed in-cluster via Helm.
- **State Management**: Consider using a GCS backend for Terraform state in production (uncomment backend configuration in `main.tf`).
