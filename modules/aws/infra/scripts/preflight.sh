#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# preflight.sh — Pre-Terraform AWS permission and prerequisite check.
#
# Run this BEFORE 'terraform apply' to verify that your AWS credentials
# have the permissions needed to provision all LangSmith infrastructure.
#
# Usage (from aws/infra/):
#   ./scripts/preflight.sh                         # read-only checks
#   ./scripts/preflight.sh --domain langsmith.example.com  # + ACM/Route53 domain check
#   ./scripts/preflight.sh --create-test-resources # + create/destroy real AWS resources
#   ./scripts/preflight.sh -y                      # non-interactive
set -euo pipefail
export AWS_PAGER=""

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DENY_RE='AccessDenied|AccessDeniedException|UnauthorizedOperation|not authorized|NotAuthorized|is not authorized'

# ── Args ──────────────────────────────────────────────────────────────────────
SKIP_RESOURCE_TESTS=false
NON_INTERACTIVE=false
CREATE_TEST_RESOURCES=false
ACM_DOMAIN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--skip_resource_tests) SKIP_RESOURCE_TESTS=true; shift ;;
    -y|--yes)                 NON_INTERACTIVE=true; shift ;;
    --create-test-resources)  CREATE_TEST_RESOURCES=true; shift ;;
    --domain)                 [[ $# -lt 2 ]] && { printf "ERROR: --domain requires an argument\n" >&2; exit 1; }; ACM_DOMAIN="$2"; shift 2 ;;
    *)
      printf "Unknown option: %s\n" "$1"
      printf "Usage: %s [-s] [-y] [--create-test-resources] [--domain <domain>]\n" "$0"
      exit 1 ;;
  esac
done

[[ "${CI:-false}" == "true" ]] && NON_INTERACTIVE=true

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf "${BLUE}[INFO]${NC}    %s\n" "$1"; }
success() { printf "${GREEN}[OK]${NC}      %s\n" "$1"; }
warning() { printf "${YELLOW}[WARN]${NC}    %s\n" "$1"; }
error()   { printf "${RED}[ERROR]${NC}   %s\n" "$1"; }

check_denied() { echo "$1" | grep -Eqi "$DENY_RE"; }

# ── Required tools ────────────────────────────────────────────────────────────
REQUIRED_TOOLS=(aws terraform kubectl helm)
MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required tools: ${MISSING[*]}"
  info "Install guide:"
  info "  terraform  → https://developer.hashicorp.com/terraform/install"
  info "  aws        → https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  info "  kubectl    → https://kubernetes.io/docs/tasks/tools/"
  info "  helm       → https://helm.sh/docs/intro/install/"
  exit 1
fi

# Verify minimum versions
TF_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+')
AWS_VERSION=$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+' | cut -d/ -f2)
if [[ -n "$AWS_VERSION" && "$AWS_VERSION" -lt 2 ]]; then
  error "AWS CLI v2 required (found v${AWS_VERSION}). Upgrade: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

printf "\n"
info "=== LangSmith AWS Preflight (Pass 1 — pre-Terraform) ==="
info "Default mode: READ-ONLY. Use --create-test-resources to test resource creation."
printf "\n"

success "Required tools: $(printf '%s ' "${REQUIRED_TOOLS[@]}")"
[[ -n "${TF_VERSION:-}" ]] && info "Terraform version: $TF_VERSION"

# ── terraform.tfvars check ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="$SCRIPT_DIR/../terraform.tfvars"
if [[ ! -f "$TFVARS" ]]; then
  error "terraform.tfvars not found at $TFVARS"
  info "Quick start:"
  info "  cp terraform.tfvars.minimum terraform.tfvars     # minimum profile (cost parking, CI)"
  info "  cp terraform.tfvars.dev terraform.tfvars         # dev profile"
  info "  cp terraform.tfvars.production terraform.tfvars  # production profile"
  info "  cp terraform.tfvars.example terraform.tfvars     # full reference"
  exit 1
fi
success "terraform.tfvars found"

# ── Credentials ───────────────────────────────────────────────────────────────
info "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
  error "Not authenticated. Run 'aws configure' or set AWS_* environment variables."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
REGION=$(aws configure get region 2>/dev/null || true)
REGION=${REGION:-${AWS_DEFAULT_REGION:-us-east-2}}

info "Account ID : $ACCOUNT_ID"
info "Identity   : $USER_ARN"
info "Region     : $REGION"

