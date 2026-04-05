#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# quickstart.sh — Interactive setup wizard for LangSmith on Azure
#
# Generates infra/terraform.tfvars from a guided questionnaire.
# Run from the azure/ directory:
#
#   ./infra/scripts/quickstart.sh
#
# Also available as: make quickstart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
OUTPUT="$INFRA_DIR/terraform.tfvars"

# ── Colors ────────────────────────────────────────────────────────────────────
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
printf "${BOLD}  LangSmith on Azure — Quickstart Setup${RESET}\n"
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
# 2. Subscription & Naming
# ═══════════════════════════════════════════════════════════════════════════

_section "2. Subscription & Naming"

# Auto-detect subscription
AUTO_SUB=""
if command -v az &>/dev/null; then
  AUTO_SUB=$(az account show --query id --output tsv 2>/dev/null) || AUTO_SUB=""
fi

if [[ -n "$AUTO_SUB" ]]; then
  _ask "Azure subscription ID" "$AUTO_SUB"
else
  _ask "Azure subscription ID (az account show --query id -o tsv)" ""
fi
SUBSCRIPTION_ID="$_REPLY"

while true; do
  _ask "Identifier suffix (lowercase, starts with hyphen, e.g. -prod, -staging, -myco)" "-dev"
  IDENTIFIER="$_REPLY"
  if [[ "$IDENTIFIER" =~ ^-[a-z][a-z0-9-]*$ ]]; then
    break
  fi
  _red "  ERROR: must start with a hyphen followed by lowercase alphanumeric chars (e.g. -prod, -myco)."
done

if [[ "$PROFILE" == "prod" ]]; then
  _ask "Environment" "prod"
else
  _ask "Environment" "dev"
fi
ENVIRONMENT="$_REPLY"

_ask "Azure region" "eastus"
LOCATION="$_REPLY"

_ask "Owner (team or person, for tagging)" "platform-team"
OWNER="$_REPLY"

_ask "Cost center (for billing, leave blank to skip)" ""
COST_CENTER="$_REPLY"

echo ""
printf "  Resources will be named: langsmith-{resource}%s\n" "$(_cyan "$IDENTIFIER")"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Networking
# ═══════════════════════════════════════════════════════════════════════════

_section "3. Networking"

CREATE_VNET="true"
VNET_ID=""
AKS_SUBNET_ID=""
POSTGRES_SUBNET_ID=""
REDIS_SUBNET_ID=""

if _ask_yn "Create a new VNet?" "y"; then
  CREATE_VNET="true"
else
  CREATE_VNET="false"
  echo ""
  printf "  ${DIM}Bring Your Own VNet — provide existing resource IDs${RESET}\n"
  echo ""
  printf "  ${DIM}Note: PostgreSQL subnet must have Microsoft.DBforPostgreSQL/flexibleServers delegation.${RESET}\n"
  echo ""

  _ask "VNet resource ID (/subscriptions/.../virtualNetworks/...)" ""
  VNET_ID="$_REPLY"

  _ask "AKS subnet resource ID (/subscriptions/.../subnets/...)" ""
  AKS_SUBNET_ID="$_REPLY"

  _ask "PostgreSQL subnet resource ID (must have flexibleServers delegation)" ""
  POSTGRES_SUBNET_ID="$_REPLY"

  _ask "Redis subnet resource ID" ""
  REDIS_SUBNET_ID="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. AKS
# ═══════════════════════════════════════════════════════════════════════════

_section "4. AKS Cluster"

# Node sizing defaults by profile
if [[ "$PROFILE" == "prod" ]]; then
  NODE_VM_SIZE="Standard_D8s_v3"
  NODE_MIN=3
  NODE_MAX=10
else
  NODE_VM_SIZE="Standard_D4s_v3"
  NODE_MIN=2
  NODE_MAX=5
fi

_ask "Node VM size" "$NODE_VM_SIZE"
NODE_VM_SIZE="$_REPLY"

_ask_int "Node pool min count" "$NODE_MIN"
NODE_MIN="$_REPLY"

_ask_int "Node pool max count" "$NODE_MAX"
NODE_MAX="$_REPLY"

AKS_DELETION_PROTECTION="false"
if [[ "$PROFILE" == "prod" ]]; then
  AKS_DELETION_PROTECTION="true"
  printf "  $(_dim "Production: aks_deletion_protection set to true.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5. Ingress Controller
