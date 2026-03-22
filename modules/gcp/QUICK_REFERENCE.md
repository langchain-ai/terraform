# LangSmith on GCP — Quick Reference

---

## Pass 1 — Terraform Infrastructure

```bash
# Authenticate
gcloud auth login
gcloud config set project <your-project-id>
gcloud auth application-default login

# AWS-style task runner flow (recommended)
cd terraform/gcp
make preflight
make init
make plan
make apply

# Configure
cd terraform/gcp/infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Deploy
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# Get cluster credentials from Terraform outputs
cd ../helm/scripts
./get-kubeconfig.sh

# Verify
kubectl get nodes
kubectl get ns
kubectl get pods -n cert-manager
kubectl get pods -n keda
kubectl get secrets -n langsmith
```

---

## Pass 2 — LangSmith Helm Deploy

```bash
# Use scripted deployment (AWS-style guardrails)
cd terraform/gcp/helm/scripts
./deploy.sh

# Or run manually:
export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export INSIGHTS_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export ADMIN_EMAIL="admin@example.com"
export ADMIN_PASSWORD="<strong-password>"
# Create HMAC key in GCP Console: Storage > Settings > Interoperability
export GCS_ACCESS_KEY="<hmac-access-key>"
export GCS_ACCESS_SECRET="<hmac-secret>"

helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith --create-namespace \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.langsmithLicenseKey="<your-license-key>" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="<your-langsmith-domain>" \
  --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
  --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
  --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
  --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
  --set config.blobStorage.bucketName="$(terraform output -raw storage_bucket_name)" \
  --set config.blobStorage.accessKey="$GCS_ACCESS_KEY" \
  --set config.blobStorage.accessKeySecret="$GCS_ACCESS_SECRET" \
  --set gateway.enabled=true \
  --set ingress.enabled=false \
  --wait --timeout 15m

# Get Gateway IP for DNS
kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=langsmith-gateway \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'

# Verify pods
kubectl get pods -n langsmith

# Check TLS certificate
kubectl get certificate -n langsmith
```

---

## Pass 3 — LangSmith Deployments (Optional)

```bash
# Add to terraform.tfvars:
#   enable_langsmith_deployment = true

cd terraform/gcp/infra
terraform apply -var-file=terraform.tfvars

kubectl get pods -n keda

helm upgrade langsmith langchain/langsmith \
  --namespace langsmith \
  -f ../helm/values/values.yaml \
  -f ../helm/values/values-overrides.yaml \
  --set config.deployment.enabled=true \
  --set config.deployment.url="https://<your-langsmith-domain>" \
  --wait --timeout 10m

kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
```

---

## Common kubectl Commands

```bash
# All pods — status, restarts, age
kubectl get pods -n langsmith

# Watch pods in real time
kubectl get pods -n langsmith -w

# Describe a crashing/pending pod
kubectl describe pod <pod-name> -n langsmith

# Pod logs (live)
kubectl logs <pod-name> -n langsmith --tail=100 -f

# Previous crashed container logs
kubectl logs <pod-name> -n langsmith --previous --tail=50

# Stream backend logs
kubectl logs -n langsmith deploy/langsmith-backend --tail=100 -f

# Gateway / ingress
kubectl get gateway -n langsmith
kubectl get httproute -n langsmith
kubectl get svc -n envoy-gateway-system

# TLS
kubectl get certificate -n langsmith
kubectl get challenges -n langsmith
kubectl describe certificate <cert-name> -n langsmith
kubectl get clusterissuer

# Helm status
helm status langsmith -n langsmith
helm history langsmith -n langsmith
helm get values langsmith -n langsmith

# LangSmith Deployments
kubectl get lgp -n langsmith
kubectl get crd | grep langchain
```

---

## Common gcloud Commands

```bash
# Get cluster credentials
gcloud container clusters get-credentials <cluster-name> --region <region> --project <project-id>

# List clusters
gcloud container clusters list --project <project-id>

# Check cluster status
gcloud container clusters describe <cluster-name> --region <region> --format="value(status)"

# Check Cloud SQL
gcloud sql instances list --project <project-id>
gcloud sql instances describe <instance-name> --format="value(ipAddresses)"

# Check Memorystore Redis
gcloud redis instances list --region <region>
gcloud redis instances describe <instance-name> --region <region> --format="value(host)"

# Check GCS bucket
gsutil ls gs://<bucket-name>
gsutil iam get gs://<bucket-name>

# Check enabled APIs
gcloud services list --enabled --project <project-id>

# Check VPC peering
gcloud services vpc-peerings list --network <vpc-name> --project <project-id>
```

---

## Terraform Commands

```bash
# Initialize
terraform init

# Plan with var file
terraform plan -var-file=terraform.tfvars

# Apply
terraform apply -var-file=terraform.tfvars

# Target a specific module
terraform apply -var-file=terraform.tfvars -target=module.networking

# Show all outputs
terraform output

# Show a specific output
terraform output -raw cluster_name
terraform output -raw storage_bucket_name
terraform output -raw helm_install_command

# Show resource state
terraform state list
terraform state show module.gke_cluster

# Refresh state
terraform refresh -var-file=terraform.tfvars
```

---

## Teardown

```bash
# 1. Remove LangSmith Deployments (if Pass 3 was enabled)
kubectl delete lgp --all -n langsmith 2>/dev/null || true

# 2. Uninstall LangSmith
helm uninstall langsmith -n langsmith --wait

# 3. Delete namespace
kubectl delete namespace langsmith --timeout=60s

# 4. Set deletion protection = false in terraform.tfvars, then:
cd terraform/gcp/infra
terraform destroy
```
