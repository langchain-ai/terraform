#!/usr/bin/env bash
# quickstart.sh — Interactive setup wizard for LangSmith on AWS
#
# Generates infra/terraform.tfvars from a guided questionnaire.
# Run from the aws/ directory:
#
#   ./infra/scripts/quickstart.sh
#
# Also available as: make quickstart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
OUTPUT="$INFRA_DIR/terraform.tfvars"

# ── Colors (extend _common.sh with raw vars for printf in heredocs) ──────────
BOLD='\033[1m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────

_ask() {
  local prompt="$1" default="${2:-}"
  if [[ -n "$default" ]]; then
    printf "  %s ${DIM}[%s]${RESET}: " "$prompt" "$default"
  else
    printf "  %s: " "$prompt"
  fi
  read -r _REPLY
  _REPLY="${_REPLY:-$default}"
}

_ask_yn() {
  local prompt="$1" default="${2:-y}"
  local hint="Y/n"
  [[ "$default" == "n" ]] && hint="y/N"
  printf "  %s ${DIM}[%s]${RESET}: " "$prompt" "$hint"
  read -r _REPLY
  _REPLY="${_REPLY:-$default}"
  [[ "$_REPLY" =~ ^[Yy] ]]
}

_ask_choice() {
  local prompt="$1"
  shift
  local options=("$@")
  echo ""
  printf "  ${BOLD}%s${RESET}\n" "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    printf "    %d) %s\n" "$i" "$opt"
    ((i++))
  done
  printf "  Choice: "
  read -r _CHOICE
  if ! [[ "$_CHOICE" =~ ^[0-9]+$ ]] || (( _CHOICE < 1 || _CHOICE > ${#options[@]} )); then
    _red "Invalid selection."; echo ""
    exit 1
  fi
}

_section() {
  echo ""
  printf "${BOLD}── %s ──${RESET}\n" "$1"
}

# ── Guard ──────────────────────────────────────────────────────────────────

if [[ -f "$OUTPUT" ]]; then
  echo ""
  _yellow "WARNING"; printf ": %s already exists.\n" "$OUTPUT"
  if ! _ask_yn "Overwrite it?" "n"; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Banner ─────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}  LangSmith on AWS — Quickstart Setup${RESET}\n"
printf "${DIM}  Generates terraform.tfvars for your deployment.${RESET}\n"

# ═══════════════════════════════════════════════════════════════════════════
# 1. Profile
# ═══════════════════════════════════════════════════════════════════════════

_section "1. Deployment Profile"

_ask_choice "What kind of deployment is this?" \
  "Dev / POC  — minimal resources, in-cluster services OK" \
  "Production — HA resources, external managed services"

PROFILE="dev"
[[ "$_CHOICE" == "2" ]] && PROFILE="prod"

echo ""
printf "  Profile: $(_green "$PROFILE")\n"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Identity
# ═══════════════════════════════════════════════════════════════════════════

_section "2. Naming & Region"

_ask "Company/team prefix (max 11 chars, lowercase)" "myco"
NAME_PREFIX="$_REPLY"

if [[ "$PROFILE" == "prod" ]]; then
  _ask "Environment" "prod"
else
  _ask "Environment (dev, staging, test, uat)" "dev"
fi
ENVIRONMENT="$_REPLY"

_ask "AWS region" "us-west-2"
REGION="$_REPLY"

_ask "Owner (team or person, for tagging)" "platform-team"
OWNER="$_REPLY"

_ask "Cost center (for billing, leave blank to skip)" ""
COST_CENTER="$_REPLY"

echo ""
printf "  Resources will be named: $(_cyan "${NAME_PREFIX}-${ENVIRONMENT}")-{resource}\n"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Networking
# ═══════════════════════════════════════════════════════════════════════════

_section "3. Networking"

CREATE_VPC="true"
VPC_ID=""
VPC_CIDR=""
PRIVATE_SUBNETS=""
PUBLIC_SUBNETS=""

if _ask_yn "Create a new VPC?" "y"; then
  CREATE_VPC="true"
else
  CREATE_VPC="false"
  echo ""
  printf "  ${DIM}Bring Your Own VPC — provide existing resource IDs${RESET}\n"

  _ask "VPC ID" ""
  VPC_ID="$_REPLY"

  _ask "VPC CIDR block (e.g. 10.0.0.0/16)" ""
  VPC_CIDR="$_REPLY"

  _ask "Private subnet IDs (comma-separated)" ""
  PRIVATE_SUBNETS="$_REPLY"

  _ask "Public subnet IDs (comma-separated)" ""
  PUBLIC_SUBNETS="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. EKS
# ═══════════════════════════════════════════════════════════════════════════

_section "4. EKS Cluster"

_ask "EKS Kubernetes version" "1.31"
EKS_VERSION="$_REPLY"

EKS_PUBLIC="true"
EKS_PUBLIC_CIDRS=""
CREATE_BASTION="false"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  _ask_choice "EKS API endpoint access:" \
    "Public  — accessible from the internet (restrict with CIDRs)" \
    "Private — accessible only from within the VPC (bastion recommended)"

  if [[ "$_CHOICE" == "2" ]]; then
    EKS_PUBLIC="false"
    CREATE_BASTION="true"
    printf "\n  $(_dim "Bastion will be created for private cluster access via SSM.")\n"
  else
    echo ""
    _ask "Restrict EKS API to specific CIDRs? (comma-separated, blank = 0.0.0.0/0)" ""
    EKS_PUBLIC_CIDRS="$_REPLY"
  fi
else
  printf "  $(_dim "Dev profile: EKS API endpoint will be public.")\n"
fi

# Node group sizing
if [[ "$PROFILE" == "prod" ]]; then
  NODE_INSTANCE="m5.4xlarge"
  NODE_MIN=3
  NODE_MAX=10
else
  NODE_INSTANCE="m5.2xlarge"
  NODE_MIN=2
  NODE_MAX=5
fi

echo ""
_ask "Node group instance type" "$NODE_INSTANCE"
NODE_INSTANCE="$_REPLY"
_ask "Node group min size" "$NODE_MIN"
NODE_MIN="$_REPLY"
_ask "Node group max size" "$NODE_MAX"
NODE_MAX="$_REPLY"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Services
# ═══════════════════════════════════════════════════════════════════════════

_section "5. Backend Services"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  $(_dim "Production: external PostgreSQL (RDS) and Redis (ElastiCache) recommended.")\n"
  PG_SOURCE="external"
  REDIS_SOURCE="external"

  if ! _ask_yn "Use external PostgreSQL (RDS)?" "y"; then
    PG_SOURCE="in-cluster"
  fi
  if ! _ask_yn "Use external Redis (ElastiCache)?" "y"; then
    REDIS_SOURCE="in-cluster"
  fi
else
  _ask_choice "Backend services:" \
    "All external — RDS + ElastiCache (recommended even for dev)" \
    "All in-cluster — everything runs as pods (simplest, least durable)"

  if [[ "$_CHOICE" == "1" ]]; then
    PG_SOURCE="external"
    REDIS_SOURCE="external"
  else
    PG_SOURCE="in-cluster"
    REDIS_SOURCE="in-cluster"
  fi
fi

# Postgres sizing (only if external)
PG_INSTANCE="db.t3.large"
PG_STORAGE=20
PG_MAX_STORAGE=100
PG_DELETION_PROTECTION="true"

if [[ "$PG_SOURCE" == "external" ]]; then
  if [[ "$PROFILE" == "prod" ]]; then
    PG_INSTANCE="db.r6g.xlarge"
    PG_STORAGE=50
    PG_MAX_STORAGE=500
  fi
  echo ""
  _ask "RDS instance type" "$PG_INSTANCE"
  PG_INSTANCE="$_REPLY"
  _ask "RDS initial storage (GB)" "$PG_STORAGE"
  PG_STORAGE="$_REPLY"
  _ask "RDS max storage (GB, for autoscaling)" "$PG_MAX_STORAGE"
  PG_MAX_STORAGE="$_REPLY"

  if [[ "$PROFILE" != "prod" ]]; then
    PG_DELETION_PROTECTION="false"
  fi
fi

# Redis sizing (only if external)
REDIS_INSTANCE="cache.m6g.xlarge"
if [[ "$REDIS_SOURCE" == "external" ]]; then
  [[ "$PROFILE" != "prod" ]] && REDIS_INSTANCE="cache.m6g.large"
  _ask "ElastiCache instance type" "$REDIS_INSTANCE"
  REDIS_INSTANCE="$_REPLY"
fi

# ClickHouse
echo ""
_ask_choice "ClickHouse:" \
  "In-cluster — single pod, dev/POC only" \
  "External — LangChain Managed ClickHouse (production)"

CH_SOURCE="in-cluster"
[[ "$_CHOICE" == "2" ]] && CH_SOURCE="external"

if [[ "$PROFILE" == "prod" && "$CH_SOURCE" == "in-cluster" ]]; then
  echo ""
  _yellow "NOTE"; printf ": In-cluster ClickHouse is not recommended for production.\n"
  printf "  See: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. TLS
# ═══════════════════════════════════════════════════════════════════════════

_section "6. TLS / HTTPS"

TLS_SOURCE="none"
ACM_ARN=""
LE_EMAIL=""

_ask_choice "TLS certificate:" \
  "ACM — AWS Certificate Manager (recommended)" \
  "Let's Encrypt — auto-provisioned via cert-manager" \
  "None — HTTP only (not recommended for production)"

case "$_CHOICE" in
  1)
    TLS_SOURCE="acm"
    echo ""
    _ask "ACM certificate ARN" ""
    ACM_ARN="$_REPLY"
    if [[ -z "$ACM_ARN" ]]; then
      _yellow "NOTE"; printf ": You'll need to set acm_certificate_arn before applying.\n"
    fi
    ;;
  2)
    TLS_SOURCE="letsencrypt"
    echo ""
    _ask "Email for Let's Encrypt registration" ""
    LE_EMAIL="$_REPLY"
    ;;
  3)
    TLS_SOURCE="none"
    if [[ "$PROFILE" == "prod" ]]; then
      echo ""
      _yellow "WARNING"; printf ": Running production without TLS is not recommended.\n"
    fi
    ;;