# ═══════════════════════════════════════════════════════════════════════════

_section "5. Ingress Controller"

_ask_choice "Which ingress controller?" \
  "nginx         — NGINX via Helm (standard, start here)" \
  "istio-addon   — Azure managed Istio, AKS service mesh add-on" \
  "istio         — Istio via Helm (self-managed)" \
  "agic          — Application Gateway Ingress Controller (enterprise, native WAF)" \
  "envoy-gateway — Envoy Gateway (Gateway API native)" \
  "none          — skip (bring your own)"

case "$_CHOICE" in
  1) INGRESS_CONTROLLER="nginx" ;;
  2) INGRESS_CONTROLLER="istio-addon" ;;
  3) INGRESS_CONTROLLER="istio" ;;
  4) INGRESS_CONTROLLER="agic" ;;
  5) INGRESS_CONTROLLER="envoy-gateway" ;;
  6) INGRESS_CONTROLLER="none" ;;
esac

echo ""
printf "  Ingress: $(_cyan "$INGRESS_CONTROLLER")\n"

# Istio addon revision
ISTIO_ADDON_REVISION_LINE=""
if [[ "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
  echo ""
  printf "  ${DIM}Available revisions: az aks mesh get-upgrades -g <rg> -n <cluster>${RESET}\n"
  _ask "Istio addon revision" "asm-1-22"
  ISTIO_ADDON_REVISION_LINE="istio_addon_revision = \"$_REPLY\""
fi

# AGIC options
AGW_SKU_TIER_LINE=""
if [[ "$INGRESS_CONTROLLER" == "agic" ]]; then
  echo ""
  printf "  ${DIM}AGIC creates an Application Gateway v2. WAF_v2 adds integrated WAF.${RESET}\n"
  _ask_choice "Application Gateway SKU tier:" \
    "Standard_v2 — standard (no WAF)" \
    "WAF_v2      — with integrated WAF (OWASP 3.2)"
  if [[ "$_CHOICE" == "2" ]]; then
    AGW_SKU_TIER_LINE="agw_sku_tier = \"WAF_v2\""
  else
    AGW_SKU_TIER_LINE="agw_sku_tier = \"Standard_v2\""
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. DNS + TLS
# ═══════════════════════════════════════════════════════════════════════════

_section "6. DNS + TLS"

TLS_SOURCE="none"
DNS_LABEL=""
LANGSMITH_DOMAIN=""
LE_EMAIL=""

_ask_choice "TLS certificate:" \
  "None          — HTTP only (quickstart default, zero setup)" \
  "Let's Encrypt — HTTPS via HTTP-01 (nginx, istio, envoy-gateway only)" \
  "DNS-01        — HTTPS via DNS-01 (all controllers, requires custom domain)" \
  "Existing      — bring your own K8s TLS secret"

case "$_CHOICE" in
  1) TLS_SOURCE="none" ;;
  2) TLS_SOURCE="letsencrypt" ;;
  3) TLS_SOURCE="dns01" ;;
  4) TLS_SOURCE="existing" ;;
esac