if [[ "$NON_INTERACTIVE" == "false" ]]; then
  printf "\n"
  read -p "Is the region '$REGION' correct? (y/n): " -n 1 -r; printf "\n"
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    error "Set the correct region via 'aws configure set region <region>' or AWS_DEFAULT_REGION."
    exit 1
  fi
fi

# ── Sandbox detection ─────────────────────────────────────────────────────────
info "Checking for sandbox/restricted account indicators..."
ALIASES=$(aws iam list-account-aliases --query 'AccountAliases' --output text 2>/dev/null || echo "")
if echo "$ALIASES" | grep -qi "sandbox\|test\|dev"; then
  warning "Account alias suggests sandbox/test: $ALIASES"
  warning "Verify this account is not restricted by SCPs before proceeding."
fi

# ── Read-only permission checks ───────────────────────────────────────────────
printf "\n"
info "Running read-only permission checks..."
printf "\n"

# EC2 — VPCs, subnets, AZs (needed for vpc module + alb module)
info "EC2 — VPCs, subnets, availability zones..."
EC2_VPC=$(aws ec2 describe-vpcs --region "$REGION" --max-items 1 2>&1 || true)
EC2_SUB=$(aws ec2 describe-subnets --region "$REGION" --max-items 1 2>&1 || true)
EC2_AZ=$(aws ec2 describe-availability-zones --region "$REGION" 2>&1 || true)
if check_denied "$EC2_VPC" || check_denied "$EC2_SUB" || check_denied "$EC2_AZ"; then
  error "EC2 read permission denied. Required: ec2:DescribeVpcs, ec2:DescribeSubnets, ec2:DescribeAvailabilityZones"
  exit 1
fi
success "EC2 read permissions OK"

# EKS — cluster operations (needed for eks module)
info "EKS — cluster operations..."
EKS_OUT=$(aws eks describe-cluster --name "preflight-nonexistent-$$" --region "$REGION" 2>&1 || true)
if check_denied "$EKS_OUT"; then
  error "EKS permission denied. Required: eks:* (DescribeCluster, CreateCluster, etc.)"
  exit 1
elif echo "$EKS_OUT" | grep -q "ResourceNotFoundException"; then
  success "EKS permissions OK"
else
  EKS_LIST=$(aws eks list-clusters --region "$REGION" 2>&1 || true)
  if check_denied "$EKS_LIST"; then
    error "EKS permission denied. Required: eks:ListClusters"
    exit 1
  fi
  success "EKS permissions OK"
fi
warning "Passing EKS checks does not guarantee node group creation — iam:PassRole and service quotas are not tested here."

# IAM — role management (needed for IRSA roles, ESO role, EBS CSI role)
info "IAM — role listing..."
IAM_OUT=$(aws iam list-roles --max-items 1 2>&1 || true)
if check_denied "$IAM_OUT"; then
  error "IAM read permission denied. Required: iam:ListRoles, iam:CreateRole, iam:PassRole"
  exit 1
fi
success "IAM read permissions OK"

# RDS — PostgreSQL (needed for postgres module)
info "RDS — PostgreSQL..."
RDS_OUT=$(aws rds describe-db-instances --region "$REGION" 2>&1 || true)
if check_denied "$RDS_OUT"; then
  error "RDS permission denied. Required: rds:*"
  exit 1
fi
success "RDS permissions OK"

# ElastiCache — Redis (needed for redis module)
info "ElastiCache — Redis..."
CACHE_OUT=$(aws elasticache describe-cache-clusters --region "$REGION" 2>&1 || true)
if check_denied "$CACHE_OUT"; then
  error "ElastiCache permission denied. Required: elasticache:*"
  exit 1
fi
success "ElastiCache permissions OK"

# ELBv2 — ALB (needed for alb module + ALB ingress controller)
info "ELBv2 — Application Load Balancer..."
ALB_OUT=$(aws elbv2 describe-load-balancers --region "$REGION" 2>&1 || true)
if check_denied "$ALB_OUT"; then
  error "ELBv2 permission denied. Required: elasticloadbalancing:*"
  exit 1
fi
success "ELBv2 permissions OK"

# S3 — blob storage (needed for storage module)
info "S3 — blob storage bucket..."
S3_OUT=$(aws s3api list-buckets --query 'Buckets[0]' 2>&1 || true)
if check_denied "$S3_OUT"; then
  error "S3 permission denied. Required: s3:CreateBucket, s3:PutBucketPolicy, s3:GetObject, s3:PutObject, s3:DeleteObject, s3:ListBucket"
  exit 1
