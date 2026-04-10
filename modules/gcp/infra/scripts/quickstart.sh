#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# quickstart.sh — Interactive setup wizard for LangSmith on GCP
#
# Generates infra/terraform.tfvars from a guided questionnaire.
# Run from the gcp/ directory:
#
#   ./infra/scripts/quickstart.sh
#
# Also available as: make quickstart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
OUTPUT="$INFRA_DIR/terraform.tfvars"

# ── Colors (extend _common.sh with raw vars for printf in heredocs) ───────────
BOLD='\033[1m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

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
    # Reject shell metacharacters that could cause injection in heredocs
    if [[ "$_REPLY" =~ [\`\$\!\\] ]]; then
      _red "  ERROR: value must not contain \`, \$, !, or \\ characters. Try again."
      echo ""
      continue
    fi
    break
  done
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

_ask_int() {
  local prompt="$1" default="${2:-}"
  while true; do
    _ask "$prompt" "$default"
    if [[ "$_REPLY" =~ ^[0-9]+$ ]]; then
      break
    fi
    _red "  ERROR: must be a number. Try again."
    echo ""
  done
}

_section() {
  echo ""
  printf "${BOLD}── %s ──${RESET}\n" "$1"
}

# ── Guard ─────────────────────────────────────────────────────────────────────

if [[ -f "$OUTPUT" ]]; then
  echo ""
  _yellow "WARNING"; printf ": %s already exists.\n" "$OUTPUT"
  if ! _ask_yn "Overwrite it?" "n"; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Banner ────────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}  LangSmith on GCP — Quickstart Setup${RESET}\n"
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
# 2. GCP Identity
# ═══════════════════════════════════════════════════════════════════════════

_section "2. GCP Project & Naming"

# Try to auto-detect project from gcloud
_default_project=$(gcloud config get-value project 2>/dev/null) || _default_project=""

_ask "GCP project ID" "${_default_project}"
PROJECT_ID="$_REPLY"

while true; do
  _ask "Company/team prefix (max 11 chars, lowercase)" "myco"
  NAME_PREFIX="$_REPLY"
  if [[ ${#NAME_PREFIX} -le 11 ]] && [[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9-]*$ ]]; then
    break
  fi
  _red "  ERROR: must be 1-11 lowercase alphanumeric chars (may include hyphens, must start with a letter)."
  echo ""
done

if [[ "$PROFILE" == "prod" ]]; then
  _ask "Environment" "prod"
else
  _ask "Environment (dev, staging, test, uat)" "dev"
fi
ENVIRONMENT="$_REPLY"

_ask "GCP region" "us-west2"
REGION="$_REPLY"

# Zone: default to first zone in the region
_default_zone="${REGION}-a"
_ask "GCP zone (for zonal resources)" "$_default_zone"
ZONE="$_REPLY"

_ask "Owner (team or person, for labels)" "platform-team"
OWNER="$_REPLY"

_ask "Cost center (for billing, leave blank to skip)" ""
COST_CENTER="$_REPLY"

echo ""
printf "  Resources will be named: $(_cyan "${NAME_PREFIX}-${ENVIRONMENT}")-{resource}\n"

# ═══════════════════════════════════════════════════════════════════════════
# 3. GKE Cluster
# ═══════════════════════════════════════════════════════════════════════════

_section "3. GKE Cluster"

USE_AUTOPILOT="false"
if [[ "$PROFILE" == "dev" ]]; then
  printf "  $(_dim "Dev profile: using Standard mode GKE.")\n"
else
  if _ask_yn "Use GKE Autopilot mode?" "n"; then
    USE_AUTOPILOT="true"
    printf "  $(_dim "Autopilot: node management is fully managed by GKE.")\n"
  fi
fi

# Node sizing (only relevant for Standard mode)
if [[ "$USE_AUTOPILOT" == "false" ]]; then
  if [[ "$PROFILE" == "prod" ]]; then
    MACHINE_TYPE="e2-standard-8"
    NODE_MIN=3
    NODE_MAX=10
    NODE_COUNT=3
  else
    MACHINE_TYPE="e2-standard-4"
    NODE_MIN=2
    NODE_MAX=5
    NODE_COUNT=2
  fi

  echo ""
  _ask "Machine type" "$MACHINE_TYPE"
  MACHINE_TYPE="$_REPLY"
  _ask_int "Initial node count" "$NODE_COUNT"
  NODE_COUNT="$_REPLY"
  _ask_int "Min nodes (autoscaling)" "$NODE_MIN"
  NODE_MIN="$_REPLY"
  _ask_int "Max nodes (autoscaling)" "$NODE_MAX"
  NODE_MAX="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. Backend Services
# ═══════════════════════════════════════════════════════════════════════════

_section "4. Backend Services"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  $(_dim "Production: external Cloud SQL and Memorystore recommended.")\n"
  PG_SOURCE="external"
  REDIS_SOURCE="external"

  if ! _ask_yn "Use external PostgreSQL (Cloud SQL)?" "y"; then
    PG_SOURCE="in-cluster"
  fi
  if ! _ask_yn "Use external Redis (Memorystore)?" "y"; then
    REDIS_SOURCE="in-cluster"
  fi
else
  _ask_choice "Backend services:" \
    "All external — Cloud SQL + Memorystore (recommended even for dev)" \
    "All in-cluster — everything runs as pods (simplest, least durable)"

  if [[ "$_CHOICE" == "1" ]]; then
    PG_SOURCE="external"
    REDIS_SOURCE="external"
  else
    PG_SOURCE="in-cluster"
    REDIS_SOURCE="in-cluster"
  fi
fi

# Postgres sizing
PG_TIER="db-custom-2-8192"
PG_DISK=50
PG_HA="false"
PG_DELETION_PROTECTION="false"

if [[ "$PG_SOURCE" == "external" ]]; then
  if [[ "$PROFILE" == "prod" ]]; then
    PG_TIER="db-custom-4-16384"
    PG_DISK=100
    PG_HA="true"
    PG_DELETION_PROTECTION="true"
  fi
  echo ""
  _ask "Cloud SQL tier (vCPU-RAM in MB)" "$PG_TIER"
  PG_TIER="$_REPLY"
  _ask_int "Cloud SQL disk size (GB)" "$PG_DISK"
  PG_DISK="$_REPLY"
  if [[ "$PROFILE" == "prod" ]]; then
    _ask_yn "Enable Cloud SQL HA (REGIONAL)?" "y" && PG_HA="true" || PG_HA="false"
    PG_DELETION_PROTECTION="true"
  fi
fi

# Redis sizing
REDIS_MEMORY=5
if [[ "$REDIS_SOURCE" == "external" ]]; then
  [[ "$PROFILE" != "prod" ]] && REDIS_MEMORY=2
  _ask_int "Memorystore memory size (GB)" "$REDIS_MEMORY"
  REDIS_MEMORY="$_REPLY"
fi

# ClickHouse
echo ""
_ask_choice "ClickHouse:" \
  "In-cluster — single pod, dev/POC only" \
  "LangSmith-managed — production-grade, managed by LangChain"

CH_SOURCE="in-cluster"
CH_HOST=""
CH_PASSWORD=""
CH_TLS="true"
[[ "$_CHOICE" == "2" ]] && CH_SOURCE="langsmith-managed"

if [[ "$PROFILE" == "prod" && "$CH_SOURCE" == "in-cluster" ]]; then
  echo ""
  _yellow "NOTE"; printf ": In-cluster ClickHouse is not recommended for production.\n"
  printf "  See: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse\n"
fi

if [[ "$CH_SOURCE" != "in-cluster" ]]; then
  echo ""
  _ask "ClickHouse host" ""
  CH_HOST="$_REPLY"
  _ask "ClickHouse password (or set TF_VAR_clickhouse_password later)" ""
  CH_PASSWORD="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5. TLS / HTTPS
# ═══════════════════════════════════════════════════════════════════════════

_section "5. TLS / HTTPS"

TLS_SOURCE="none"
LE_EMAIL=""
DOMAIN=""

_ask_choice "TLS certificate:" \
  "Let's Encrypt — auto-provisioned via cert-manager (recommended)" \
  "Existing certificate — provide your own TLS cert and key" \
  "None — HTTP only (deploy first, add TLS after DNS is pointed)"

case "$_CHOICE" in
  1)
    TLS_SOURCE="letsencrypt"
    echo ""
    _ask "Email for Let's Encrypt registration" ""
    LE_EMAIL="$_REPLY"
    ;;
  2)
    TLS_SOURCE="existing"
    echo ""
    printf "  ${DIM}Set tls_certificate_crt and tls_certificate_key in terraform.tfvars.${RESET}\n"
    printf "  ${DIM}You can use file() references or inline PEM strings.${RESET}\n"
    ;;
  3)
    TLS_SOURCE="none"
    if [[ "$PROFILE" == "prod" ]]; then
      echo ""
      _yellow "NOTE"; printf ": Consider using TLS for production (staged-deploy walkthrough in tfvars.example).\n"
    fi
    ;;
esac

if [[ "$TLS_SOURCE" != "none" ]]; then
  echo ""
  _ask "LangSmith domain (e.g. langsmith.example.com)" ""
  DOMAIN="$_REPLY"
fi

INSTALL_INGRESS="true"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Product Features
# ═══════════════════════════════════════════════════════════════════════════

_section "6. Product Features (LangGraph Platform)"

ENABLE_DEPLOYMENTS="false"
ENABLE_AGENT_BUILDER="false"
ENABLE_INSIGHTS="false"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  ${DIM}Each feature requires the matching license entitlement.${RESET}\n"
  _ask_yn "Enable Deployments? (deploy agents from LangSmith UI)" "n" \
    && ENABLE_DEPLOYMENTS="true" || true
  if [[ "$ENABLE_DEPLOYMENTS" == "true" ]]; then
    _ask_yn "Enable Agent Builder? (requires Deployments)" "n" \
      && ENABLE_AGENT_BUILDER="true" || true
  fi
  _ask_yn "Enable Insights? (ClickHouse-backed analytics)" "n" \
    && ENABLE_INSIGHTS="true" || true
else
  printf "  $(_dim "Dev profile: all features disabled. Edit terraform.tfvars to enable.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7. Storage
# ═══════════════════════════════════════════════════════════════════════════

_section "7. Storage (GCS)"

TTL_SHORT=14
TTL_LONG=400

if [[ "$PROFILE" == "prod" ]]; then
  _ask_int "Short-lived trace TTL (days, ttl_s/ prefix)" "14"
  TTL_SHORT="$_REPLY"
  _ask_int "Long-lived trace TTL (days, ttl_l/ prefix)" "400"
  TTL_LONG="$_REPLY"
else
  printf "  $(_dim "Using defaults: short=14d, long=400d. Edit terraform.tfvars to change.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Generate terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

_section "Generating terraform.tfvars"

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}

#------------------------------------------------------------------------------
# Identity & GCP Project
#------------------------------------------------------------------------------
project_id  = "${PROJECT_ID}"
name_prefix = "${NAME_PREFIX}"
environment = "${ENVIRONMENT}"
region      = "${REGION}"
zone        = "${ZONE}"
owner       = "${OWNER}"
TFVARS

if [[ -n "$COST_CENTER" ]]; then
  echo "cost_center = \"${COST_CENTER}\"" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# GKE Cluster
#------------------------------------------------------------------------------
gke_use_autopilot       = ${USE_AUTOPILOT}
TFVARS

if [[ "$USE_AUTOPILOT" == "false" ]]; then
  cat >> "$OUTPUT" << TFVARS
gke_machine_type        = "${MACHINE_TYPE}"
gke_node_count          = ${NODE_COUNT}
gke_min_nodes           = ${NODE_MIN}
gke_max_nodes           = ${NODE_MAX}
TFVARS
fi

cat >> "$OUTPUT" << TFVARS
gke_deletion_protection = $( [[ "$PROFILE" == "prod" ]] && echo "true" || echo "false" )

#------------------------------------------------------------------------------
# Backend Services
#------------------------------------------------------------------------------
postgres_source = "${PG_SOURCE}"
redis_source    = "${REDIS_SOURCE}"
TFVARS

if [[ "$PG_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# PostgreSQL (Cloud SQL)
postgres_tier                = "${PG_TIER}"
postgres_disk_size           = ${PG_DISK}
postgres_high_availability   = ${PG_HA}
postgres_deletion_protection = ${PG_DELETION_PROTECTION}
# postgres_password = ""  # Set via: export TF_VAR_postgres_password=... OR source infra/scripts/setup-env.sh
TFVARS
fi

if [[ "$REDIS_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# Redis (Memorystore)
redis_memory_size       = ${REDIS_MEMORY}
redis_high_availability = $( [[ "$PROFILE" == "prod" ]] && echo "true" || echo "false" )
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

# ClickHouse
clickhouse_source = "${CH_SOURCE}"
TFVARS

if [[ -n "$CH_HOST" ]]; then
  cat >> "$OUTPUT" << TFVARS
clickhouse_host = "${CH_HOST}"
clickhouse_tls  = true
# clickhouse_password = ""  # Set via: export TF_VAR_clickhouse_password=...
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Storage (GCS)
#------------------------------------------------------------------------------
storage_ttl_short_days = ${TTL_SHORT}
storage_ttl_long_days  = ${TTL_LONG}

#------------------------------------------------------------------------------
# TLS / HTTPS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$LE_EMAIL" ]] && echo "letsencrypt_email      = \"${LE_EMAIL}\"" >> "$OUTPUT"
[[ -n "$DOMAIN" ]]   && echo "langsmith_domain       = \"${DOMAIN}\""   >> "$OUTPUT"

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Ingress
#------------------------------------------------------------------------------
install_ingress = ${INSTALL_INGRESS}
ingress_type    = "envoy"

#------------------------------------------------------------------------------
# GCP Modules
#------------------------------------------------------------------------------
enable_gcp_iam_module        = true
enable_secret_manager_module = false
enable_langsmith_deployment  = true

#------------------------------------------------------------------------------
# Product Features
# Set to true to enable addons. Each requires the matching license entitlement.
# Run setup-env.sh to auto-generate and store the required encryption keys.
#------------------------------------------------------------------------------
enable_deployments   = ${ENABLE_DEPLOYMENTS}
enable_agent_builder = ${ENABLE_AGENT_BUILDER}
enable_insights      = ${ENABLE_INSIGHTS}

#------------------------------------------------------------------------------
# Labels
#------------------------------------------------------------------------------
labels = {}
TFVARS

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT")\n"
echo ""
printf "${BOLD}── Summary ──${RESET}\n"
echo ""
printf "  %-22s %s\n" "Profile:"    "$PROFILE"
printf "  %-22s %s\n" "Project:"    "$PROJECT_ID"
printf "  %-22s %s\n" "Name:"       "${NAME_PREFIX}-${ENVIRONMENT}"
printf "  %-22s %s\n" "Region:"     "${REGION} / ${ZONE}"
printf "  %-22s %s\n" "GKE:"        "$( [[ "$USE_AUTOPILOT" == "true" ]] && echo "Autopilot" || echo "Standard (${MACHINE_TYPE})" )"
printf "  %-22s %s\n" "PostgreSQL:" "$PG_SOURCE"
printf "  %-22s %s\n" "Redis:"      "$REDIS_SOURCE"
printf "  %-22s %s\n" "ClickHouse:" "$CH_SOURCE"
printf "  %-22s %s\n" "TLS:"        "$TLS_SOURCE"
[[ -n "$DOMAIN" ]] && printf "  %-22s %s\n" "Domain:" "$DOMAIN"
printf "  %-22s %s\n" "Features:"   "deployments=${ENABLE_DEPLOYMENTS}  agent_builder=${ENABLE_AGENT_BUILDER}  insights=${ENABLE_INSIGHTS}"

echo ""
printf "${BOLD}── Next Steps ──${RESET}\n"
echo ""
printf "  1. Review the generated file:\n"
printf "     ${CYAN}cat infra/terraform.tfvars${RESET}\n"
echo ""
printf "  2. Set up secrets (auto-generates passwords, stores in Secret Manager):\n"
printf "     ${CYAN}source infra/scripts/setup-env.sh${RESET}\n"
echo ""
printf "  3. Deploy infrastructure:\n"
printf "     ${CYAN}make init && make plan${RESET}\n"
printf "     ${CYAN}make apply${RESET}\n"
echo ""
printf "  4. Deploy LangSmith:\n"
printf "     ${CYAN}make init-values && make deploy${RESET}\n"
echo ""