# ── Warn on incompatible controller + TLS combinations ────────────────────
if [[ "$TLS_SOURCE" == "letsencrypt" && "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
  echo ""
  _yellow "⚠  WARNING: istio-addon + letsencrypt is NOT supported."
  printf "   The AKS managed Istio addon does not register a Kubernetes IngressClass.\n"
  printf "   cert-manager HTTP-01 solver creates a temp Ingress that needs an IngressClass\n"
  printf "   to route the ACME challenge — without one, the cert times out and is never issued.\n"
  echo ""
  printf "   Supported options for istio-addon:\n"
  printf "     • none   — HTTP (dev/internal, no cert setup)\n"
  printf "     • dns01  — HTTPS via DNS-01 (requires custom domain + Azure DNS zone)\n"
  echo ""
  if ! _ask_yn "Continue anyway (cert will fail to issue)?" "n"; then
    echo "Aborted. Re-run and select a compatible TLS option."
    exit 1
  fi
fi

if [[ "$TLS_SOURCE" == "letsencrypt" && "$INGRESS_CONTROLLER" == "agic" ]]; then
  echo ""
  _yellow "⚠  WARNING: agic + letsencrypt is NOT supported."
  printf "   Azure Application Gateway rewrites all request paths. The ACME HTTP-01\n"
  printf "   challenge path (/.well-known/acme-challenge/<token>) is modified by AGW\n"
  printf "   and Let's Encrypt cannot verify the token.\n"
  echo ""
  printf "   Supported options for agic:\n"
  printf "     • none   — HTTP\n"
  printf "     • dns01  — HTTPS via DNS-01 (requires custom domain + Azure DNS zone)\n"
  echo ""
  if ! _ask_yn "Continue anyway (cert will fail to issue)?" "n"; then
    echo "Aborted. Re-run and select a compatible TLS option."
    exit 1
  fi
fi

if [[ "$TLS_SOURCE" != "none" && "$TLS_SOURCE" != "existing" ]]; then
  echo ""
  printf "  ${DIM}DNS Option A: Azure public IP DNS label (free, no zone needed)${RESET}\n"
  printf "  ${DIM}  → <label>.%s.cloudapp.azure.com${RESET}\n" "$LOCATION"
  printf "  ${DIM}DNS Option B: Custom domain — provide your own domain${RESET}\n"
  echo ""

  _ask_choice "Which DNS approach?" \
    "Azure public IP DNS label (dns_label) — simplest" \
    "Custom domain (langsmith_domain)"

  if [[ "$_CHOICE" == "1" ]]; then
    _ask "DNS label (e.g. langsmith-prod)" "langsmith${IDENTIFIER}"
    DNS_LABEL="$_REPLY"
  else
    _ask "Custom domain (e.g. langsmith.example.com)" ""
    LANGSMITH_DOMAIN="$_REPLY"
  fi

  if [[ "$TLS_SOURCE" == "letsencrypt" || "$TLS_SOURCE" == "dns01" ]]; then
    _ask "Email for Let's Encrypt registration" ""
    LE_EMAIL="$_REPLY"
  fi
elif [[ "$TLS_SOURCE" == "none" ]] && [[ "$PROFILE" == "prod" ]]; then
  echo ""
  _yellow "WARNING"; printf ": Running production without TLS is not recommended.\n"
fi

CREATE_DNS_ZONE="false"
if [[ "$TLS_SOURCE" == "dns01" ]]; then
  CREATE_DNS_ZONE="true"
  printf "\n  $(_dim "dns01 requires an Azure DNS zone. create_dns_zone will be set to true.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 7. Services
# ═══════════════════════════════════════════════════════════════════════════

_section "7. Backend Services"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  $(_dim "Production: external PostgreSQL and Redis recommended.")\n"
  PG_SOURCE="external"
  REDIS_SOURCE="external"
  if ! _ask_yn "Use external PostgreSQL (Azure DB for PostgreSQL)?" "y"; then
    PG_SOURCE="in-cluster"
  fi
  if ! _ask_yn "Use external Redis (Azure Cache for Redis)?" "y"; then
    REDIS_SOURCE="in-cluster"
  fi
else
  _ask_choice "Backend services:" \
    "External — Azure managed Postgres + Redis (recommended even for dev)" \
    "In-cluster — all services run as pods (simplest, least durable)"

  if [[ "$_CHOICE" == "1" ]]; then
    PG_SOURCE="external"
    REDIS_SOURCE="external"
  else
    PG_SOURCE="in-cluster"
    REDIS_SOURCE="in-cluster"
  fi
fi

# Postgres config
PG_ADMIN_USER="langsmith"
PG_DB_NAME="langsmith"
PG_DELETION_PROTECTION="false"
[[ "$PROFILE" == "prod" ]] && PG_DELETION_PROTECTION="true"

# Redis capacity
REDIS_CAPACITY=1

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
# 8. Key Vault
# ═══════════════════════════════════════════════════════════════════════════

_section "8. Key Vault"

KV_PURGE_PROTECTION="false"
if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  ${DIM}Production note: purge protection = true prevents reusing the identifier for 90 days after destroy.${RESET}\n"
  if _ask_yn "Enable Key Vault purge protection? (recommended for production)" "y"; then
    KV_PURGE_PROTECTION="true"
  fi
else
  printf "  $(_dim "Dev profile: keyvault_purge_protection = false (identifier reusable after destroy).")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 9. Sizing + Features
# ═══════════════════════════════════════════════════════════════════════════

_section "9. Sizing Profile"

_ask_choice "Sizing profile:" \
  "minimum        — absolute minimum (demos, very constrained clusters)" \
  "dev            — single-replica, minimal resources (dev / CI / demos)" \
  "production     — multi-replica with HPA (recommended for all real workloads)" \
  "production-large — high-volume (~50 concurrent users, ~1000 traces/sec)"

case "$_CHOICE" in
  1) SIZING_PROFILE="minimum" ;;
  2) SIZING_PROFILE="dev" ;;
  3) SIZING_PROFILE="production" ;;
  4) SIZING_PROFILE="production-large" ;;