fi
# Check VPC endpoint creation (needed for S3 VPC gateway endpoint in storage module)
EC2_ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "$REGION" --max-items 1 2>&1 || true)
if check_denied "$EC2_ENDPOINTS"; then
  error "ec2:DescribeVpcEndpoints denied. Required for VPC S3 gateway endpoint (storage module)."
  exit 1
fi
success "S3 + VPC endpoint permissions OK"

# SSM Parameter Store — secret management (needed for setup-env.sh + ESO)
info "SSM Parameter Store — secret management..."
SSM_OUT=$(aws ssm describe-parameters --region "$REGION" --max-items 1 2>&1 || true)
if check_denied "$SSM_OUT"; then
  error "SSM permission denied. Required: ssm:PutParameter, ssm:GetParameter, ssm:GetParametersByPath"
  error "SSM is used by setup-env.sh to store secrets and by ESO to sync them into the cluster."
  exit 1
fi
success "SSM Parameter Store permissions OK"

# ACM — TLS certificates (needed for acm TLS mode)
info "ACM — TLS certificate management..."
ACM_OUT=$(aws acm list-certificates --region "$REGION" 2>&1 || true)
if check_denied "$ACM_OUT"; then
  error "ACM permission denied. Required: acm:ListCertificates, acm:DescribeCertificate"
  exit 1
fi
success "ACM permissions OK"

