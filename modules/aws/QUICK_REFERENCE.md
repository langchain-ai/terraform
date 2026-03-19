# LangSmith on AWS — Quick Reference

All commands run from `terraform/aws/`. Run `make help` to see all targets.

---

## First-Time Setup

```bash
cd terraform/aws

# 1. Generate terraform.tfvars (interactive wizard)
make quickstart

# 2. Set up secrets in SSM Parameter Store
source infra/scripts/setup-env.sh

# 3. Deploy infrastructure (~20-25 min)
make init
make plan
make apply

# 4. Generate Helm values from Terraform outputs
make init-values

# 5. Deploy LangSmith (~10 min)
make deploy
```

---

## Day-2 Operations

```bash
# Check deployment state and get next-step guidance
make status

# Re-deploy after changing Helm values or upgrading
make deploy

# Re-generate Helm values after Terraform changes
make init-values

# Re-sync ESO secrets without redeploying
make apply-eso

# Manage SSM secrets interactively
make ssm

# Update kubeconfig for the EKS cluster
make kubeconfig
```

---

## Enable Optional Addons

Copy `.example` files before deploying:

```bash
# Deployments feature (required for Agent Builder)
cp helm/values/langsmith-values-agent-deploys.yaml.example \
   helm/values/langsmith-values-agent-deploys.yaml

# Agent Builder (requires agent-deploys)
cp helm/values/langsmith-values-agent-builder.yaml.example \
   helm/values/langsmith-values-agent-builder.yaml

# ClickHouse Insights
cp helm/values/langsmith-values-insights.yaml.example \
   helm/values/langsmith-values-insights.yaml

# Then redeploy
make deploy
```

**Sizing**: HA sizing is enabled by default. For dev/test/POC:

```bash
rm helm/values/langsmith-values-ha.yaml
cp helm/values/langsmith-values-dev.yaml.example \
   helm/values/langsmith-values-dev.yaml
```

---

## Common kubectl Commands

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

# ESO secret sync status
kubectl get externalsecret langsmith-config -n langsmith

# TLS
kubectl get certificate -n langsmith
kubectl get challenges -n langsmith
kubectl describe certificate <cert-name> -n langsmith

# Helm
helm status langsmith -n langsmith
helm history langsmith -n langsmith
helm get values langsmith -n langsmith

# IRSA — check per-component annotations
kubectl get sa -n langsmith -o yaml | grep eks.amazonaws.com

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
cd terraform/aws/infra

terraform init
terraform plan
terraform apply
terraform apply -target=module.eks
terraform output
terraform output -raw cluster_name
terraform output -raw alb_dns_name
terraform output -raw langsmith_irsa_role_arn
terraform output -raw bucket_name
terraform state list
```

---

## Teardown

```bash
cd terraform/aws

# Option A: script-driven deploy
make uninstall

# Option B: Terraform-managed deploy
make destroy-app

# Then destroy infrastructure:
# 1. Set postgres_deletion_protection = false in infra/terraform.tfvars
# 2. Apply the change, then destroy
cd infra
terraform apply
terraform destroy
```