esac

_section "10. Optional Security Add-ons"

CREATE_WAF="false"
CREATE_DIAGNOSTICS="false"
CREATE_BASTION="false"

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  if _ask_yn "Enable Azure WAF policy? (OWASP 3.2 + bot protection)" "n"; then
    CREATE_WAF="true"
  fi
  if _ask_yn "Enable Log Analytics + diagnostics? (recommended for prod)" "y"; then
    CREATE_DIAGNOSTICS="true"
  fi
  if _ask_yn "Create bastion host? (for node-level troubleshooting)" "n"; then
    CREATE_BASTION="true"
  fi
else
  printf "  $(_dim "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Generate terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

_section "Generating terraform.tfvars"

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}

#------------------------------------------------------------------------------
# Subscription & Identity
#------------------------------------------------------------------------------
subscription_id = "${SUBSCRIPTION_ID}"
identifier      = "${IDENTIFIER}"
environment     = "${ENVIRONMENT}"
location        = "${LOCATION}"
TFVARS

if [[ -n "$OWNER" ]]; then
  echo "owner           = \"${OWNER}\"" >> "$OUTPUT"
fi
if [[ -n "$COST_CENTER" ]]; then
  echo "cost_center     = \"${COST_CENTER}\"" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Networking
#------------------------------------------------------------------------------
TFVARS

if [[ "$CREATE_VNET" == "false" ]]; then
  cat >> "$OUTPUT" << TFVARS
create_vnet        = false
vnet_id            = "${VNET_ID}"
aks_subnet_id      = "${AKS_SUBNET_ID}"
postgres_subnet_id = "${POSTGRES_SUBNET_ID}"
redis_subnet_id    = "${REDIS_SUBNET_ID}"
TFVARS
else
  echo "# Using auto-created VNet (default)" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# AKS
#------------------------------------------------------------------------------
default_node_pool_vm_size   = "${NODE_VM_SIZE}"
default_node_pool_min_count = ${NODE_MIN}
default_node_pool_max_count = ${NODE_MAX}
default_node_pool_max_pods  = 60
aks_deletion_protection     = ${AKS_DELETION_PROTECTION}

#------------------------------------------------------------------------------
# Ingress
#------------------------------------------------------------------------------
ingress_controller = "${INGRESS_CONTROLLER}"
TFVARS

if [[ -n "$ISTIO_ADDON_REVISION_LINE" ]]; then
  echo "$ISTIO_ADDON_REVISION_LINE" >> "$OUTPUT"
fi
if [[ -n "$AGW_SKU_TIER_LINE" ]]; then
  echo "$AGW_SKU_TIER_LINE" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# DNS + TLS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$DNS_LABEL" ]] && echo "dns_label        = \"${DNS_LABEL}\"" >> "$OUTPUT"
[[ -n "$LANGSMITH_DOMAIN" ]] && echo "langsmith_domain       = \"${LANGSMITH_DOMAIN}\"" >> "$OUTPUT"
[[ -n "$LE_EMAIL" ]] && echo "letsencrypt_email      = \"${LE_EMAIL}\"" >> "$OUTPUT"
[[ "$CREATE_DNS_ZONE" == "true" ]] && echo "create_dns_zone        = true" >> "$OUTPUT"

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Services
#------------------------------------------------------------------------------
postgres_source   = "${PG_SOURCE}"
redis_source      = "${REDIS_SOURCE}"
clickhouse_source = "${CH_SOURCE}"
TFVARS

