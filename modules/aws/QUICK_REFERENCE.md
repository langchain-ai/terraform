# LangSmith on AWS — Quick Reference

## Prerequisites

Install these tools before starting:

| Tool | Version | Install |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | `brew install terraform` |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | `brew install awscli` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | >= 1.28 | `brew install kubectl` |
| [Helm](https://helm.sh/docs/intro/install/) | >= 3.12 | `brew install helm` |

```bash
# Verify AWS credentials
aws configure
aws sts get-caller-identity
```

---

## Pass 1 — Infrastructure (Terraform)

```bash
cd aws/infra

# 1. Configure variables — pick a profile or start from the full example
cp terraform.tfvars.dev terraform.tfvars      # dev: public EKS, small instances, no deletion protection
# cp terraform.tfvars.prod terraform.tfvars   # prod: private EKS, recommended sizes, protection on
# cp terraform.tfvars.example terraform.tfvars  # full annotated reference — every option explained

# 2. Run preflight checks (validates tools, AWS creds, IAM permissions)
./scripts/preflight.sh

# 3. Set up secrets (stores in SSM Parameter Store, exports TF_VAR_*)
#    IMPORTANT: use `source` — not `./setup-env.sh`
source ./setup-env.sh

# 4. Deploy infrastructure
terraform init
terraform plan
terraform apply

# 5. Update kubeconfig after cluster is created
aws eks update-kubeconfig --region <region> --name <name_prefix>-<env>-eks
```

---

## Pass 1b — Custom Domain (optional)

If you set `langsmith_domain` in `terraform.tfvars`, Terraform auto-provisions a Route 53 zone and ACM certificate.

```bash
# After terraform apply, get the NS records to delegate at your registrar
terraform output dns_name_servers

# Once NS delegation propagates (~5-30 min), enable HTTPS:
# In terraform.tfvars, change: tls_certificate_source = "acm"
terraform apply
```

You can skip this step and access LangSmith via the ALB hostname directly.

---

## Pass 2 — Deploy LangSmith (Helm)

```bash
cd aws/helm

# 1. Generate environment values file from Terraform outputs
./scripts/init-overrides.sh

# 2. Deploy (includes preflight checks, ESO setup, and Helm install)
./scripts/deploy.sh
```

**First deploy**: The ALB hostname isn't known until the ingress is created.
`deploy.sh` handles this automatically — it detects the ALB hostname after the
first install and re-runs Helm with the hostname set.

### Optional addons

Enable addons by copying the example files, then re-run `./scripts/deploy.sh`:

```bash
# Agent Deployments (LangGraph Platform)
cp values/langsmith-values-agent-deploys.yaml.example values/langsmith-values-agent-deploys.yaml

# Agent Builder (requires agent-deploys)
cp values/langsmith-values-agent-builder.yaml.example values/langsmith-values-agent-builder.yaml

# Insights
cp values/langsmith-values-insights.yaml.example values/langsmith-values-insights.yaml
```

---

## Verify

```bash
kubectl get pods -n langsmith
kubectl get ingress -n langsmith
```

---

## Access LangSmith

**Port-forward** (works immediately, no ALB/DNS needed):
```bash
kubectl port-forward svc/langsmith-frontend -n langsmith 8080:80
# Open http://localhost:8080
```

**Via ALB** (once the ingress has an address):
```bash
# Get the ALB hostname
kubectl get ingress -n langsmith -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
# Open http://<alb-hostname> in your browser
```

Login with the admin email from `init-overrides.sh` and the admin password from `setup-env.sh`.

---

## Common Operations

```bash
# Pod health
kubectl get pods -n langsmith
kubectl get pods -n langsmith -w
kubectl describe pod <pod-name> -n langsmith
kubectl logs <pod-name> -n langsmith --tail=100 -f
kubectl logs <pod-name> -n langsmith --previous --tail=50

# ALB / Ingress
kubectl get ingress -n langsmith
kubectl describe ingress -n langsmith

# TLS
kubectl get certificate -n langsmith
kubectl get challenges -n langsmith
kubectl describe certificate <cert-name> -n langsmith

# Helm
helm status langsmith -n langsmith
helm history langsmith -n langsmith
helm get values langsmith -n langsmith

# IRSA
kubectl get sa langsmith -n langsmith -o yaml | grep eks.amazonaws.com

# LangSmith Deployments
kubectl get lgp -n langsmith
kubectl get crd | grep langchain
kubectl get pods -n keda
```

---

## Common AWS CLI Commands

```bash
# EKS
aws eks list-clusters --region <region>
aws eks describe-cluster --name <cluster-name> --region <region>
aws eks update-kubeconfig --region <region> --name <cluster-name>

# RDS
aws rds describe-db-instances --query "DBInstances[?contains(DBInstanceIdentifier,'langsmith')]"

# ElastiCache
aws elasticache describe-cache-clusters --query "CacheClusters[?contains(CacheClusterId,'langsmith')]"

# S3
aws s3 ls s3://<bucket-name>
aws s3api get-bucket-location --bucket <bucket-name>

# ALB
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName,'langsmith')]"

# VPC endpoint
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.<region>.s3" \
  --query "VpcEndpoints[].State"

# SSM secrets
aws ssm get-parameters-by-path --path "/langsmith/<base-name>/" --with-decryption

# IAM role
aws iam get-role --role-name <irsa-role-name>
```

---

## Terraform Commands

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars -target=module.eks
terraform output
terraform output -raw cluster_name
terraform output -raw alb_dns_name
terraform output -raw langsmith_irsa_role_arn
terraform output -raw bucket_name
terraform state list
terraform refresh -var-file=terraform.tfvars
```

---

## Troubleshooting

### LangSmith UI unreachable after re-running init-overrides.sh

**Symptom:** `kubectl get ingress -n langsmith` shows a hostname under `HOSTS` (not `*`), and the ALB returns 404 or no response.

**Cause:** `config.hostname` was populated (e.g. from the pre-provisioned ALB DNS name), which locks the ALB listener rule to that specific `Host` header. Requests arriving with a different `Host` header are dropped.

**Fix:** Clear the hostname and redeploy:
```bash
# In langsmith-values-{env}.yaml, set:
#   config.hostname: ""
./helm/scripts/deploy.sh
```

---

### Switching to the pre-provisioned ALB on an existing cluster (Option A cut-over)

**Symptom:** After provisioning the `alb` module and re-running `init-overrides.sh`, the ingress `ADDRESS` still shows the old reactive ALB. The `load-balancer-arn` annotation is present but ignored.

**Cause:** The AWS Load Balancer Controller cannot reassign an existing ingress to a different ALB. The annotation is only respected on initial ingress creation.

**Fix:** Delete the ingress so the controller recreates it against the pre-provisioned ALB:
```bash
kubectl delete ingress langsmith-ingress -n langsmith
./helm/scripts/deploy.sh
```

---

### platform-backend / ingest-queue crash on startup (S3 301 MovedPermanently)

**Symptom:** Pods in `CrashLoopBackOff`; logs show `panic: blob-storage health-check failed: ... StatusCode: 301 ... api error MovedPermanently`.

**Cause:** `config.blobStorage.apiURL` defaults to `https://s3.us-west-2.amazonaws.com` in the Helm chart. If your bucket is in a different region, the SDK gets a 301 redirect it cannot follow.

**Fix:** Ensure `init-overrides.sh` has been run to generate `langsmith-values-{env}.yaml`, which sets `apiURL` to the correct regional endpoint. Verify:
```bash
grep apiURL aws/helm/values/langsmith-values-*.yaml
# should show: apiURL: "https://s3.<your-region>.amazonaws.com"
```

---

### IRSA not applied — pods lack S3 access

**Symptom:** S3 operations fail with permission errors despite an IRSA role existing.

**Cause:** The LangSmith Helm chart does not support a top-level `serviceAccount` block. IRSA annotations must be set per component.

**Fix:** Ensure `langsmith-values-{env}.yaml` (generated by `init-overrides.sh`) contains per-component annotations:
```yaml
platformBackend:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "<role-arn>"
backend:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "<role-arn>"
# ... ingestQueue, queue
```

---

## Teardown

See [TEARDOWN.md](TEARDOWN.md) for the full step-by-step teardown guide.
