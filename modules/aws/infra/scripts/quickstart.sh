#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# quickstart.sh — Interactive setup wizard for LangSmith on AWS
#
# Generates (or updates) infra/terraform.tfvars from a guided questionnaire.
# Run from the aws/ directory:
#
#   ./infra/scripts/quickstart.sh         # create or update
#   ./infra/scripts/quickstart.sh --fresh # always start from scratch
#   make quickstart
#
# Update mode: when terraform.tfvars already exists, the wizard pre-fills
# all answers from the existing file so you only need to change what you want.
# Useful for switching gateway mode, enabling TLS, adding product features, etc.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
OUTPUT="$INFRA_DIR/terraform.tfvars"

# ── Colors ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

_ask() {
  local prompt="$1" default="${2:-}"
  while true; do
    if [[ -n "$default" ]]; then
      printf "  %s ${DIM}[%s]${RESET}: " "$prompt" "$default"
    else
      printf "  %s: " "$prompt"
    fi
    read -r _REPLY
    _REPLY="${_REPLY:-$default}"
    if [[ "$_REPLY" =~ [\`\$\!\\] ]]; then
      _red "  ERROR: value must not contain \`, \$, !, or \\ characters. Try again."
      continue
    fi
    break
  done
}

_ask_yn() {
  local prompt="$1" default="${2:-y}"
  local hint="Y/n"; [[ "$default" == "n" ]] && hint="y/N"
  printf "  %s ${DIM}[%s]${RESET}: " "$prompt" "$hint"
  read -r _REPLY
  _REPLY="${_REPLY:-$default}"
  [[ "$_REPLY" =~ ^[Yy] ]]
}

_ask_choice() {
  # Usage: _ask_choice [--default N] "prompt" "opt1" "opt2" ...
  local default=""
  if [[ "${1:-}" == "--default" ]]; then
    default="$2"; shift 2
  fi
  local prompt="$1"; shift
  local options=("$@")
  echo ""
  printf "  ${BOLD}%s${RESET}\n" "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    if [[ -n "$default" && "$i" == "$default" ]]; then
      printf "    %d) %s ${DIM}(default)${RESET}\n" "$i" "$opt"
    else
      printf "    %d) %s\n" "$i" "$opt"
    fi
    ((i++))
  done
  if [[ -n "$default" ]]; then
    printf "  Choice [%s]: " "$default"
  else
    printf "  Choice: "
  fi
  read -r _CHOICE
  _CHOICE="${_CHOICE:-$default}"
  if ! [[ "$_CHOICE" =~ ^[0-9]+$ ]] || (( _CHOICE < 1 || _CHOICE > ${#options[@]} )); then
    _red "  Invalid selection."; echo ""; exit 1
  fi
}

_ask_int() {
  local prompt="$1" default="${2:-}"
  while true; do
    _ask "$prompt" "$default"
    [[ "$_REPLY" =~ ^[0-9]+$ ]] && break
    _red "  ERROR: must be a number. Try again."
  done
}

_section() { echo ""; printf "${BOLD}── %s ──${RESET}\n" "$1"; }

# Read a value from the existing terraform.tfvars, returning a default if missing.
_existing() {
  local key="$1" fallback="${2:-}"
  local val
  val=$(_parse_tfvar "$key" 2>/dev/null) || val="$fallback"
  echo "$val"
}

_existing_bool() {
  local key="$1" fallback="${2:-false}"
  local val
  val=$(_existing "$key" "$fallback")
  echo "$val"
}

# ── Conflict validation ───────────────────────────────────────────────────────
# Called in update mode to alert on contradictory values already in the file.
# Each check prints a warning but does NOT abort — user can fix via the wizard.

_validate_conflicts() {
  local file="$1"
  local found=0

  _conflict_warn() { _yellow "CONFLICT"; printf ": %s\n" "$1"; found=1; }

  local envoy; envoy=$(_parse_tfvar "enable_envoy_gateway" 2>/dev/null || echo "false")
  local istio;  istio=$(_parse_tfvar "enable_istio_gateway" 2>/dev/null || echo "false")
  local nginx;  nginx=$(_parse_tfvar "enable_nginx_ingress" 2>/dev/null || echo "false")
  local tls;    tls=$(_parse_tfvar "tls_certificate_source" 2>/dev/null || echo "none")
  local dns01;  dns01=$(_parse_tfvar "create_cert_manager_irsa" 2>/dev/null || echo "false")

  # More than one gateway controller enabled at the same time
  local gw_count=0
  [[ "$envoy" == "true" ]] && (( gw_count++ )) || true
  [[ "$istio" == "true" ]] && (( gw_count++ )) || true
  [[ "$nginx" == "true" ]] && (( gw_count++ )) || true
  if (( gw_count > 1 )); then
    _conflict_warn "Multiple gateway controllers enabled (nginx=$nginx, envoy=$envoy, istio=$istio)."
    printf "  Only one gateway controller can be active. Choose one in Section 6.\n"
  fi

  # HTTP-01 and DNS-01 both active — both create ClusterIssuer/letsencrypt-prod
  if [[ "$tls" == "letsencrypt" && "$dns01" == "true" ]]; then
    _conflict_warn "tls_certificate_source = \"letsencrypt\" (HTTP-01) AND create_cert_manager_irsa = true (DNS-01)."
    printf "  Both paths create ClusterIssuer/letsencrypt-prod. Pick one in Section 7.\n"
  fi

  # ACM cert with non-ALB gateway — ACM requires ALB for certificate attachment
  if [[ "$tls" == "acm" && ( "$envoy" == "true" || "$istio" == "true" ) ]]; then
    _conflict_warn "tls_certificate_source = \"acm\" with Istio or Envoy Gateway."
    printf "  ACM certificates attach to ALB only. Use DNS-01 for Istio, or switch to ALB.\n"
  fi

  # DNS-01 IRSA enabled but no Istio — cert-manager would issue a cert with no Gateway to use it
  if [[ "$dns01" == "true" && "$istio" != "true" ]]; then
    _conflict_warn "create_cert_manager_irsa = true but enable_istio_gateway is not true."
    printf "  DNS-01 cert-manager is only used with the Istio gateway path.\n"
  fi

  if (( found > 0 )); then
    echo ""
    printf "  ${DIM}The wizard will let you fix these below. Conflicts are enforced by${RESET}\n"
    printf "  ${DIM}terraform preconditions and will cause 'terraform apply' to fail.${RESET}\n"
    echo ""
  fi
}

# ── Mode: fresh vs update ─────────────────────────────────────────────────────

FRESH=false
for arg in "$@"; do [[ "$arg" == "--fresh" ]] && FRESH=true; done

UPDATE_MODE=false
if [[ -f "$OUTPUT" && "$FRESH" == "false" ]]; then
  echo ""
  printf "${BOLD}  LangSmith on AWS — terraform.tfvars already exists${RESET}\n"
  echo ""
  printf "  ${DIM}%s${RESET}\n" "$OUTPUT"
  echo ""
  _ask_choice --default 1 "What would you like to do?" \
    "Update — re-run wizard with current values as defaults (recommended)" \
    "Start fresh — overwrite everything" \
    "Cancel"
  case "$_CHOICE" in
    1) UPDATE_MODE=true ;;
    2) UPDATE_MODE=false ;;
    3) echo "Aborted."; exit 0 ;;
  esac
fi

# In update mode, check for conflicting values already in the file.
if [[ "$UPDATE_MODE" == "true" ]]; then
  _validate_conflicts "$OUTPUT"
fi

# ── Banner ───────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}  LangSmith on AWS — Quickstart Setup${RESET}\n"
if [[ "$UPDATE_MODE" == "true" ]]; then
  printf "${DIM}  Updating terraform.tfvars — existing values shown as defaults.${RESET}\n"
else
  printf "${DIM}  Generates terraform.tfvars for your deployment.${RESET}\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 1. Profile
# ═══════════════════════════════════════════════════════════════════════════

_section "1. Deployment Profile"

_existing_profile=$(_existing "sizing_profile" "")
if [[ "$_existing_profile" == "dev" || "$_existing_profile" == "minimum" ]]; then
  _profile_default=1
else
  _profile_default=2
fi

_ask_choice --default "$_profile_default" "What kind of deployment is this?" \
  "Dev / POC  — minimal resources, in-cluster services OK" \
  "Production — HA resources, external managed services"

PROFILE="dev"
[[ "$_CHOICE" == "2" ]] && PROFILE="prod"
echo ""
printf "  Profile: $(_green "$PROFILE")\n"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Naming & Region
# ═══════════════════════════════════════════════════════════════════════════

_section "2. Naming & Region"

while true; do
  _ask "Company/team prefix (max 15 chars, lowercase)" "$(_existing "name_prefix" "myco")"
  NAME_PREFIX="$_REPLY"
  if [[ ${#NAME_PREFIX} -le 15 ]] && [[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9-]*$ ]]; then break; fi
  _red "  ERROR: 1-15 lowercase alphanumeric chars, start with a letter."
done

_env_default="dev"; [[ "$PROFILE" == "prod" ]] && _env_default="prod"
_ask "Environment" "$(_existing "environment" "$_env_default")"
ENVIRONMENT="$_REPLY"

_ask "AWS region" "$(_existing "region" "us-west-2")"
REGION="$_REPLY"

_ask "Owner (team or person, for tagging)" "$(_existing "owner" "platform-team")"
OWNER="$_REPLY"

_ask "Cost center (for billing, leave blank to skip)" "$(_existing "cost_center" "")"
COST_CENTER="$_REPLY"

echo ""
printf "  Resources will be named: $(_cyan "${NAME_PREFIX}-${ENVIRONMENT}")-{resource}\n"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Networking
# ═══════════════════════════════════════════════════════════════════════════

_section "3. Networking"

_existing_create_vpc=$(_existing "create_vpc" "true")
CREATE_VPC="true"
VPC_ID=""; VPC_CIDR=""; PRIVATE_SUBNETS=""; PUBLIC_SUBNETS=""

if _ask_yn "Create a new VPC?" "$([[ "$_existing_create_vpc" == "true" ]] && echo "y" || echo "n")"; then
  CREATE_VPC="true"
else
  CREATE_VPC="false"
  echo ""
  printf "  ${DIM}Bring Your Own VPC — provide existing resource IDs${RESET}\n"
  _ask "VPC ID"            "$(_existing "vpc_id" "")"
  VPC_ID="$_REPLY"
  _ask "VPC CIDR block"    "$(_existing "vpc_cidr_block" "")"
  VPC_CIDR="$_REPLY"
  _ask "Private subnet IDs (comma-separated)" "$(_existing "private_subnets" "")"
  PRIVATE_SUBNETS="$_REPLY"
  _ask "Public subnet IDs (comma-separated)"  "$(_existing "public_subnets" "")"
  PUBLIC_SUBNETS="$_REPLY"
  if [[ -z "$PUBLIC_SUBNETS" ]]; then
    ALB_SCHEME="internal"
    printf '\n  %sNo public subnets — alb_scheme will be set to "internal"%s\n' "$DIM" "$RESET"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. EKS
# ═══════════════════════════════════════════════════════════════════════════

_section "4. EKS Cluster"

_ask "EKS Kubernetes version" "$(_existing "eks_cluster_version" "1.31")"
EKS_VERSION="$_REPLY"

EKS_PUBLIC="true"; EKS_PUBLIC_CIDRS=""; CREATE_BASTION="false"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  _existing_public=$(_existing "enable_public_eks_cluster" "true")
  _eks_access_default=1; [[ "$_existing_public" == "false" ]] && _eks_access_default=2
  _ask_choice --default "$_eks_access_default" "EKS API endpoint access:" \
    "Public  — accessible from the internet (restrict with CIDRs)" \
    "Private — accessible only from within the VPC (bastion recommended)"
  if [[ "$_CHOICE" == "2" ]]; then
    EKS_PUBLIC="false"; CREATE_BASTION="true"
    printf "\n  $(_dim "Bastion will be created for private cluster access via SSM.")\n"
  else
    echo ""
    _ask "Restrict EKS API to specific CIDRs? (comma-separated, blank = 0.0.0.0/0)" ""
    EKS_PUBLIC_CIDRS="$_REPLY"
  fi
else
  printf "  $(_dim "Dev profile: EKS API endpoint will be public.")\n"
fi

NODE_INSTANCE="$([[ "$PROFILE" == "prod" ]] && echo "m5.4xlarge" || echo "m5.2xlarge")"
NODE_MIN="$([[ "$PROFILE" == "prod" ]] && echo "3" || echo "2")"
NODE_MAX="$([[ "$PROFILE" == "prod" ]] && echo "10" || echo "5")"

echo ""
_ask "Node group instance type" "$(_existing_bool "instance_types" "$NODE_INSTANCE")"
NODE_INSTANCE="$_REPLY"
_ask_int "Node group min size" "$NODE_MIN"
NODE_MIN="$_REPLY"
_ask_int "Node group max size" "$NODE_MAX"
NODE_MAX="$_REPLY"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Backend Services
# ═══════════════════════════════════════════════════════════════════════════

_section "5. Backend Services"

_ex_pg=$(_existing "postgres_source" "")
_ex_redis=$(_existing "redis_source" "")

if [[ "$PROFILE" == "prod" ]]; then
  printf "  $(_dim "Production: external RDS + ElastiCache recommended.")\n"
  PG_SOURCE="external"; REDIS_SOURCE="external"
  if ! _ask_yn "Use external PostgreSQL (RDS)?" "$([[ "$_ex_pg" != "in-cluster" ]] && echo "y" || echo "n")"; then
    PG_SOURCE="in-cluster"
  fi
  if ! _ask_yn "Use external Redis (ElastiCache)?" "$([[ "$_ex_redis" != "in-cluster" ]] && echo "y" || echo "n")"; then
    REDIS_SOURCE="in-cluster"
  fi
else
  _backend_default=1; [[ "$_ex_pg" == "in-cluster" ]] && _backend_default=2
  _ask_choice --default "$_backend_default" "Backend services:" \
    "All external — RDS + ElastiCache (recommended even for dev)" \
    "All in-cluster — everything runs as pods (simplest)"
  if [[ "$_CHOICE" == "1" ]]; then
    PG_SOURCE="external"; REDIS_SOURCE="external"
  else
    PG_SOURCE="in-cluster"; REDIS_SOURCE="in-cluster"
  fi
fi

PG_INSTANCE="$(_existing "postgres_instance_type" "$([[ "$PROFILE" == "prod" ]] && echo "db.r6g.xlarge" || echo "db.t3.large")")"
PG_STORAGE="$(_existing "postgres_storage_gb" "$([[ "$PROFILE" == "prod" ]] && echo "50" || echo "20")")"
PG_MAX_STORAGE="$(_existing "postgres_max_storage_gb" "$([[ "$PROFILE" == "prod" ]] && echo "500" || echo "100")")"
PG_DELETION_PROTECTION="$([[ "$PROFILE" == "prod" ]] && echo "true" || echo "false")"

if [[ "$PG_SOURCE" == "external" ]]; then
  echo ""
  _ask "RDS instance type"           "$PG_INSTANCE";      PG_INSTANCE="$_REPLY"
  _ask_int "RDS initial storage (GB)" "$PG_STORAGE";      PG_STORAGE="$_REPLY"
  _ask_int "RDS max storage (GB)"    "$PG_MAX_STORAGE";   PG_MAX_STORAGE="$_REPLY"
fi

REDIS_INSTANCE="$(_existing "redis_instance_type" "$([[ "$PROFILE" == "prod" ]] && echo "cache.m6g.xlarge" || echo "cache.m6g.large")")"
if [[ "$REDIS_SOURCE" == "external" ]]; then
  _ask "ElastiCache instance type" "$REDIS_INSTANCE"
  REDIS_INSTANCE="$_REPLY"
fi

echo ""
_ex_ch=$(_existing "clickhouse_source" "")
_ch_default=1; [[ "$_ex_ch" == "external" || "$PROFILE" == "prod" ]] && _ch_default=2
_ask_choice --default "$_ch_default" "ClickHouse:" \
  "In-cluster — single pod, dev/POC only" \
  "External — LangChain Managed ClickHouse (production)"
CH_SOURCE="in-cluster"; [[ "$_CHOICE" == "2" ]] && CH_SOURCE="external"
if [[ "$PROFILE" == "prod" && "$CH_SOURCE" == "in-cluster" ]]; then
  echo ""
  _yellow "NOTE"; printf ": In-cluster ClickHouse is not production-grade.\n"
  printf "  Docs: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. Ingress / Gateway Mode
# ═══════════════════════════════════════════════════════════════════════════

_section "6. Ingress / Gateway Mode"

echo ""
printf "  ${DIM}Choose how traffic reaches LangSmith. These options are mutually exclusive:${RESET}\n"
printf "  ${DIM}only one gateway controller can be active at a time.${RESET}\n"
printf "  ${DIM}ALB is the default and simplest. Istio/Envoy needed for split dataplane.${RESET}\n"

_ex_envoy=$(_existing "enable_envoy_gateway" "false")
_ex_istio=$(_existing "enable_istio_gateway" "false")
_ex_nginx=$(_existing "enable_nginx_ingress" "false")
_gw_default=1
[[ "$_ex_nginx" == "true" ]] && _gw_default=2
[[ "$_ex_envoy" == "true" ]] && _gw_default=3
[[ "$_ex_istio" == "true" ]] && _gw_default=4

_ask_choice --default "$_gw_default" "Ingress / Gateway mode:" \
  "ALB (Application Load Balancer) — standard, TLS via ACM or Let's Encrypt HTTP-01" \
  "NGINX Ingress Controller — ALB → NGINX → pods via TargetGroupBinding" \
  "Envoy Gateway (Kubernetes Gateway API) — HTTPRoutes, split dataplane support" \
  "Istio Gateway — VirtualServices, split dataplane, TLS via Let's Encrypt DNS-01"

GATEWAY_MODE="alb"
ENABLE_ENVOY="false"
ENABLE_ISTIO="false"
ENABLE_NGINX="false"

case "$_CHOICE" in
  1) GATEWAY_MODE="alb" ;;
  2) GATEWAY_MODE="nginx"; ENABLE_NGINX="true" ;;
  3) GATEWAY_MODE="envoy"; ENABLE_ENVOY="true" ;;
  4) GATEWAY_MODE="istio"; ENABLE_ISTIO="true" ;;
esac

# For NGINX: brief note (ALB TGB wires automatically, no extra input needed)
if [[ "$GATEWAY_MODE" == "nginx" ]]; then
  echo ""
  printf "  ${DIM}NGINX: ALB → TargetGroupBinding → NGINX controller pods → LangSmith.${RESET}\n"
  printf "  ${DIM}TLS terminates at the ALB. Supports ACM and Let's Encrypt HTTP-01.${RESET}\n"
fi

# For Istio: ask about public NLB
ISTIO_NLB_SCHEME=""
if [[ "$GATEWAY_MODE" == "istio" ]]; then
  echo ""
  printf "  ${DIM}Istio ingressgateway runs an NLB. On EKS it defaults to private subnets.${RESET}\n"
  printf "  ${DIM}You can switch the scheme after deploy via helm upgrade — see example yaml.${RESET}\n"
  if _ask_yn "Make the Istio NLB internet-facing? (public subnets)" "y"; then
    ISTIO_NLB_SCHEME="internet-facing"
  else
    ISTIO_NLB_SCHEME="internal"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7. TLS / HTTPS
# ═══════════════════════════════════════════════════════════════════════════

_section "7. TLS / HTTPS"

_ex_tls=$(_existing "tls_certificate_source" "none")
_ex_domain=$(_existing "langsmith_domain" "")
_ex_acm=$(_existing "acm_certificate_arn" "")
_ex_le_email=$(_existing "letsencrypt_email" "")

# For Istio and Envoy, only DNS-01 works on EKS (HTTP-01 fails due to NLB hairpin NAT).
# ACM is also unavailable for both — ACM certificates attach to ALB only.
# Offer a restricted 2-option menu for both NLB-backed gateway modes.
if [[ "$GATEWAY_MODE" == "istio" ]]; then
  echo ""
  printf "  ${DIM}On EKS, Istio requires DNS-01 (Let's Encrypt via Route 53) for TLS.${RESET}\n"
  printf "  ${DIM}HTTP-01 is not shown: EKS NLBs block hairpin traffic, so cert-manager${RESET}\n"
  printf "  ${DIM}cannot complete the self-check. ACM is also not shown: ACM attaches to${RESET}\n"
  printf "  ${DIM}ALB only and cannot be used with Istio NLB.${RESET}\n"
  _tls_default_istio=2; [[ "$_ex_tls" == "none" || -z "$_ex_tls" ]] || _tls_default_istio=1
  _ask_choice --default "$_tls_default_istio" "TLS certificate (Istio mode):" \
    "Let's Encrypt DNS-01 via Route 53 — fully automated, recommended" \
    "None — HTTP only (useful for initial deploy, add TLS later)"
  case "$_CHOICE" in
    1) TLS_SOURCE="none"   ;; # tls_certificate_source stays "none"; cert-manager handles it
    2) TLS_SOURCE="none"   ;;
  esac
  TLS_MODE="$_CHOICE"  # 1=dns01, 2=no_tls
elif [[ "$GATEWAY_MODE" == "envoy" ]]; then
  echo ""
  printf "  ${DIM}On EKS, Envoy Gateway uses an NLB. HTTP-01 is not shown: EKS NLBs block${RESET}\n"
  printf "  ${DIM}hairpin traffic, so cert-manager cannot complete the self-check.${RESET}\n"
  printf "  ${DIM}ACM is also not shown: ACM attaches to ALB only, not Envoy NLB.${RESET}\n"
  _tls_default_envoy=2; [[ "$_ex_tls" == "none" || -z "$_ex_tls" ]] || _tls_default_envoy=1
  _ask_choice --default "$_tls_default_envoy" "TLS certificate (Envoy mode):" \
    "Let's Encrypt DNS-01 via Route 53 — fully automated, recommended" \
    "None — HTTP only (useful for initial deploy, add TLS later)"
  case "$_CHOICE" in
    1) TLS_SOURCE="none"   ;; # tls_certificate_source stays "none"; cert-manager handles it
    2) TLS_SOURCE="none"   ;;
  esac
  TLS_MODE="$_CHOICE"  # 1=dns01, 2=no_tls
else
  _tls_default_alb=3
  [[ "$_ex_tls" == "acm" ]]        && _tls_default_alb=1
  [[ "$_ex_tls" == "letsencrypt" ]] && _tls_default_alb=2
  _ask_choice --default "$_tls_default_alb" "TLS certificate:" \
    "ACM — AWS Certificate Manager (recommended for ALB)" \
    "Let's Encrypt — auto-provisioned via cert-manager HTTP-01" \
    "None — HTTP only (not recommended for production)"
  TLS_MODE="$_CHOICE"
  case "$_CHOICE" in
    1) TLS_SOURCE="acm" ;;
    2) TLS_SOURCE="letsencrypt" ;;
    3) TLS_SOURCE="none" ;;
  esac
fi

ACM_ARN=""; LE_EMAIL=""; DOMAIN=""; CREATE_CERT_MANAGER="false"; HOSTED_ZONE_ID=""

# ACM ARN
if [[ "$TLS_SOURCE" == "acm" ]]; then
  echo ""
  _ask "ACM certificate ARN (blank = auto-provision via Route 53)" "$_ex_acm"
  ACM_ARN="$_REPLY"
fi

# Domain
echo ""
_ask "Custom domain for LangSmith (e.g. langsmith.example.com, blank = use LB hostname)" "$_ex_domain"
DOMAIN="$_REPLY"

# Let's Encrypt email (HTTP-01 or DNS-01)
if [[ "$TLS_SOURCE" == "letsencrypt" ]] || \
   [[ "$GATEWAY_MODE" == "istio" && "$TLS_MODE" == "1" ]] || \
   [[ "$GATEWAY_MODE" == "envoy" && "$TLS_MODE" == "1" ]]; then
  echo ""
  _ask "Email for Let's Encrypt expiry notifications" "$_ex_le_email"
  LE_EMAIL="$_REPLY"
fi

# cert-manager IRSA for DNS-01 (Istio and Envoy)
if [[ "$GATEWAY_MODE" == "istio" && "$TLS_MODE" == "1" ]] || \
   [[ "$GATEWAY_MODE" == "envoy" && "$TLS_MODE" == "1" ]]; then
  CREATE_CERT_MANAGER="true"
  echo ""
  printf "  ${DIM}cert-manager uses IRSA (no static credentials) to create DNS TXT records.${RESET}\n"
  printf "  ${DIM}Find your hosted zone: aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table${RESET}\n"
  _ask "Route 53 Hosted Zone ID (e.g. Z1ABCDEF123456)" "$(_existing "cert_manager_hosted_zone_id" "")"
  HOSTED_ZONE_ID="$_REPLY"
  if [[ -z "$HOSTED_ZONE_ID" ]]; then
    _yellow "NOTE"; printf ": set cert_manager_hosted_zone_id in terraform.tfvars before applying.\n"
  fi
fi

if [[ "$TLS_SOURCE" == "none" && "$PROFILE" == "prod" && "$GATEWAY_MODE" == "alb" ]]; then
  echo ""
  _yellow "WARNING"; printf ": Running production without TLS is not recommended.\n"
fi

# Early exit: ACM is incompatible with Envoy/Istio (ACM attaches to ALB listeners only)
if [[ ("$ENABLE_ENVOY" == "true" || "$ENABLE_ISTIO" == "true") && "$TLS_SOURCE" == "acm" ]]; then
  echo ""
  _red "ERROR"; printf ": ACM certificates require ALB and cannot be used with Envoy or Istio Gateway.\n"
  echo ""
  printf "  ACM attaches to ALB listeners only. Envoy and Istio use their own\n"
  printf "  load balancers (NLB/Gateway API) and cannot reference ACM certificates.\n"
  echo ""
  printf "  Re-run:  ${CYAN}make quickstart${RESET}\n"
  printf "  Choose:  Let's Encrypt (DNS-01 for Istio, HTTP-01 for Envoy) or None\n"
  echo ""
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# 8. Security Add-ons
# ═══════════════════════════════════════════════════════════════════════════

_section "8. Security Add-ons"

ALB_SCHEME="${ALB_SCHEME:-internet-facing}"
ALB_LOGS="false"; CREATE_CLOUDTRAIL="false"; CREATE_WAF="false"; CREATE_FIREWALL="false"

if [[ "$PROFILE" == "prod" ]]; then
  if [[ "${ALB_SCHEME:-}" == "internal" ]]; then
    printf '  %sALB scheme already set to "internal" (no public subnets)%s\n' "$DIM" "$RESET"
  elif _ask_yn "Internal ALB? (private subnets only)" "$([[ "$(_existing "alb_scheme" "internet-facing")" == "internal" ]] && echo "y" || echo "n")"; then
    ALB_SCHEME="internal"
  fi
  _ask_yn "Enable ALB access logs?" "$([[ "$(_existing "alb_access_logs_enabled" "false")" == "true" ]] && echo "y" || echo "n")" && ALB_LOGS="true" || ALB_LOGS="false"
  _ask_yn "Create CloudTrail? (skip if org-level trail exists)" "$([[ "$(_existing "create_cloudtrail" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_CLOUDTRAIL="true" || CREATE_CLOUDTRAIL="false"
  _ask_yn "Enable WAF on ALB? (~\$10/mo)" "$([[ "$(_existing "create_waf" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_WAF="true" || CREATE_WAF="false"
  _ask_yn "Enable AWS Network Firewall? (FQDN egress filtering, ~\$0.40/hr)" "$([[ "$(_existing "create_firewall" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_FIREWALL="true" || CREATE_FIREWALL="false"
  if [[ "${CREATE_BASTION:-false}" != "true" ]]; then
    _ask_yn "Create bastion host?" "$([[ "$(_existing "create_bastion" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_BASTION="true" || CREATE_BASTION="${CREATE_BASTION:-false}"
  fi
else
  printf "  $(_dim "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 9. Storage (S3)
# ═══════════════════════════════════════════════════════════════════════════

_section "9. Storage (S3)"

S3_TTL="true"
S3_SHORT="$(_existing "s3_ttl_short_days" "14")"
S3_LONG="$(_existing "s3_ttl_long_days" "400")"

if [[ "$PROFILE" == "prod" ]]; then
  _ask_int "S3 short-lived trace TTL (days)" "$S3_SHORT"; S3_SHORT="$_REPLY"
  _ask_int "S3 long-lived trace TTL (days)"  "$S3_LONG";  S3_LONG="$_REPLY"
else
  printf "  $(_dim "Using defaults: short=${S3_SHORT}d, long=${S3_LONG}d. Edit terraform.tfvars to change.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 10. Sizing Profile
# ═══════════════════════════════════════════════════════════════════════════

_section "10. Helm Sizing Profile"

echo ""
printf "  ${DIM}Controls resource requests, replica counts, and HPA ranges for LangSmith pods.${RESET}\n"

_ex_sizing=$(_existing "sizing_profile" "")
_size_default=1
[[ "$_ex_sizing" == "production" ]]       && _size_default=2
[[ "$_ex_sizing" == "production-large" ]] && _size_default=3
[[ "$PROFILE" == "dev" ]]                 && _size_default=1

_ask_choice --default "$_size_default" "Sizing profile:" \
  "dev        — single replica, minimal resources (dev/CI/demos)" \
  "production — multi-replica, HPA autoscaling (~20 users, ~100 traces/sec)" \
  "production-large — higher baselines (~50 users, ~1000 traces/sec)"

case "$_CHOICE" in
  1) SIZING="dev" ;;
  2) SIZING="production" ;;
  3) SIZING="production-large" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# 11. LangGraph Platform Features
# ═══════════════════════════════════════════════════════════════════════════

_section "11. Product Features"

echo ""
printf "  ${DIM}Optional addons — each requires the matching license entitlement.${RESET}\n"

_ex_deploys=$(_existing "enable_deployments" "false")
_ex_ab=$(_existing "enable_agent_builder" "false")
_ex_insights=$(_existing "enable_insights" "false")
_ex_polly=$(_existing "enable_polly" "false")

ENABLE_DEPLOYMENTS="false"; ENABLE_AGENT_BUILDER="false"
ENABLE_INSIGHTS="false"; ENABLE_POLLY="false"

_ask_yn "Enable LangGraph Platform Deployments (listener + operator + host-backend)?" \
  "$([[ "$_ex_deploys" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_DEPLOYMENTS="true" || ENABLE_DEPLOYMENTS="false"

if [[ "$ENABLE_DEPLOYMENTS" == "true" ]]; then
  _ask_yn "  ↳ Enable Agent Builder (visual agent UI, requires Deployments)?" \
    "$([[ "$_ex_ab" == "true" ]] && echo "y" || echo "n")" \
    && ENABLE_AGENT_BUILDER="true" || ENABLE_AGENT_BUILDER="false"
  _ask_yn "  ↳ Enable Polly (AI-powered eval, requires Deployments)?" \
    "$([[ "$_ex_polly" == "true" ]] && echo "y" || echo "n")" \
    && ENABLE_POLLY="true" || ENABLE_POLLY="false"
fi

_ask_yn "Enable Insights (ClickHouse analytics dashboard)?" \
  "$([[ "$_ex_insights" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_INSIGHTS="true" || ENABLE_INSIGHTS="false"

# ═══════════════════════════════════════════════════════════════════════════
# Write terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

# ── Final conflict guard before writing ──────────────────────────────────────
# Belt-and-suspenders: abort if the selections result in a known-bad combination.
# (Should never fire given the menu structure, but protects against future edits.)

_pre_write_guard() {
  local abort=0

  local _gw_on=0
  [[ "$ENABLE_NGINX" == "true" ]] && (( _gw_on++ )) || true
  [[ "$ENABLE_ENVOY" == "true" ]] && (( _gw_on++ )) || true
  [[ "$ENABLE_ISTIO" == "true" ]] && (( _gw_on++ )) || true
  if (( _gw_on > 1 )); then
    _red "ABORT"; printf ": only one of enable_nginx_ingress / enable_envoy_gateway / enable_istio_gateway can be true.\n"
    abort=1
  fi
  if [[ "$TLS_SOURCE" == "letsencrypt" && "$CREATE_CERT_MANAGER" == "true" ]]; then
    _red "ABORT"; printf ": HTTP-01 (tls_certificate_source=letsencrypt) and DNS-01 (create_cert_manager_irsa=true) are mutually exclusive.\n"
    abort=1
  fi
  if [[ "$TLS_SOURCE" == "acm" && ( "$ENABLE_ENVOY" == "true" || "$ENABLE_ISTIO" == "true" ) ]]; then
    _red "ABORT"; printf ": ACM certificates require ALB and cannot be used with Istio or Envoy Gateway.\n"
    abort=1
  fi
  if (( abort )); then
    echo ""
    printf "  Please re-run ${CYAN}make quickstart${RESET} and choose a compatible combination.\n"
    exit 1
  fi
}

_pre_write_guard

_section "Generating terraform.tfvars"

_tf_list() {
  local input="$1"
  [[ -z "$input" ]] && echo "[]" && return
  local result="[" first=true
  IFS=',' read -ra items <<< "$input"
  for item in "${items[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ "$first" == "true" ]] && first=false || result+=", "
    result+="\"$item\""
  done
  echo "${result}]"
}

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}
# Re-run: make quickstart  (will pre-fill defaults from this file)

#------------------------------------------------------------------------------
# Identity & Tagging
#------------------------------------------------------------------------------
name_prefix = "${NAME_PREFIX}"
environment = "${ENVIRONMENT}"
region      = "${REGION}"
owner       = "${OWNER}"
TFVARS

[[ -n "$COST_CENTER" ]] && echo "cost_center = \"${COST_CENTER}\"" >> "$OUTPUT"

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

[[ -n "$EKS_PUBLIC_CIDRS" ]] && echo "eks_public_access_cidrs = $(_tf_list "$EKS_PUBLIC_CIDRS")" >> "$OUTPUT"

cat >> "$OUTPUT" << TFVARS

eks_managed_node_groups = {
  default = {
    name           = "node-group-default"
    instance_types = ["${NODE_INSTANCE}"]
    min_size       = ${NODE_MIN}
    max_size       = ${NODE_MAX}
  }
}
create_gp3_storage_class = true

#------------------------------------------------------------------------------
# Backend Services
#------------------------------------------------------------------------------
postgres_source   = "${PG_SOURCE}"
redis_source      = "${REDIS_SOURCE}"
clickhouse_source = "${CH_SOURCE}"
TFVARS

if [[ "$PG_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# PostgreSQL (RDS)
postgres_instance_type       = "${PG_INSTANCE}"
postgres_storage_gb          = ${PG_STORAGE}
postgres_max_storage_gb      = ${PG_MAX_STORAGE}
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
# Ingress / Gateway Mode
# Only one of enable_nginx_ingress / enable_envoy_gateway / enable_istio_gateway
# should be true at a time.
#------------------------------------------------------------------------------
enable_nginx_ingress = ${ENABLE_NGINX}
enable_envoy_gateway = ${ENABLE_ENVOY}
enable_istio_gateway = ${ENABLE_ISTIO}
TFVARS

# Write istio_nlb_scheme when Istio is selected
if [[ "$GATEWAY_MODE" == "istio" && -n "$ISTIO_NLB_SCHEME" ]]; then
  cat >> "$OUTPUT" << TFVARS
istio_nlb_scheme = "${ISTIO_NLB_SCHEME}"
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# TLS / HTTPS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$ACM_ARN" ]]  && echo "acm_certificate_arn    = \"${ACM_ARN}\""  >> "$OUTPUT"
[[ -n "$LE_EMAIL" ]] && echo "letsencrypt_email      = \"${LE_EMAIL}\""  >> "$OUTPUT"
[[ -n "$DOMAIN" ]]   && echo "langsmith_domain       = \"${DOMAIN}\""    >> "$OUTPUT"

if [[ "$CREATE_CERT_MANAGER" == "true" ]]; then
  cat >> "$OUTPUT" << TFVARS

# cert-manager IRSA for Let's Encrypt DNS-01 (Istio + Route 53)
# terraform apply provisions the IAM role; cert-manager installs and issues
# the cert automatically as part of k8s-bootstrap — no separate make tls step.
create_cert_manager_irsa    = true
cert_manager_hosted_zone_id = "${HOSTED_ZONE_ID}"
TFVARS
else
  cat >> "$OUTPUT" << TFVARS

create_cert_manager_irsa = false
TFVARS
fi

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

#------------------------------------------------------------------------------
# Helm Sizing Profile
# Controls resource requests, replica counts, and HPA ranges.
# Docs: https://docs.langchain.com/langsmith/self-host-scale
#------------------------------------------------------------------------------
sizing_profile = "${SIZING}"

#------------------------------------------------------------------------------
# Product Features
# Set to true to enable addons. Each requires a matching license entitlement.
# deploy.sh reads these flags to select the right Helm values overlays.
#------------------------------------------------------------------------------
enable_deployments   = ${ENABLE_DEPLOYMENTS}
enable_agent_builder = ${ENABLE_AGENT_BUILDER}
enable_insights      = ${ENABLE_INSIGHTS}
enable_polly         = ${ENABLE_POLLY}
TFVARS

# Security add-ons
HAS_SECURITY=false; SECURITY_BLOCK=""
[[ "${ALB_SCHEME:-internet-facing}" != "internet-facing" ]] && { SECURITY_BLOCK+="alb_scheme          = \"${ALB_SCHEME}\"\n"; HAS_SECURITY=true; }
[[ "$ALB_LOGS" == "true" ]]          && { SECURITY_BLOCK+="alb_access_logs_enabled = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_CLOUDTRAIL" == "true" ]] && { SECURITY_BLOCK+="create_cloudtrail   = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_WAF" == "true" ]]        && { SECURITY_BLOCK+="create_waf          = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_FIREWALL" == "true" ]]   && { SECURITY_BLOCK+="create_firewall     = true\n"; HAS_SECURITY=true; }
[[ "${CREATE_BASTION:-false}" == "true" ]] && { SECURITY_BLOCK+="create_bastion      = true\n"; HAS_SECURITY=true; }

if [[ "$HAS_SECURITY" == "true" ]]; then
  cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Security Add-ons
#------------------------------------------------------------------------------
TFVARS
  printf "%b" "$SECURITY_BLOCK" >> "$OUTPUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary + Next Steps
# ═══════════════════════════════════════════════════════════════════════════

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT")\n"
echo ""
printf "${BOLD}── Summary ──${RESET}\n"
echo ""
printf "  %-26s %s\n" "Profile:"      "$PROFILE"
printf "  %-26s %s\n" "Name:"         "${NAME_PREFIX}-${ENVIRONMENT}"
printf "  %-26s %s\n" "Region:"       "$REGION"
printf "  %-26s %s\n" "VPC:"          "$([[ "$CREATE_VPC" == "true" ]] && echo "new" || echo "existing ($VPC_ID)")"
printf "  %-26s %s\n" "EKS API:"      "$([[ "$EKS_PUBLIC" == "true" ]] && echo "public" || echo "private + bastion")"
printf "  %-26s %s\n" "PostgreSQL:"   "$PG_SOURCE"
printf "  %-26s %s\n" "Redis:"        "$REDIS_SOURCE"
printf "  %-26s %s\n" "ClickHouse:"   "$CH_SOURCE"
printf "  %-26s %s\n" "Gateway mode:" "$GATEWAY_MODE"
printf "  %-26s %s\n" "TLS:"          "$([[ "$CREATE_CERT_MANAGER" == "true" ]] && echo "Let's Encrypt DNS-01 (Route 53)" || echo "$TLS_SOURCE")"
[[ -n "$DOMAIN" ]] && printf "  %-26s %s\n" "Domain:" "$DOMAIN"
printf "  %-26s %s\n" "Sizing:"       "$SIZING"
printf "  %-26s %s\n" "Deployments:"  "$ENABLE_DEPLOYMENTS"
[[ "$ENABLE_AGENT_BUILDER" == "true" ]] && printf "  %-26s %s\n" "Agent Builder:" "$ENABLE_AGENT_BUILDER"
[[ "$ENABLE_POLLY" == "true" ]]         && printf "  %-26s %s\n" "Polly:"         "$ENABLE_POLLY"
[[ "$ENABLE_INSIGHTS" == "true" ]]      && printf "  %-26s %s\n" "Insights:"      "$ENABLE_INSIGHTS"

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

if [[ "$GATEWAY_MODE" == "istio" ]]; then
  printf "  4. Install Istio (before or after terraform apply):\n"
  printf "     ${CYAN}helm repo add istio https://istio-release.storage.googleapis.com/charts${RESET}\n"
  printf "     ${CYAN}helm upgrade --install istiod istio/istiod --namespace istio-system --create-namespace --wait${RESET}\n"
  printf "     ${CYAN}helm upgrade --install istio-ingressgateway istio/gateway --namespace istio-system --wait${RESET}\n"
  echo ""
  if [[ "$CREATE_CERT_MANAGER" == "true" ]]; then
    printf "  5. Deploy LangSmith (cert-manager + TLS + Gateway handled by terraform apply):\n"
    printf "     ${CYAN}make init-values && make deploy${RESET}\n"
    echo ""
    printf "  ${DIM}Note: terraform apply installs cert-manager, creates the ClusterIssuer,${RESET}\n"
    printf "  ${DIM}requests the Let's Encrypt cert via DNS-01, and patches the Istio Gateway.${RESET}\n"
    printf "  ${DIM}DNS delegation to Route 53 must be complete before terraform apply.${RESET}\n"
  else
    printf "  5. Deploy LangSmith:\n"
    printf "     ${CYAN}make init-values && make deploy${RESET}\n"
  fi
elif [[ "$GATEWAY_MODE" == "nginx" ]]; then
  printf "  4. Deploy LangSmith:\n"
  printf "     ${CYAN}make init-values && make deploy${RESET}\n"
  echo ""
  printf "  ${DIM}Note: terraform apply installs NGINX ingress-nginx chart and creates a${RESET}\n"
  printf "  ${DIM}TargetGroupBinding to wire the ALB target group to the NGINX controller.${RESET}\n"
  printf "  ${DIM}No separate controller install step needed — handled by k8s-bootstrap.${RESET}\n"
elif [[ "$GATEWAY_MODE" == "envoy" ]]; then
  printf "  4. Deploy LangSmith:\n"
  printf "     ${CYAN}make init-values && make deploy${RESET}\n"
  echo ""
  printf "  ${DIM}Note: terraform apply installs Envoy Gateway and creates the GatewayClass/Gateway.${RESET}\n"
  printf "  ${DIM}No separate controller install step needed — handled by k8s-bootstrap.${RESET}\n"
  echo ""
  if [[ -z "$DOMAIN" ]]; then
    printf "  ${DIM}No custom domain was set. To find your Gateway NLB hostname after deploy:${RESET}\n"
    printf "     ${CYAN}kubectl get gateway langsmith-gateway -n langsmith -o jsonpath='{.status.addresses[0].value}'${RESET}\n"
    printf "  ${DIM}Or check the NLB service directly:${RESET}\n"
    printf "     ${CYAN}kubectl get svc -n envoy-gateway-system${RESET}\n"
    printf "  ${DIM}Use this hostname in your HTTPRoute hostnames field or set langsmith_domain${RESET}\n"
    printf "  ${DIM}in terraform.tfvars and re-run make quickstart.${RESET}\n"
  fi
else
  printf "  4. Deploy LangSmith:\n"
  printf "     ${CYAN}make init-values && make deploy${RESET}\n"
fi

echo ""
printf "  ${DIM}To change options later, re-run:  make quickstart${RESET}\n"
echo ""