if [[ "$PG_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# PostgreSQL
postgres_admin_username      = "${PG_ADMIN_USER}"
postgres_database_name       = "${PG_DB_NAME}"
postgres_deletion_protection = ${PG_DELETION_PROTECTION}
TFVARS
fi

if [[ "$REDIS_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# Redis
redis_capacity = ${REDIS_CAPACITY}
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Key Vault
#------------------------------------------------------------------------------
keyvault_purge_protection = ${KV_PURGE_PROTECTION}

#------------------------------------------------------------------------------
# Blob Storage
#------------------------------------------------------------------------------
blob_ttl_enabled    = true
blob_ttl_short_days = 14
blob_ttl_long_days  = 400

#------------------------------------------------------------------------------
# LangSmith
#------------------------------------------------------------------------------
langsmith_namespace    = "langsmith"
langsmith_release_name = "langsmith"

#------------------------------------------------------------------------------
# Helm Sizing + Feature Flags
# Set flags and re-run: make init-values && make deploy
#------------------------------------------------------------------------------
sizing_profile = "${SIZING_PROFILE}"

# Pass 3 — LangGraph Platform (enable_deployments required before agent_builder/insights/polly)
enable_deployments   = false

# Pass 4 — Agent Builder UI
enable_agent_builder = false

# Pass 5 — Insights (ClickHouse-backed analytics)
enable_insights      = false

# Pass 5 — Polly
enable_polly         = false
TFVARS

# Security add-ons — only write non-default values
HAS_SECURITY=false
SECURITY_BLOCK=""

[[ "$CREATE_WAF" == "true" ]] && { SECURITY_BLOCK+="create_waf         = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_DIAGNOSTICS" == "true" ]] && { SECURITY_BLOCK+="create_diagnostics = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_BASTION" == "true" ]] && { SECURITY_BLOCK+="create_bastion     = true\n"; HAS_SECURITY=true; }

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
printf "  %-22s %s\n" "Profile:"       "$PROFILE"
printf "  %-22s %s\n" "Identifier:"    "$IDENTIFIER"
printf "  %-22s %s\n" "Location:"      "$LOCATION"
printf "  %-22s %s\n" "VNet:"          "$( [[ "$CREATE_VNET" == "true" ]] && echo "new" || echo "existing" )"
printf "  %-22s %s\n" "Ingress:"       "$INGRESS_CONTROLLER"
printf "  %-22s %s\n" "TLS:"           "$TLS_SOURCE"
[[ -n "$DNS_LABEL" ]] && printf "  %-22s %s\n" "DNS label:" "${DNS_LABEL}.${LOCATION}.cloudapp.azure.com"
[[ -n "$LANGSMITH_DOMAIN" ]] && printf "  %-22s %s\n" "Domain:" "$LANGSMITH_DOMAIN"
printf "  %-22s %s\n" "PostgreSQL:"    "$PG_SOURCE"
printf "  %-22s %s\n" "Redis:"         "$REDIS_SOURCE"
printf "  %-22s %s\n" "ClickHouse:"    "$CH_SOURCE"
printf "  %-22s %s\n" "Sizing:"        "$SIZING_PROFILE"

echo ""
printf "${BOLD}── Next Steps ──${RESET}\n"
echo ""
printf "  1. Review the generated file:\n"
printf "     ${CYAN}cat infra/terraform.tfvars${RESET}\n"
echo ""
printf "  2. Bootstrap secrets (prompts once, reads from Key Vault on repeat):\n"
printf "     ${CYAN}make setup-env${RESET}\n"
echo ""
printf "  3. Run preflight checks (az login, resource providers, RBAC, quotas):\n"
printf "     ${CYAN}make preflight${RESET}\n"
echo ""
printf "  4. Deploy infrastructure (~15–20 min):\n"
printf "     ${CYAN}make init${RESET}\n"
printf "     ${CYAN}make apply${RESET}   ${DIM}# note: make plan fails on first deploy — run apply directly${RESET}\n"
echo ""
printf "  5. Get cluster credentials + create K8s secrets:\n"
printf "     ${CYAN}make kubeconfig${RESET}\n"
printf "     ${CYAN}make k8s-secrets${RESET}\n"
echo ""
printf "  6. Generate Helm values + deploy LangSmith (~10 min):\n"
printf "     ${CYAN}make init-values${RESET}\n"
printf "     ${CYAN}make deploy${RESET}\n"
echo ""
printf "  Or run everything in one shot:\n"
printf "     ${CYAN}make deploy-all${RESET}   ${DIM}# apply → kubeconfig → k8s-secrets → init-values → deploy${RESET}\n"
echo ""
printf "  Check status at any time: ${CYAN}make status${RESET}\n"
echo ""
printf "  ${DIM}To enable Pass 3+ (Deployments / Agent Builder / Insights / Polly):${RESET}\n"
printf "  ${DIM}  Set enable_* flags in terraform.tfvars → make init-values && make deploy${RESET}\n"
echo ""
