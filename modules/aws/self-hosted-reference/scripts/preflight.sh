#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Deny pattern regex (broadened to catch all AWS denial patterns)
DENY_RE='AccessDenied|AccessDeniedException|UnauthorizedOperation|not authorized|NotAuthorized|is not authorized'

# Parse command line arguments
SKIP_RESOURCE_TESTS=false
NON_INTERACTIVE=false
CREATE_TEST_RESOURCES=false
ACM_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--skip_resource_tests|--skip_checks)
            SKIP_RESOURCE_TESTS=true
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        --create-test-resources)
            CREATE_TEST_RESOURCES=true
            shift
            ;;
        --domain)
            ACM_DOMAIN="$2"
            shift 2
            ;;
        *)
            printf "Unknown option: %s\n" "$1"
            printf "Usage: %s [-s|--skip_resource_tests] [-y|--yes] [--create-test-resources] [--domain <domain>]\n" "$0"
            exit 1
            ;;
    esac
done

# Check for CI environment
if [ "${CI:-false}" = "true" ]; then
    NON_INTERACTIVE=true
fi

# Function to print colored output
info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1"
}

success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"
}

warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1"
}

# Function to check for access denied patterns
check_denied() {
    local output="$1"
    if echo "$output" | grep -Eqi "$DENY_RE"; then
        return 0  # Access denied found
    fi
    return 1  # No access denied
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    error "AWS CLI is not installed. Please install it first."
    exit 1
fi

# Safety banner
printf "\n"
info "=== LangSmith AWS Preflight Check ==="
info "Default mode: READ-ONLY (no resource creation)"
info "Use --create-test-resources to test resource creation"
info "No modifications to existing resources will be made."
info "Temporary test resources may be created only with --create-test-resources."
printf "\n"

# Check AWS credentials
info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    error "Not logged into AWS. Please run 'aws configure' or set AWS credentials."
    exit 1
fi

# Get AWS account info
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ARN=$(aws sts get-caller-identity --query Arn --output text)

# Better region handling
REGION=$(aws configure get region 2>/dev/null || true)
REGION=${REGION:-${AWS_DEFAULT_REGION:-us-west-2}}

info "AWS Account ID: $ACCOUNT_ID"
info "User ARN: $USER_ARN"
info "Current region: $REGION"

# Confirm region (non-interactive mode skips this)
if [ "$NON_INTERACTIVE" = false ]; then
    printf "\n"
    read -p "Is the region '$REGION' correct? (y/n): " -n 1 -r
    printf "\n"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Please set the correct region using 'aws configure set region <region>' or export AWS_DEFAULT_REGION"
        exit 1
    fi
else
    info "Non-interactive mode: using region '$REGION'"
fi

# Check for sandbox account indicators (warning only, no prompt)
info "Checking for sandbox account restrictions..."
if [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    # Check if account has restrictions (common sandbox patterns)
    ALIASES=$(aws iam list-account-aliases --query 'AccountAliases' --output text 2>/dev/null || echo "")
    if echo "$ALIASES" | grep -qi "sandbox\|test\|dev"; then
        warning "Account alias suggests this might be a sandbox/test account: $ALIASES"
        warning "Please verify this account is not restricted by SCPs or other policies"
    fi
else
    warning "Account ID format is unusual. Please verify this is not a restricted account."
fi

# Function to cleanup resources on exit (with retry logic)
cleanup() {
    info "Cleaning up test resources..."
    
    # Cleanup in correct order: SG -> Subnet -> VPC -> IAM role
    # Retry logic for eventual consistency
    
    # Delete security group (with retry)
    if [ -n "${TEST_SG_ID:-}" ]; then
        for i in {1..3}; do
            if aws ec2 delete-security-group --group-id "$TEST_SG_ID" --region "$REGION" 2>/dev/null; then
                success "Security group deleted: $TEST_SG_ID"
                break
            fi
            if [ $i -lt 3 ]; then
                sleep 2
            fi
        done
    fi
    
    # Delete subnet (with retry)
    if [ -n "${TEST_SUBNET_ID:-}" ]; then
        for i in {1..3}; do
            if aws ec2 delete-subnet --subnet-id "$TEST_SUBNET_ID" --region "$REGION" 2>/dev/null; then
                success "Subnet deleted: $TEST_SUBNET_ID"
                break
            fi
            if [ $i -lt 3 ]; then
                sleep 2
            fi
        done
    fi
    
    # Delete VPC (with retry)
    if [ -n "${TEST_VPC_ID:-}" ]; then
        for i in {1..3}; do
            if aws ec2 delete-vpc --vpc-id "$TEST_VPC_ID" --region "$REGION" 2>/dev/null; then
                success "VPC deleted: $TEST_VPC_ID"
                break
            fi
            if [ $i -lt 3 ]; then
                sleep 2
            fi
        done
    fi
    
    # Delete IAM role (IAM is global, no --region, with retry)
    # NOTE: If you attach policies to the role, you must detach them before deleting
    if [ -n "${TEST_ROLE_NAME:-}" ]; then
        for i in {1..3}; do
            if aws iam delete-role --role-name "$TEST_ROLE_NAME" 2>/dev/null; then
                success "IAM role deleted: $TEST_ROLE_NAME"
                break
            fi
            if [ $i -lt 3 ]; then
                sleep 2
            fi
        done
    fi
}

# Read-only permission checks (always run)
info "Running read-only permission checks..."

# Test EC2 permissions (needed for EKS and ALB controller)
info "Testing EC2 permissions (VPC, subnets, availability zones)..."
EC2_VPC_OUTPUT=$(aws ec2 describe-vpcs --region "$REGION" --max-items 1 2>&1 || true)
EC2_SUBNET_OUTPUT=$(aws ec2 describe-subnets --region "$REGION" --max-items 1 2>&1 || true)
EC2_AZ_OUTPUT=$(aws ec2 describe-availability-zones --region "$REGION" 2>&1 || true)

if check_denied "$EC2_VPC_OUTPUT" || check_denied "$EC2_SUBNET_OUTPUT" || check_denied "$EC2_AZ_OUTPUT"; then
    error "Failed EC2 permission check. Check IAM permissions for ec2:DescribeVpcs, ec2:DescribeSubnets, ec2:DescribeAvailabilityZones"
    exit 1
fi
success "EC2 permissions verified"

# Test EKS permissions (fixed - single call with broader check)
info "Testing EKS permissions..."
EKS_OUTPUT=$(aws eks describe-cluster --name "preflight-nonexistent-$(date +%s)" --region "$REGION" 2>&1 || true)
if check_denied "$EKS_OUTPUT"; then
    error "Failed EKS permission check. Check IAM permissions for eks:*"
    exit 1
elif echo "$EKS_OUTPUT" | grep -q "ResourceNotFoundException"; then
    success "EKS permissions verified"
else
    # Try list-clusters as alternative check
    EKS_LIST_OUTPUT=$(aws eks list-clusters --region "$REGION" 2>&1 || true)
    if check_denied "$EKS_LIST_OUTPUT"; then
        error "Failed EKS permission check. Check IAM permissions for eks:*"
        exit 1
    elif [ -n "$EKS_LIST_OUTPUT" ]; then
        success "EKS permissions verified"
    else
        warning "EKS permission check inconclusive, but continuing..."
    fi
fi

# Add warning about EKS prerequisites
warning "Note: Passing EKS checks does not guarantee you can create EKS/nodegroups."
warning "Common failures occur at iam:PassRole, ec2:* permissions, and service quotas."

# Test IAM permissions (read-only check, needed for PassRole)
info "Testing IAM permissions..."
IAM_OUTPUT=$(aws iam list-roles --max-items 1 2>&1 || true)
if check_denied "$IAM_OUTPUT"; then
    error "Failed IAM permission check. Check IAM permissions for iam:ListRoles (needed for iam:PassRole)"
    exit 1
else
    success "IAM permissions verified"
fi

# Test RDS permissions
info "Testing RDS permissions..."
RDS_OUTPUT=$(aws rds describe-db-instances --region "$REGION" 2>&1 || true)
if check_denied "$RDS_OUTPUT"; then
    error "Failed RDS permission check. Check IAM permissions for rds:*"
    exit 1
else
    success "RDS permissions verified"
fi

# Test ElastiCache permissions
info "Testing ElastiCache permissions..."
CACHE_OUTPUT=$(aws elasticache describe-cache-clusters --region "$REGION" 2>&1 || true)
if check_denied "$CACHE_OUTPUT"; then
    error "Failed ElastiCache permission check. Check IAM permissions for elasticache:*"
    exit 1
else
    success "ElastiCache permissions verified"
fi

# Test ALB/ELB permissions
info "Testing Application Load Balancer permissions..."
ALB_OUTPUT=$(aws elbv2 describe-load-balancers --region "$REGION" 2>&1 || true)
if check_denied "$ALB_OUTPUT"; then
    error "Failed ALB permission check. Check IAM permissions for elasticloadbalancing:*"
    exit 1
else
    success "ALB permissions verified"
fi

# Test ACM permissions (for TLS certificates)
info "Testing ACM (Certificate Manager) permissions..."
ACM_OUTPUT=$(aws acm list-certificates --region "$REGION" 2>&1 || true)
if check_denied "$ACM_OUTPUT"; then
    error "Failed ACM permission check. Check IAM permissions for acm:*"
    exit 1
else
    success "ACM permissions verified"
    if [ -z "$ACM_DOMAIN" ]; then
        warning "ACM check passed (does not confirm a cert exists for your chosen domain)"
    else
        # Check if certificate exists for the domain
        info "Checking for ACM certificate matching domain: $ACM_DOMAIN"
        
        # Extract zone apex (e.g., "example.com" from "langsmith.example.com")
        # If domain contains a dot, extract everything after the first dot
        if echo "$ACM_DOMAIN" | grep -q '\.'; then
            ZONE_APEX=$(echo "$ACM_DOMAIN" | sed -E 's/^[^.]*\.(.+)$/\1/')
        else
            # Already an apex domain (unlikely but handle it)
            ZONE_APEX="$ACM_DOMAIN"
        fi
        
        # First try exact match
        CERT_ARN=$(aws acm list-certificates --region "$REGION" --query "CertificateSummaryList[?DomainName=='$ACM_DOMAIN'].CertificateArn" --output text 2>/dev/null || echo "")
        
        # If no exact match, try wildcard for zone apex (e.g., *.example.com)
        if [ -z "$CERT_ARN" ] && [ "$ZONE_APEX" != "$ACM_DOMAIN" ]; then
            WILDCARD_DOMAIN="*.$ZONE_APEX"
            CERT_ARN=$(aws acm list-certificates --region "$REGION" --query "CertificateSummaryList[?DomainName=='$WILDCARD_DOMAIN'].CertificateArn" --output text 2>/dev/null || echo "")
        fi
        
        # If still no match, check SANs by describing each cert (limited check)
        if [ -z "$CERT_ARN" ]; then
            ALL_CERTS=$(aws acm list-certificates --region "$REGION" --query "CertificateSummaryList[*].CertificateArn" --output text 2>/dev/null || echo "")
            for cert_arn in $ALL_CERTS; do
                CERT_DETAILS=$(aws acm describe-certificate --certificate-arn "$cert_arn" --region "$REGION" --query "Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames}" --output json 2>/dev/null || echo "{}")
                if echo "$CERT_DETAILS" | grep -q "\"$ACM_DOMAIN\"" || echo "$CERT_DETAILS" | grep -q "\"*.$ZONE_APEX\""; then
                    CERT_ARN="$cert_arn"
                    break
                fi
            done
        fi
        
        if [ -n "$CERT_ARN" ]; then
            success "Found ACM certificate for domain: $CERT_ARN"
        else
            warning "No ACM certificate found for domain '$ACM_DOMAIN' in region '$REGION'"
            warning "You may need to request a certificate before deploying"
        fi
    fi
fi

# Test Route53 permissions (for DNS/ingress) - Route53 is global, no --region
info "Testing Route53 permissions..."
R53_OUTPUT=$(aws route53 list-hosted-zones 2>&1 || true)
if check_denied "$R53_OUTPUT"; then
    error "Failed Route53 permission check. Check IAM permissions for route53:*"
    exit 1
else
    success "Route53 permissions verified"
    # Check if hosted zones exist
    ZONE_COUNT=$(aws route53 list-hosted-zones --query "HostedZones | length(@)" --output text 2>/dev/null || echo "0")
    if [ "$ZONE_COUNT" = "0" ] || [ -z "$ZONE_COUNT" ]; then
        warning "No Route53 hosted zones found."
        warning "If you intend to use Route53 for ingress, create/identify the hosted zone first."
    else
        info "Found $ZONE_COUNT Route53 hosted zone(s)"
        
        # If domain provided, check for matching hosted zone
        if [ -n "$ACM_DOMAIN" ]; then
            # Extract zone apex (same logic as ACM check)
            if echo "$ACM_DOMAIN" | grep -q '\.'; then
                ZONE_APEX=$(echo "$ACM_DOMAIN" | sed -E 's/^[^.]*\.(.+)$/\1/')
            else
                ZONE_APEX="$ACM_DOMAIN"
            fi
            # Route53 zone names end with a dot
            ZONE_NAME="${ZONE_APEX}."
            MATCHING_ZONE=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='$ZONE_NAME'].Id" --output text 2>/dev/null || echo "")
            if [ -n "$MATCHING_ZONE" ]; then
                success "Found Route53 hosted zone for domain: $ZONE_NAME"
            else
                warning "No Route53 hosted zone found matching domain '$ACM_DOMAIN' (checked for zone: $ZONE_NAME)"
            fi
        fi
    fi
fi

# Test WAFv2 permissions (optional, for WAF support)
info "Testing WAFv2 permissions (optional)..."
WAF_OUTPUT=$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" 2>&1 || true)
if check_denied "$WAF_OUTPUT"; then
    warning "WAFv2 permission check failed (optional, but recommended for production)"
else
    WAF_COUNT=$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" --query "WebACLs | length(@)" --output text 2>/dev/null || echo "0")
    if [ "$WAF_COUNT" = "0" ] || [ -z "$WAF_COUNT" ]; then
        success "WAFv2 accessible (no web ACLs found)"
    else
        success "WAFv2 permissions verified (found $WAF_COUNT web ACL(s))"
    fi
fi

# Resource creation tests (only if --create-test-resources is set or skip is not set)
if [ "$SKIP_RESOURCE_TESTS" = true ]; then
    info "Skipping resource creation tests (--skip_resource_tests flag provided)"
    success "Preflight checks complete (resource tests skipped)"
    exit 0
fi

if [ "$CREATE_TEST_RESOURCES" = false ]; then
    info "Skipping resource creation tests (use --create-test-resources to enable)"
    info "Read-only checks passed. You can proceed with deployment."
    success "Preflight checks complete!"
    exit 0
fi

# Set trap only when we're actually creating resources
trap cleanup EXIT

# Confirmation prompt before creating resources (unless --yes is set)
if [ "$NON_INTERACTIVE" = false ]; then
    printf "\n"
    warning "This will create temporary test resources:"
    warning "  - VPC, Subnet, Security Group (isolated, will be deleted)"
    warning "  - IAM Role (will be deleted)"
    warning "  - No modifications to existing resources"
    printf "\n"
    read -p "Continue with resource creation tests? (y/n): " -n 1 -r
    printf "\n"
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Resource creation tests cancelled by user"
        exit 0
    fi
fi

# Resource creation tests (only run if --create-test-resources is set)
info "Running resource creation tests (--create-test-resources mode)..."

# Generate a safer CIDR block (10.254.x.x range, avoid 0, less likely to conflict)
# Retry logic for VPC creation in case of CIDR conflicts
VPC_CREATED=false
for attempt in {1..3}; do
    RANDOM_SUFFIX=$(( (RANDOM % 250) + 1 ))  # Range 1-250, avoids 0
    TEST_CIDR="10.254.${RANDOM_SUFFIX}.0/28"
    
    info "Attempting VPC creation with CIDR $TEST_CIDR (attempt $attempt/3)..."
    VPC_OUTPUT=$(aws ec2 create-vpc \
        --cidr-block "$TEST_CIDR" \
        --region "$REGION" \
        --query 'Vpc.VpcId' \
        --output text 2>&1) || {
        if echo "$VPC_OUTPUT" | grep -qi "InvalidVpc.Range\|overlap\|conflict"; then
            if [ $attempt -lt 3 ]; then
                warning "VPC creation failed (org policy or CIDR validation), trying different CIDR..."
                continue
            else
                error "Failed to create VPC after 3 attempts (org policy or CIDR validation). Check IAM permissions for ec2:CreateVpc"
                exit 1
            fi
        else
            error "Failed to create VPC. Check IAM permissions for ec2:CreateVpc"
            exit 1
        fi
    }
    
    TEST_VPC_ID="$VPC_OUTPUT"
    VPC_CREATED=true
    success "VPC created: $TEST_VPC_ID"
    break
done

if [ "$VPC_CREATED" = false ]; then
    error "Failed to create VPC after all retry attempts"
    exit 1
fi

# Test subnet creation (reuse VPC CIDR since it's a /28)
info "Testing subnet creation..."
AZ=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)
TEST_SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "$TEST_VPC_ID" \
    --cidr-block "$TEST_CIDR" \
    --availability-zone "$AZ" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null) || {
    error "Failed to create subnet. Check IAM permissions for ec2:CreateSubnet"
    exit 1
}
success "Subnet created: $TEST_SUBNET_ID"

# Test security group creation
info "Testing security group creation..."
TEST_SG_ID=$(aws ec2 create-security-group \
    --group-name "preflight-test-sg-$(date +%s)" \
    --description "Preflight test security group" \
    --vpc-id "$TEST_VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null) || {
    error "Failed to create security group. Check IAM permissions for ec2:CreateSecurityGroup"
    exit 1
}
success "Security group created: $TEST_SG_ID"

# Test IAM role creation (IAM is global, no --region)
info "Testing IAM role creation..."
TEST_ROLE_NAME="preflight-test-role-$(date +%s)"
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'
if aws iam create-role \
    --role-name "$TEST_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --output text > /dev/null 2>&1; then
    success "IAM role created: $TEST_ROLE_NAME"
else
    error "Failed to create IAM role. Check IAM permissions for iam:CreateRole"
    exit 1
fi

# Cleanup happens automatically via trap
info "All test resources will be cleaned up on exit..."

success "Preflight checks complete! All permissions verified."
info "You are ready to deploy LangSmith infrastructure."