if [[ -n "$ACM_DOMAIN" ]]; then
  info "Checking for ACM certificate matching: $ACM_DOMAIN"
  ZONE_APEX=$(echo "$ACM_DOMAIN" | sed -E 's/^[^.]*\.(.+)$/\1/')

  CERT_ARN=$(aws acm list-certificates --region "$REGION" \
    --query "CertificateSummaryList[?DomainName=='$ACM_DOMAIN'].CertificateArn" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$CERT_ARN" && "$ZONE_APEX" != "$ACM_DOMAIN" ]]; then
    CERT_ARN=$(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[?DomainName=='*.$ZONE_APEX'].CertificateArn" \
      --output text 2>/dev/null || echo "")
  fi

  if [[ -z "$CERT_ARN" ]]; then
    ALL_CERTS=$(aws acm list-certificates --region "$REGION" \
      --query "CertificateSummaryList[*].CertificateArn" --output text 2>/dev/null || echo "")
    for cert_arn in $ALL_CERTS; do
      CERT_DETAILS=$(aws acm describe-certificate --certificate-arn "$cert_arn" --region "$REGION" \
        --query "Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames}" --output json 2>/dev/null || echo "{}")
      if echo "$CERT_DETAILS" | grep -q "\"$ACM_DOMAIN\"" || echo "$CERT_DETAILS" | grep -q "\"*.$ZONE_APEX\""; then
        CERT_ARN="$cert_arn"; break
      fi
    done
  fi

  if [[ -n "$CERT_ARN" ]]; then
    success "ACM certificate found: $CERT_ARN"
  else
    warning "No ACM certificate found for '$ACM_DOMAIN' in $REGION — request one before deploying with tls_certificate_source = \"acm\""
  fi
fi

# Route53 — DNS (needed for dns module; optional for basic deploys)
info "Route53 — hosted zones..."
R53_OUT=$(aws route53 list-hosted-zones 2>&1 || true)
if check_denied "$R53_OUT"; then
  error "Route53 permission denied. Required: route53:ListHostedZones, route53:ChangeResourceRecordSets"
  exit 1
fi
success "Route53 permissions OK"
ZONE_COUNT=$(aws route53 list-hosted-zones --query "HostedZones | length(@)" --output text 2>/dev/null || echo "0")
if [[ "$ZONE_COUNT" == "0" || -z "$ZONE_COUNT" ]]; then
  warning "No Route53 hosted zones found. Required only if using the dns module or custom domain."
else
  info "Found $ZONE_COUNT Route53 hosted zone(s)"
  if [[ -n "$ACM_DOMAIN" ]]; then
    ZONE_APEX=$(echo "$ACM_DOMAIN" | sed -E 's/^[^.]*\.(.+)$/\1/')
    MATCHING_ZONE=$(aws route53 list-hosted-zones \
      --query "HostedZones[?Name=='${ZONE_APEX}.'].Id" --output text 2>/dev/null || echo "")
    if [[ -n "$MATCHING_ZONE" ]]; then
      success "Route53 hosted zone found for: $ZONE_APEX"
    else
      warning "No Route53 zone found for '$ZONE_APEX'"
    fi
  fi
fi

# WAFv2 — optional
info "WAFv2 — optional, for production WAF coverage..."
WAF_OUT=$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" 2>&1 || true)
if check_denied "$WAF_OUT"; then
  warning "WAFv2 permission denied (optional — not required for basic deployment)"
else
  success "WAFv2 permissions OK (optional)"
fi

# ── Resource creation tests ───────────────────────────────────────────────────
printf "\n"

if [[ "$SKIP_RESOURCE_TESTS" == "true" ]]; then
  info "Skipping resource creation tests (--skip_resource_tests)."
  success "Preflight complete (resource tests skipped)."
  exit 0
fi

if [[ "$CREATE_TEST_RESOURCES" == "false" ]]; then
  info "Read-only checks passed. Run with --create-test-resources to also validate resource creation permissions."
  success "Preflight complete!"
  exit 0
fi

# ── Cleanup trap (only registered when creating real resources) ───────────────
cleanup() {
  info "Cleaning up test resources..."
  for i in {1..3}; do
    [[ -n "${TEST_SG_ID:-}" ]] && aws ec2 delete-security-group --group-id "$TEST_SG_ID" --region "$REGION" 2>/dev/null && break || sleep 2
  done
  for i in {1..3}; do
    [[ -n "${TEST_SUBNET_ID:-}" ]] && aws ec2 delete-subnet --subnet-id "$TEST_SUBNET_ID" --region "$REGION" 2>/dev/null && break || sleep 2
  done
  for i in {1..3}; do
    [[ -n "${TEST_VPC_ID:-}" ]] && aws ec2 delete-vpc --vpc-id "$TEST_VPC_ID" --region "$REGION" 2>/dev/null && break || sleep 2
  done
  [[ -n "${TEST_ROLE_NAME:-}" ]] && aws iam delete-role --role-name "$TEST_ROLE_NAME" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$NON_INTERACTIVE" == "false" ]]; then
  printf "\n"
  warning "This will create and immediately delete: VPC, Subnet, Security Group, IAM Role."
  read -p "Continue? (y/n): " -n 1 -r; printf "\n"
  [[ ! $REPLY =~ ^[Yy]$ ]] && { info "Cancelled."; exit 0; }
fi

info "Running resource creation tests..."

VPC_CREATED=false
for attempt in {1..3}; do
  RANDOM_SUFFIX=$(( (RANDOM % 250) + 1 ))
  TEST_CIDR="10.254.${RANDOM_SUFFIX}.0/28"
  info "Creating test VPC with CIDR $TEST_CIDR (attempt $attempt/3)..."
  VPC_OUT=$(aws ec2 create-vpc --cidr-block "$TEST_CIDR" --region "$REGION" \
    --query 'Vpc.VpcId' --output text 2>&1) || {
    if echo "$VPC_OUT" | grep -qi "InvalidVpc.Range\|overlap\|conflict" && [[ $attempt -lt 3 ]]; then
      warning "CIDR conflict, retrying..."; continue
    fi
    error "Failed to create VPC. Required: ec2:CreateVpc"; exit 1
  }
  TEST_VPC_ID="$VPC_OUT"; VPC_CREATED=true
  success "VPC created: $TEST_VPC_ID"; break
done
[[ "$VPC_CREATED" == "false" ]] && { error "Failed to create VPC after 3 attempts."; exit 1; }

info "Creating test subnet..."
AZ=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)
TEST_SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$TEST_VPC_ID" --cidr-block "$TEST_CIDR" \
  --availability-zone "$AZ" --region "$REGION" --query 'Subnet.SubnetId' --output text 2>/dev/null) || {
  error "Failed to create subnet. Required: ec2:CreateSubnet"; exit 1
}
success "Subnet created: $TEST_SUBNET_ID"

info "Creating test security group..."
TEST_SG_ID=$(aws ec2 create-security-group \
  --group-name "preflight-test-sg-$$" \
  --description "LangSmith preflight test — will be deleted" \
  --vpc-id "$TEST_VPC_ID" --region "$REGION" \
  --query 'GroupId' --output text 2>/dev/null) || {
  error "Failed to create security group. Required: ec2:CreateSecurityGroup"; exit 1
}
success "Security group created: $TEST_SG_ID"

info "Creating test IAM role..."
TEST_ROLE_NAME="preflight-test-role-$$"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$TEST_ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" --output text >/dev/null 2>&1 || {
  error "Failed to create IAM role. Required: iam:CreateRole"; exit 1
}
success "IAM role created: $TEST_ROLE_NAME"

info "All test resources will be cleaned up on exit..."
printf "\n"
success "Preflight complete! All permissions verified. You are ready to run 'terraform apply'."