esac

# Domain
DOMAIN=""
if [[ "$TLS_SOURCE" != "none" ]]; then
  echo ""
  _ask "Custom domain (e.g. langsmith.example.com, blank to use ALB DNS)" ""
  DOMAIN="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7. Security Add-ons
# ═══════════════════════════════════════════════════════════════════════════

_section "7. Security Add-ons"

ALB_SCHEME="internet-facing"
ALB_LOGS="false"
CREATE_CLOUDTRAIL="false"
CREATE_WAF="false"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  if _ask_yn "Internal ALB? (private, no public access)" "n"; then
    ALB_SCHEME="internal"
  fi
  if _ask_yn "Enable ALB access logs?" "n"; then
    ALB_LOGS="true"
  fi
  if _ask_yn "Create CloudTrail? (skip if org-level trail exists)" "n"; then
    CREATE_CLOUDTRAIL="true"
  fi
  if _ask_yn "Enable WAF on ALB? (~\$10/mo)" "n"; then
    CREATE_WAF="true"
  fi
  # Bastion — only ask if not already set by EKS private endpoint choice
  if [[ "$CREATE_BASTION" != "true" ]]; then
    if _ask_yn "Create bastion host? (for private cluster access)" "n"; then
      CREATE_BASTION="true"
    fi
  fi
