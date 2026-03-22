# LangSmith on GCP — Quick Reference

---

## First-Time Setup

```bash
cd terraform/gcp

# Interactive wizard — generates terraform.tfvars from guided prompts
make quickstart

# Set up secrets in Secret Manager (auto-generates passwords + Fernet keys)
# Must be sourced so it can export TF_VAR_* into your shell
source infra/scripts/setup-env.sh

# Verify secrets are stored correctly
make secrets        # → infra/scripts/manage-secrets.sh validate

# Deploy infrastructure
make init
make plan
make apply

# Generate Helm values from Terraform outputs
make init-values    # → helm/scripts/init-values.sh

# Deploy LangSmith
make deploy         # → helm/scripts/deploy.sh
```

---

## Day-2 Operations

```bash
# Check deployment state and get next-step guidance
make status              # full check
make status-quick        # skip Secret Manager and K8s queries

# Re-deploy after changing Helm values or upgrading chart version
make deploy

# Re-generate Helm values after Terraform changes
make init-values

# Manage Secret Manager secrets interactively
make secrets             # list/get/set/validate/delete

# Update kubeconfig for the GKE cluster
make kubeconfig
```

---

## Enable Optional Addons

Set the feature flags in `terraform.tfvars`, then `make init-values && make deploy`. `init-values.sh` copies the matching example file into `helm/values/` automatically.

```hcl
# terraform.tfvars
enable_deployments   = true
enable_agent_builder = true   # requires enable_deployments = true
enable_insights      = true
enable_polly         = true   # requires enable_deployments = true + Polly license entitlement

# Usage telemetry (optional)
enable_usage_telemetry = true
```

To add an addon after initial install without re-running `init-values.sh`, copy manually from `examples/`:

```bash
cp helm/values/examples/langsmith-values-agent-deploys.yaml helm/values/
cp helm/values/examples/langsmith-values-agent-builder.yaml helm/values/
cp helm/values/examples/langsmith-values-insights.yaml      helm/values/
cp helm/values/examples/langsmith-values-polly.yaml         helm/values/

make deploy
```

## Sizing Profiles

Set `sizing_profile` in `terraform.tfvars` before running `make init-values`:

```hcl
sizing_profile = "production"   # default | minimum | dev | production | production-large
```

| Profile | When to use |
|---|---|
| `default` | Chart defaults — quick tests, no overlay applied |
| `minimum` | Absolute floor — fits e2-standard-4; use for cost parking or CI smoke tests |
| `dev` | Single replica, minimal resources — dev/CI environments |
| `production` | Multi-replica with HPA — recommended for real workloads |
| `production-large` | High-memory / high-CPU — 50+ users or 1000+ traces/sec |

After changing `sizing_profile`, re-run `make init-values` to copy the sizing overlay, then `make deploy`.

> **Minimum profile + LGP?** Run `make patch-lgp` after deploy to right-size LangGraph Platform CRs. The operator overwrites Deployment patches, so the CRs must be targeted directly.

---

## Pass 1 — Terraform Infrastructure

```bash
# Authenticate
gcloud auth login
gcloud config set project <your-project-id>
gcloud auth application-default login

# Recommended workflow
cd terraform/gcp
make preflight
make init
make plan
make apply

# Configure
cd terraform/gcp/infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Direct Terraform (equivalent)
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# Get cluster credentials
make kubeconfig

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
# Recommended: use the scripted deployment
cd terraform/gcp
make init-values   # generates values-overrides.yaml from Terraform outputs
make deploy        # runs helm upgrade --install with the full values chain

# Check what was deployed
helm status langsmith -n langsmith
kubectl get pods -n langsmith

# Get Gateway IP for DNS
kubectl get gateway -n langsmith \
  -o jsonpath='{.items[0].status.addresses[0].value}'
```

---

## Pass 3 — LangSmith Deployments (Optional)

```bash
# Set in terraform.tfvars, then re-apply
enable_deployments   = true
enable_agent_builder = true   # if you have the Agent Builder entitlement

make apply
make deploy   # re-deploys with addon overlay files

# Verify KEDA and operator
kubectl get pods -n keda
kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
kubectl get lgp -n langsmith
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

# Gateway / HTTPRoute
kubectl get gateway -n langsmith
kubectl get httproute -n langsmith
kubectl get svc -n envoy-gateway-system

# TLS
kubectl get certificate -n langsmith
kubectl get challenges -n langsmith
kubectl describe certificate <cert-name> -n langsmith
kubectl get clusterissuer

# Workload Identity
kubectl get serviceaccount langsmith-ksa -n langsmith -o yaml | grep annotation -A5

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

# Check Workload Identity binding
gcloud iam service-accounts get-iam-policy <gsa-email> --project <project-id>

# Check enabled APIs
gcloud services list --enabled --project <project-id>

# Check VPC peering
gcloud services vpc-peerings list --network <vpc-name> --project <project-id>

# Check Secret Manager secrets
gcloud secrets list --project <project-id> --filter="name:langsmith"
gcloud secrets versions access latest --secret=<secret-id> --project <project-id>
```

---

## Terraform Commands

```bash
# Initialize
terraform init

# Plan
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
make uninstall    # or: helm/scripts/uninstall.sh

# 3. Set deletion protection = false in terraform.tfvars, then:
make destroy
```

> Set `gke_deletion_protection = false` and `postgres_deletion_protection = false` before running `make destroy` in production.
