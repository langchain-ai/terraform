# LangSmith on AWS — Quick Reference

---

## Pass 1 — Terraform Infrastructure

```bash
# Configure AWS credentials
aws configure
aws sts get-caller-identity

# Configure and deploy
cd aws/infra
# Edit terraform.tfvars with your values

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# Get cluster credentials
aws eks update-kubeconfig \
  --region us-west-2 \
  --name $(terraform output -raw cluster_name)

# Verify
kubectl get nodes
kubectl get ns
kubectl get pods -n kube-system
kubectl get pods -n cert-manager
```

---

## Pass 2 — LangSmith Helm Deploy

```bash
cd aws/infra

# Get required outputs
terraform output -raw alb_dns_name
terraform output -raw langsmith_irsa_role_arn
terraform output -raw bucket_name

export API_KEY_SALT=$(openssl rand -base64 32)
export JWT_SECRET=$(openssl rand -base64 32)
export AGENT_BUILDER_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export INSIGHTS_ENCRYPTION_KEY=$(python3 -c \
  "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
export ADMIN_EMAIL="admin@example.com"
export ADMIN_PASSWORD="<strong-password>"

helm repo add langchain https://langchain-ai.github.io/helm
helm repo update

helm upgrade --install langsmith langchain/langsmith \
  --namespace langsmith --create-namespace \
  -f ../helm/values/langsmith-values.yaml.example \
  --set config.langsmithLicenseKey="<your-license-key>" \
  --set config.apiKeySalt="$API_KEY_SALT" \
  --set config.basicAuth.jwtSecret="$JWT_SECRET" \
  --set config.hostname="$(terraform output -raw alb_dns_name)" \
  --set config.basicAuth.initialOrgAdminEmail="$ADMIN_EMAIL" \
  --set config.basicAuth.initialOrgAdminPassword="$ADMIN_PASSWORD" \
  --set config.agentBuilder.encryptionKey="$AGENT_BUILDER_ENCRYPTION_KEY" \
  --set config.insights.encryptionKey="$INSIGHTS_ENCRYPTION_KEY" \
  --set config.blobStorage.provider="s3" \
  --set config.blobStorage.bucketName="$(terraform output -raw bucket_name)" \
  --set config.blobStorage.region="us-west-2" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$(terraform output -raw langsmith_irsa_role_arn)" \
  --wait --timeout 15m

# Verify
kubectl get pods -n langsmith
kubectl get ingress -n langsmith

# Configure DNS: create CNAME record pointing to ALB
terraform output -raw alb_dns_name
```

---

## Pass 3 — LangSmith Deployments (Optional)

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --wait

helm upgrade langsmith langchain/langsmith \
  --namespace langsmith \
  -f ../helm/values/langsmith-values.yaml.example \
  -f ../helm/values/langsmith-values-agent-deploys.yaml.example \
  --set config.deployment.enabled=true \
  --set config.deployment.url="https://<your-langsmith-domain>" \
  --wait --timeout 10m

kubectl get pods -n langsmith | grep -E "host-backend|listener|operator"
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

## Teardown

```bash
# 1. Remove LangSmith Deployments (if Pass 3 was enabled)
kubectl delete lgp --all -n langsmith 2>/dev/null || true

# 2. Uninstall LangSmith
helm uninstall langsmith -n langsmith --wait

# 3. Delete namespace
kubectl delete namespace langsmith --timeout=60s

# 4. Set postgres_deletion_protection = false in terraform.tfvars, then:
cd aws/infra
terraform apply -var-file=terraform.tfvars
terraform destroy
```