else
  printf "  $(_dim "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 8. S3 TTL
# ═══════════════════════════════════════════════════════════════════════════

_section "8. Storage (S3)"

S3_TTL="true"
S3_SHORT=14
S3_LONG=400

if [[ "$PROFILE" == "prod" ]]; then
  _ask "S3 short-lived trace TTL (days)" "14"
  S3_SHORT="$_REPLY"
  _ask "S3 long-lived trace TTL (days)" "400"
  S3_LONG="$_REPLY"
else
  printf "  $(_dim "Using defaults: short=14d, long=400d. Edit terraform.tfvars to change.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Generate terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

_section "Generating terraform.tfvars"

# Helper to format a list of comma-separated values as a Terraform list
_tf_list() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo "[]"
    return
  fi
  local result="["
  local first=true
  IFS=',' read -ra items <<< "$input"
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"  # trim whitespace
    [[ "$first" == "true" ]] && first=false || result+=", "
    result+="\"$item\""
  done
  result+="]"
  echo "$result"
}

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}

#------------------------------------------------------------------------------
# Identity & Tagging
#------------------------------------------------------------------------------
name_prefix = "${NAME_PREFIX}"
environment = "${ENVIRONMENT}"
region      = "${REGION}"
owner       = "${OWNER}"
TFVARS

if [[ -n "$COST_CENTER" ]]; then
  echo "cost_center = \"${COST_CENTER}\"" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Networking
#------------------------------------------------------------------------------
create_vpc = ${CREATE_VPC}
TFVARS

if [[ "$CREATE_VPC" == "false" ]]; then
  cat >> "$OUTPUT" << TFVARS
vpc_id          = "${VPC_ID}"
vpc_cidr_block  = "${VPC_CIDR}"
private_subnets = $(_tf_list "$PRIVATE_SUBNETS")
public_subnets  = $(_tf_list "$PUBLIC_SUBNETS")
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# EKS
#------------------------------------------------------------------------------
eks_cluster_version       = "${EKS_VERSION}"
enable_public_eks_cluster = ${EKS_PUBLIC}
TFVARS

if [[ -n "$EKS_PUBLIC_CIDRS" ]]; then
  echo "eks_public_access_cidrs = $(_tf_list "$EKS_PUBLIC_CIDRS")" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

eks_managed_node_groups = {
  default = {
    name           = "node-group-default"
    instance_types = ["${NODE_INSTANCE}"]
    min_size       = ${NODE_MIN}
    max_size       = ${NODE_MAX}
  }
}

#------------------------------------------------------------------------------
# Services
#------------------------------------------------------------------------------
postgres_source   = "${PG_SOURCE}"
redis_source      = "${REDIS_SOURCE}"
clickhouse_source = "${CH_SOURCE}"
TFVARS

if [[ "$PG_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# PostgreSQL (RDS)
postgres_instance_type  = "${PG_INSTANCE}"
postgres_storage_gb     = ${PG_STORAGE}
postgres_max_storage_gb = ${PG_MAX_STORAGE}
postgres_deletion_protection = ${PG_DELETION_PROTECTION}
TFVARS
fi

if [[ "$REDIS_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# Redis (ElastiCache)
redis_instance_type = "${REDIS_INSTANCE}"
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# TLS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$ACM_ARN" ]] && echo "acm_certificate_arn    = \"${ACM_ARN}\"" >> "$OUTPUT"
[[ -n "$LE_EMAIL" ]] && echo "letsencrypt_email      = \"${LE_EMAIL}\"" >> "$OUTPUT"
[[ -n "$DOMAIN" ]] && echo "langsmith_domain       = \"${DOMAIN}\"" >> "$OUTPUT"

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Storage (S3)
#------------------------------------------------------------------------------
s3_ttl_enabled    = ${S3_TTL}
s3_ttl_short_days = ${S3_SHORT}
s3_ttl_long_days  = ${S3_LONG}

#------------------------------------------------------------------------------
# Namespace
#------------------------------------------------------------------------------
langsmith_namespace = "langsmith"
TFVARS

# Security add-ons — only write non-default values
HAS_SECURITY=false
SECURITY_BLOCK=""

if [[ "$ALB_SCHEME" != "internet-facing" ]]; then
  SECURITY_BLOCK+="alb_scheme          = \"${ALB_SCHEME}\"\n"
  HAS_SECURITY=true
fi
if [[ "$ALB_LOGS" == "true" ]]; then
  SECURITY_BLOCK+="alb_access_logs_enabled = true\n"
  HAS_SECURITY=true
fi
if [[ "$CREATE_CLOUDTRAIL" == "true" ]]; then
  SECURITY_BLOCK+="create_cloudtrail   = true\n"
  HAS_SECURITY=true
fi
if [[ "$CREATE_WAF" == "true" ]]; then
  SECURITY_BLOCK+="create_waf          = true\n"
  HAS_SECURITY=true
fi
if [[ "$CREATE_BASTION" == "true" ]]; then
  SECURITY_BLOCK+="create_bastion      = true\n"
  HAS_SECURITY=true
fi

if [[ "$HAS_SECURITY" == "true" ]]; then
  cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Security Add-ons
#------------------------------------------------------------------------------
TFVARS
  printf "%b" "$SECURITY_BLOCK" >> "$OUTPUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT")\n"
echo ""
printf "${BOLD}── Summary ──${RESET}\n"
echo ""
printf "  %-22s %s\n" "Profile:"    "$PROFILE"
printf "  %-22s %s\n" "Name:"       "${NAME_PREFIX}-${ENVIRONMENT}"
printf "  %-22s %s\n" "Region:"     "$REGION"
printf "  %-22s %s\n" "VPC:"        "$( [[ "$CREATE_VPC" == "true" ]] && echo "new" || echo "existing ($VPC_ID)" )"
printf "  %-22s %s\n" "EKS API:"    "$( [[ "$EKS_PUBLIC" == "true" ]] && echo "public" || echo "private + bastion" )"
printf "  %-22s %s\n" "PostgreSQL:" "$PG_SOURCE"
printf "  %-22s %s\n" "Redis:"      "$REDIS_SOURCE"
printf "  %-22s %s\n" "ClickHouse:" "$CH_SOURCE"
printf "  %-22s %s\n" "TLS:"        "$TLS_SOURCE"
[[ -n "$DOMAIN" ]] && printf "  %-22s %s\n" "Domain:" "$DOMAIN"

echo ""
printf "${BOLD}── Next Steps ──${RESET}\n"
echo ""
printf "  1. Review the generated file:\n"
printf "     ${CYAN}cat infra/terraform.tfvars${RESET}\n"
echo ""
printf "  2. Set up secrets (auto-generates passwords, stores in SSM):\n"
printf "     ${CYAN}source infra/scripts/setup-env.sh${RESET}\n"
echo ""
printf "  3. Deploy infrastructure:\n"
printf "     ${CYAN}make init && make plan${RESET}\n"
printf "     ${CYAN}make apply${RESET}\n"
echo ""
printf "  4. Deploy LangSmith:\n"
printf "     ${CYAN}make init-values && make deploy${RESET}\n"
echo ""
