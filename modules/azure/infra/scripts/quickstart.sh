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

# Print a context hint in dim gray — helps users make the right decision
_hint() {
  printf "  ${DIM}%s${RESET}\n" "$1"
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
printf "${DIM}  Generates terraform.tfvars from a guided questionnaire.${RESET}\n"
printf "${DIM}  Answer each question. Review and change any answer before writing.${RESET}\n"

# ═══════════════════════════════════════════════════════════════════════════
# Section functions — each sets its own variables, callable on redo
# ═══════════════════════════════════════════════════════════════════════════

# -- 1. Profile --------------------------------------------------------------
PROFILE="dev"

_run_section_1() {
  _section "1. Deployment Profile"
  _hint "This sets defaults for node sizing, services, and security across later sections."
  _hint "Dev/POC:    smaller nodes, in-cluster services OK, no deletion protection."
  _hint "Production: D8s_v3 nodes, external Postgres + Redis, deletion protection on."

  _ask_choice "What kind of deployment is this?" \
    "Dev / POC  — minimal resources, in-cluster services OK" \
    "Production — HA resources, external managed services"

  PROFILE="dev"
  [[ "$_CHOICE" == "2" ]] && PROFILE="prod"
  echo ""
  printf "  Profile: $(_green "$PROFILE")\n"
}

# -- 2. Subscription & Naming ------------------------------------------------
SUBSCRIPTION_ID=""
IDENTIFIER="-dev"
ENVIRONMENT="dev"
LOCATION="eastus"
OWNER="platform-team"
COST_CENTER=""

_run_section_2() {
  _section "2. Subscription & Naming"
  _hint "The identifier is appended to every Azure resource name (RG, AKS, KV, blob...)."
  _hint "Example: -prod → langsmith-rg-prod, langsmith-aks-prod, langsmith-kv-prod"
  _hint "Changing it later creates entirely new resources — choose something stable."

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

  local env_default="dev"
  [[ "$PROFILE" == "prod" ]] && env_default="prod"
  _ask "Environment label (for tagging)" "$env_default"
  ENVIRONMENT="$_REPLY"

  _ask "Azure region" "eastus"
  LOCATION="$_REPLY"

  _ask "Owner tag (team or person, for cost attribution)" "platform-team"
  OWNER="$_REPLY"

  _ask "Cost center tag (leave blank to skip)" ""
  COST_CENTER="$_REPLY"

  echo ""
  printf "  Resources: langsmith-{resource}$(_cyan "$IDENTIFIER")  in  $(_cyan "$LOCATION")\n"
}

# -- 3. Networking -----------------------------------------------------------
CREATE_VNET="true"
VNET_ID=""
AKS_SUBNET_ID=""
POSTGRES_SUBNET_ID=""
REDIS_SUBNET_ID=""

_run_section_3() {
  _section "3. Networking"
  _hint "Most deployments use a new VNet — Terraform manages address space and subnets."
  _hint "Choose 'existing VNet' only if you're integrating into a corporate network"
  _hint "where network teams manage VNets centrally."

  CREATE_VNET="true"
  VNET_ID=""; AKS_SUBNET_ID=""; POSTGRES_SUBNET_ID=""; REDIS_SUBNET_ID=""

  if _ask_yn "Create a new VNet? (recommended)" "y"; then
    CREATE_VNET="true"
  else
    CREATE_VNET="false"
    echo ""
    _hint "Bring Your Own VNet — you must provide existing subnet resource IDs."
    _hint "The PostgreSQL subnet must have Microsoft.DBforPostgreSQL/flexibleServers delegation."
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
}

# -- 4. AKS ------------------------------------------------------------------
NODE_VM_SIZE="Standard_D4s_v3"
NODE_MIN=2
NODE_MAX=5
AKS_DELETION_PROTECTION="false"

_run_section_4() {
  _section "4. AKS Cluster"
  _hint "Node sizing determines how many LangSmith services fit per node."
  _hint "Standard_D4s_v3 (4 vCPU, 16 GiB) — OK for dev/POC with in-cluster services."
  _hint "Standard_D8s_v3 (8 vCPU, 32 GiB) — required for production sizing profile."
  _hint "Cost estimate (eastus, on-demand): D4s_v3 ~\$0.19/hr, D8s_v3 ~\$0.38/hr per node."
  _hint "The autoscaler handles bursts — min_count is the always-on floor."

  local vm_default="Standard_D4s_v3"
  local min_default=2
  local max_default=5
  if [[ "$PROFILE" == "prod" ]]; then
    vm_default="Standard_D8s_v3"
    min_default=3
    max_default=10
    _hint "Production defaults: D8s_v3 ×3 min (fits Pass 2 at ~76% CPU utilization)."
  fi

  _ask "Node VM size" "$vm_default"
  NODE_VM_SIZE="$_REPLY"
  _ask_int "Node pool min count (always-on nodes)" "$min_default"
  NODE_MIN="$_REPLY"
  _ask_int "Node pool max count (autoscaler ceiling)" "$max_default"
  NODE_MAX="$_REPLY"

  AKS_DELETION_PROTECTION="false"
  if [[ "$PROFILE" == "prod" ]]; then
    AKS_DELETION_PROTECTION="true"
    _hint "Production: aks_deletion_protection = true (prevents accidental terraform destroy)."
  fi
}

# -- 5. Ingress Controller ---------------------------------------------------
INGRESS_CONTROLLER="nginx"
ISTIO_ADDON_REVISION_LINE=""
AGW_SKU_TIER_LINE=""

_run_section_5() {
  _section "5. Ingress Controller"
  _hint "The ingress controller routes external HTTP/HTTPS traffic to LangSmith pods."
  _hint "nginx       — standard K8s ingress, supported everywhere, easiest to debug."
  _hint "istio-addon — AKS managed Istio mesh; best for multi-dataplane + mTLS use cases."
  _hint "istio       — self-managed Istio via Helm; more control, more operational overhead."
  _hint "agic        — Azure Application Gateway; enterprise WAF built-in, but requires a"
  _hint "              dedicated subnet at VNet creation time (cannot add to existing VNet)."
  _hint "envoy-gateway — Gateway API native; useful if you're standardizing on Gateway API."
  _hint "Start with nginx unless you have a specific reason to use another."

  ISTIO_ADDON_REVISION_LINE=""
  AGW_SKU_TIER_LINE=""

  _ask_choice "Which ingress controller?" \
    "nginx         — NGINX via Helm (recommended default)" \
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

  if [[ "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
    echo ""
    _hint "The Istio addon revision must match what AKS supports in your region."
    _hint "Check available revisions after cluster creation:"
    _hint "  az aks mesh get-upgrades -g <rg> -n <cluster>"
    _ask "Istio addon revision" "asm-1-22"
    ISTIO_ADDON_REVISION_LINE="istio_addon_revision = \"$_REPLY\""
  fi

  if [[ "$INGRESS_CONTROLLER" == "agic" ]]; then
    echo ""
    _hint "AGIC provisions an Azure Application Gateway v2 with a dedicated /24 subnet."
    _hint "WAF_v2 adds OWASP 3.2 rules + bot protection — no separate WAF module needed."
    _hint "Note: AGIC requires a full cluster rebuild to enable (AGW subnet is provisioned"
    _hint "at VNet creation time and cannot be added to an existing VNet)."
    _ask_choice "Application Gateway SKU tier:" \
      "Standard_v2 — standard routing (no WAF)" \
      "WAF_v2      — with integrated WAF (OWASP 3.2 + bot protection)"
    if [[ "$_CHOICE" == "2" ]]; then
      AGW_SKU_TIER_LINE="agw_sku_tier = \"WAF_v2\""
    else
      AGW_SKU_TIER_LINE="agw_sku_tier = \"Standard_v2\""
    fi
  fi
}

# -- 6. DNS + TLS ------------------------------------------------------------
TLS_SOURCE="none"
DNS_LABEL=""
LANGSMITH_DOMAIN=""
LE_EMAIL=""
CREATE_DNS_ZONE="false"

_run_section_6() {
  _section "6. DNS + TLS"
  _hint "Determines how LangSmith is accessed and whether traffic is encrypted."
  _hint ""
  _hint "None          — HTTP only. Fastest setup, zero cert config. Good for dev/internal."
  _hint "              URL: http://<label>.<region>.cloudapp.azure.com"
  _hint ""
  _hint "Let's Encrypt — Free HTTPS via ACME HTTP-01 challenge. Requires a public DNS label."
  _hint "              Works with: nginx, istio (self-managed), envoy-gateway."
  _hint "              Does NOT work with istio-addon or agic (no IngressClass / path rewrite)."
  _hint ""
  _hint "DNS-01        — HTTPS via ACME DNS-01 challenge. Works with ALL controllers."
  _hint "              Requires a custom domain and an Azure DNS zone (NS delegation)."
  _hint "              cert-manager writes TXT records to Azure DNS — no HTTP port needed."
  _hint "              Best for: private clusters, firewalled environments, istio-addon."
  _hint ""
  _hint "Existing      — Bring a pre-issued K8s TLS secret (manual cert management)."

  TLS_SOURCE="none"
  DNS_LABEL=""
  LANGSMITH_DOMAIN=""
  LE_EMAIL=""
  CREATE_DNS_ZONE="false"

  _ask_choice "TLS certificate source:" \
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

  # Incompatibility warnings
  if [[ "$TLS_SOURCE" == "letsencrypt" && "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
    echo ""
    _yellow "⚠  WARNING: istio-addon + letsencrypt is NOT supported."
    printf "   The AKS managed Istio addon does not register a Kubernetes IngressClass.\n"
    printf "   cert-manager HTTP-01 solver needs an IngressClass to route the ACME\n"
    printf "   challenge — without one the cert times out and is never issued.\n"
    printf "   Supported TLS options for istio-addon: none, dns01\n"
    echo ""
    if ! _ask_yn "Continue anyway (cert will fail to issue)?" "n"; then
      echo "  Re-run section 6 to pick a compatible TLS option."
      _run_section_6
      return
    fi
  fi

  if [[ "$TLS_SOURCE" == "letsencrypt" && "$INGRESS_CONTROLLER" == "agic" ]]; then
    echo ""
    _yellow "⚠  WARNING: agic + letsencrypt is NOT supported."
    printf "   Azure Application Gateway rewrites all request paths, including the ACME\n"
    printf "   HTTP-01 challenge path (/.well-known/acme-challenge/<token>).\n"
    printf "   Let's Encrypt cannot verify the token — cert will never issue.\n"
    printf "   Supported TLS options for agic: none, dns01\n"
    echo ""
    if ! _ask_yn "Continue anyway (cert will fail to issue)?" "n"; then
      echo "  Re-run section 6 to pick a compatible TLS option."
      _run_section_6
      return
    fi
  fi

  if [[ "$TLS_SOURCE" == "none" && "$PROFILE" == "prod" ]]; then
    echo ""
    _yellow "WARNING"; printf ": Running production without TLS is not recommended.\n"
  fi

  # DNS hostname setup
  if [[ "$TLS_SOURCE" != "none" && "$TLS_SOURCE" != "existing" ]]; then
    echo ""
    _hint "How do you want to expose the LangSmith URL?"
    _hint "  Azure DNS label — free Azure subdomain, no domain purchase needed."
    _hint "                    Azure assigns <label>.<region>.cloudapp.azure.com to the LB IP."
    _hint "                    Only usable with Let's Encrypt (HTTP-01)."
    _hint "  Custom domain   — bring your own domain (e.g. langsmith.mycompany.com)."
    _hint "                    Required for DNS-01. Works with all controllers."
    _hint "                    You'll delegate a subdomain's NS records to Azure DNS."
    echo ""

    _ask_choice "DNS approach:" \
      "Azure public IP DNS label — simplest, free subdomain" \
      "Custom domain — your own domain (required for DNS-01)"

    if [[ "$_CHOICE" == "1" ]]; then
      _ask "DNS label (e.g. langsmith-prod)" "langsmith${IDENTIFIER}"
      DNS_LABEL="$_REPLY"
    else
      _hint "Example: langsmith.mycompany.com or azurelangsmith.mycompany.com"
      _ask "Custom domain" ""
      LANGSMITH_DOMAIN="$_REPLY"
    fi

    _hint "Let's Encrypt requires an email for your ACME account (cert expiry notifications)."
    _ask "Email for Let's Encrypt / ACME registration" ""
    LE_EMAIL="$_REPLY"

  elif [[ "$TLS_SOURCE" == "none" ]]; then
    echo ""
    _hint "Azure assigns a free DNS label to your load balancer public IP."
    _hint "Format: <label>.<region>.cloudapp.azure.com"
    _ask "DNS label (e.g. langsmith-prod)" "langsmith${IDENTIFIER}"
    DNS_LABEL="$_REPLY"
  fi

  if [[ "$TLS_SOURCE" == "dns01" ]]; then
    CREATE_DNS_ZONE="true"
    echo ""
    _hint "DNS-01 flow: Terraform creates an Azure DNS zone → you delegate the subdomain's"
    _hint "NS records at your registrar → cert-manager writes TXT records to Azure DNS →"
    _hint "Let's Encrypt validates ownership → cert is issued automatically."
    _hint "create_dns_zone = true will be set."
  fi
}

# -- 7. Backend Services -----------------------------------------------------
PG_SOURCE="in-cluster"
REDIS_SOURCE="in-cluster"
CH_SOURCE="in-cluster"
PG_ADMIN_USER="langsmith"
PG_DB_NAME="langsmith"
PG_DELETION_PROTECTION="false"
REDIS_CAPACITY=1

_run_section_7() {
  _section "7. Backend Services"
  _hint "PostgreSQL, Redis, and ClickHouse are required by LangSmith."
  _hint ""
  _hint "In-cluster  — runs as pods. Simple to deploy, but no backups, limited HA."
  _hint "              OK for dev/POC. Do NOT use for production workloads."
  _hint ""
  _hint "External    — Azure managed services (Postgres Flexible Server, Cache for Redis)."
  _hint "              Automated backups, geo-redundancy, independent scaling."
  _hint "              Recommended for production and long-running POCs."
  _hint ""
  _hint "ClickHouse  — always in-cluster for self-hosted (single StatefulSet, no backups)."
  _hint "              For production traces, use LangChain Managed ClickHouse instead."

  PG_SOURCE="in-cluster"
  REDIS_SOURCE="in-cluster"
  CH_SOURCE="in-cluster"
  PG_ADMIN_USER="langsmith"
  PG_DB_NAME="langsmith"
  PG_DELETION_PROTECTION="false"
  REDIS_CAPACITY=1

  if [[ "$PROFILE" == "prod" ]]; then
    echo ""
    _hint "Production: external Postgres and Redis are strongly recommended."
    if ! _ask_yn "Use external PostgreSQL (Azure DB for PostgreSQL Flexible Server)?" "y"; then
      PG_SOURCE="in-cluster"
    else
      PG_SOURCE="external"
    fi
    if ! _ask_yn "Use external Redis (Azure Cache for Redis Premium P1 — 6 GB)?" "y"; then
      REDIS_SOURCE="in-cluster"
    else
      REDIS_SOURCE="external"
    fi
  else
    _ask_choice "Postgres + Redis:" \
      "External — Azure managed services (recommended even for dev — keeps data on destroy)" \
      "In-cluster — all services run as pods (fastest setup, data lost on destroy)"
    if [[ "$_CHOICE" == "1" ]]; then
      PG_SOURCE="external"
      REDIS_SOURCE="external"
    fi
  fi

  if [[ "$PG_SOURCE" == "external" ]]; then
    PG_DELETION_PROTECTION="false"
    [[ "$PROFILE" == "prod" ]] && PG_DELETION_PROTECTION="true"
  fi

  echo ""
  _ask_choice "ClickHouse:" \
    "In-cluster — single pod, dev/POC only (data lost on pod restart without PV backup)" \
    "External   — LangChain Managed ClickHouse (production-grade, contact LangChain)"

  [[ "$_CHOICE" == "2" ]] && CH_SOURCE="external" || CH_SOURCE="in-cluster"

  if [[ "$PROFILE" == "prod" && "$CH_SOURCE" == "in-cluster" ]]; then
    echo ""
    _yellow "NOTE"; printf ": In-cluster ClickHouse is not recommended for production.\n"
    printf "  See: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse\n"
  fi
}

# -- 8. Key Vault ------------------------------------------------------------
KV_PURGE_PROTECTION="false"

_run_section_8() {
  _section "8. Key Vault"
  _hint "Azure Key Vault stores LangSmith secrets (license key, passwords, Fernet keys)."
  _hint ""
  _hint "Purge protection = true  → KV is retained for 90 days after destroy (soft-delete)."
  _hint "                           Prevents data loss from accidental deletion. Production must."
  _hint "                           Downside: cannot reuse the same identifier for 90 days."
  _hint ""
  _hint "Purge protection = false → KV is immediately purged on destroy."
  _hint "                           Good for dev/POC where you want to reuse the identifier."

  KV_PURGE_PROTECTION="false"
  if [[ "$PROFILE" == "prod" ]]; then
    echo ""
    if _ask_yn "Enable Key Vault purge protection? (recommended for production)" "y"; then
      KV_PURGE_PROTECTION="true"
    fi
  else
    _hint "Dev profile: keyvault_purge_protection = false (identifier reusable immediately after destroy)."
  fi
}

# -- 9. Sizing Profile -------------------------------------------------------
SIZING_PROFILE="dev"

_run_section_9() {
  _section "9. Sizing Profile"
  _hint "Controls CPU/memory requests and HPA replica counts for all LangSmith services."
  _hint ""
  _hint "minimum        — bare minimum (demos, heavily constrained clusters, < 4 vCPU total)."
  _hint "dev            — single replica per service, minimal requests. Fast deploys."
  _hint "                 Use with Standard_D4s_v3 × 2+ nodes."
  _hint "production     — multi-replica + HPA (backend×3, queue×3, etc.)."
  _hint "                 Use with Standard_D8s_v3 × 3+ nodes. Required for real workloads."
  _hint "production-large — high-volume (~50 concurrent users, ~1000 traces/sec)."
  _hint "                 Use with Standard_D8s_v3 × 5+ nodes."

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
}

# -- 10. Security Add-ons ----------------------------------------------------
CREATE_WAF="false"
CREATE_DIAGNOSTICS="false"
CREATE_BASTION="false"

_run_section_10() {
  _section "10. Optional Security Add-ons"

  CREATE_WAF="false"
  CREATE_DIAGNOSTICS="false"
  CREATE_BASTION="false"

  if [[ "$PROFILE" == "prod" ]]; then
    echo ""
    _hint "WAF policy      — Azure WAF with OWASP 3.2 rules + bot protection on the LB."
    _hint "                  Only applies when ingress_controller = agic (WAF_v2 SKU)."
    _hint "                  For nginx/istio, use Azure Front Door or DDoS Protection instead."
    if _ask_yn "Enable Azure WAF policy? (OWASP 3.2 + bot protection)" "n"; then
      CREATE_WAF="true"
    fi

    echo ""
    _hint "Log Analytics   — sends AKS control plane logs + metrics to Log Analytics workspace."
    _hint "                  Required for audit trails, compliance, and live troubleshooting."
    if _ask_yn "Enable Log Analytics + diagnostics? (recommended for production)" "y"; then
      CREATE_DIAGNOSTICS="true"
    fi

    echo ""
    _hint "Bastion host    — jump VM for direct SSH to AKS nodes (private cluster debugging)."
    _hint "                  Not needed for most deployments unless nodes are on a private subnet."
    if _ask_yn "Create bastion host? (for node-level troubleshooting)" "n"; then
      CREATE_BASTION="true"
    fi
  else
    _hint "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable after deploy."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Run all sections in order
# ═══════════════════════════════════════════════════════════════════════════

_run_section_1
_run_section_2
_run_section_3
_run_section_4
_run_section_5
_run_section_6
_run_section_7
_run_section_8
_run_section_9
_run_section_10

# ═══════════════════════════════════════════════════════════════════════════
# Review loop — show summary, let user redo any section
# ═══════════════════════════════════════════════════════════════════════════

while true; do
  echo ""
  printf "${BOLD}══════════════════════════════════════════════════════${RESET}\n"
  printf "${BOLD}  Review your configuration${RESET}\n"
  printf "${BOLD}══════════════════════════════════════════════════════${RESET}\n"
  echo ""
  printf "  %-24s %s\n" "1. Profile:"         "$PROFILE"
  printf "  %-24s %s\n" "2. Identifier:"      "$IDENTIFIER"
  printf "  %-24s %s\n" "   Subscription:"    "$SUBSCRIPTION_ID"
  printf "  %-24s %s\n" "   Location:"        "$LOCATION"
  printf "  %-24s %s\n" "   Environment:"     "$ENVIRONMENT"
  printf "  %-24s %s\n" "3. VNet:"            "$( [[ "$CREATE_VNET" == "true" ]] && echo "new (auto-created)" || echo "existing" )"
  printf "  %-24s %s\n" "4. Node size:"       "$NODE_VM_SIZE  min=$NODE_MIN  max=$NODE_MAX"
  printf "  %-24s %s\n" "5. Ingress:"         "$INGRESS_CONTROLLER"
  [[ -n "$ISTIO_ADDON_REVISION_LINE" ]] && printf "  %-24s %s\n" "   Istio revision:"  "${ISTIO_ADDON_REVISION_LINE#*= }"
  [[ -n "$AGW_SKU_TIER_LINE" ]]         && printf "  %-24s %s\n" "   AGW SKU:"         "${AGW_SKU_TIER_LINE#*= }"
  printf "  %-24s %s\n" "6. TLS:"             "$TLS_SOURCE"
  [[ -n "$DNS_LABEL" ]]         && printf "  %-24s %s\n" "   DNS label:"   "${DNS_LABEL}.${LOCATION}.cloudapp.azure.com"
  [[ -n "$LANGSMITH_DOMAIN" ]] && printf "  %-24s %s\n" "   Domain:"       "$LANGSMITH_DOMAIN"
  [[ -n "$LE_EMAIL" ]]         && printf "  %-24s %s\n" "   ACME email:"   "$LE_EMAIL"
  printf "  %-24s %s\n" "7. PostgreSQL:"      "$PG_SOURCE"
  printf "  %-24s %s\n" "   Redis:"           "$REDIS_SOURCE"
  printf "  %-24s %s\n" "   ClickHouse:"      "$CH_SOURCE"
  printf "  %-24s %s\n" "8. KV purge prot.:"  "$KV_PURGE_PROTECTION"
  printf "  %-24s %s\n" "9. Sizing:"          "$SIZING_PROFILE"
  if [[ "$PROFILE" == "prod" ]]; then
    printf "  %-24s %s\n" "10. WAF:"            "$CREATE_WAF"
    printf "  %-24s %s\n" "    Log Analytics:"  "$CREATE_DIAGNOSTICS"
    printf "  %-24s %s\n" "    Bastion:"        "$CREATE_BASTION"
  fi
  echo ""
  printf "  ${DIM}Press Enter to write terraform.tfvars, or enter a section number (1-10) to change it.${RESET}\n"
  printf "  Choice [Enter to confirm]: "
  read -r _REDO

  # Empty input = confirm
  if [[ -z "$_REDO" ]]; then
    break
  fi

  # Validate input is a number 1-10
  if ! [[ "$_REDO" =~ ^([1-9]|10)$ ]]; then
    _red "  Enter a section number (1-10) or press Enter to confirm."
    continue
  fi

  # Re-run the chosen section
  case "$_REDO" in
    1)  _run_section_1 ;;
    2)  _run_section_2 ;;
    3)  _run_section_3 ;;
    4)  _run_section_4 ;;
    5)  _run_section_5 ;;
    6)  _run_section_6 ;;
    7)  _run_section_7 ;;
    8)  _run_section_8 ;;
    9)  _run_section_9 ;;
    10) _run_section_10 ;;
  esac
done

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

[[ -n "$OWNER" ]]       && echo "owner           = \"${OWNER}\"" >> "$OUTPUT"
[[ -n "$COST_CENTER" ]] && echo "cost_center     = \"${COST_CENTER}\"" >> "$OUTPUT"

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

[[ -n "$ISTIO_ADDON_REVISION_LINE" ]] && echo "$ISTIO_ADDON_REVISION_LINE" >> "$OUTPUT"
[[ -n "$AGW_SKU_TIER_LINE" ]]         && echo "$AGW_SKU_TIER_LINE"         >> "$OUTPUT"

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# DNS + TLS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$DNS_LABEL" ]]        && echo "dns_label              = \"${DNS_LABEL}\""        >> "$OUTPUT"
[[ -n "$LANGSMITH_DOMAIN" ]] && echo "langsmith_domain       = \"${LANGSMITH_DOMAIN}\"" >> "$OUTPUT"
[[ -n "$LE_EMAIL" ]]         && echo "letsencrypt_email      = \"${LE_EMAIL}\""         >> "$OUTPUT"
[[ "$CREATE_DNS_ZONE" == "true" ]] && echo "create_dns_zone        = true"               >> "$OUTPUT"

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

# PostgreSQL Flexible Server
postgres_admin_username      = "${PG_ADMIN_USER}"
postgres_database_name       = "${PG_DB_NAME}"
postgres_deletion_protection = ${PG_DELETION_PROTECTION}
TFVARS
fi

if [[ "$REDIS_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# Azure Cache for Redis (P1 = 6 GB RAM — sufficient for most deployments)
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
# Change flags and re-run: make init-values && make deploy  (no terraform apply needed)
#------------------------------------------------------------------------------
sizing_profile = "${SIZING_PROFILE}"

# Pass 3 — LangGraph Platform (required before agent_builder, insights, polly)
enable_deployments   = false

# Pass 4 — Agent Builder UI
enable_agent_builder = false

# Pass 5 — Insights (ClickHouse-backed analytics)
enable_insights      = false

# Pass 5 — Polly
enable_polly         = false
TFVARS

HAS_SECURITY=false
SECURITY_BLOCK=""
[[ "$CREATE_WAF" == "true" ]]          && { SECURITY_BLOCK+="create_waf         = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_DIAGNOSTICS" == "true" ]]  && { SECURITY_BLOCK+="create_diagnostics = true\n"; HAS_SECURITY=true; }
[[ "$CREATE_BASTION" == "true" ]]      && { SECURITY_BLOCK+="create_bastion     = true\n"; HAS_SECURITY=true; }

if [[ "$HAS_SECURITY" == "true" ]]; then
  cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Security Add-ons
#------------------------------------------------------------------------------
TFVARS
  printf "%b" "$SECURITY_BLOCK" >> "$OUTPUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT")\n"
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
printf "     ${CYAN}make init && make apply${RESET}\n"
echo ""
printf "  5. Get cluster credentials + create K8s secrets:\n"
printf "     ${CYAN}make kubeconfig && make k8s-secrets${RESET}\n"
echo ""
printf "  6. Generate Helm values + deploy LangSmith (~10 min):\n"
printf "     ${CYAN}make init-values && make deploy${RESET}\n"
echo ""

if [[ "$TLS_SOURCE" == "dns01" && -n "$LANGSMITH_DOMAIN" ]]; then
  _subdomain="${LANGSMITH_DOMAIN%%.*}"
  _parent="${LANGSMITH_DOMAIN#*.}"
  printf "  ${BOLD}DNS-01 required action after make apply:${RESET}\n"
  printf "  Get the Azure DNS nameservers:\n"
  printf "     ${CYAN}terraform -chdir=infra output dns_nameservers${RESET}\n"
  printf "  At your registrar (wherever ${_parent} is managed), add NS records:\n"
  printf "     Type: NS   Name: ${_subdomain}   Value: <each nameserver from above>\n"
  printf "  Verify propagation: ${CYAN}dig NS ${LANGSMITH_DOMAIN} @8.8.8.8${RESET}\n"
  printf "  Then: ${CYAN}make deploy${RESET}  (cert-manager handles cert issuance automatically)\n"
  echo ""
fi

printf "  Check status at any time: ${CYAN}make status${RESET}\n"
printf "  ${DIM}Pass 3+ (Deployments / Agent Builder / Insights / Polly):${RESET}\n"
printf "  ${DIM}  Set enable_* flags in terraform.tfvars → make init-values && make deploy${RESET}\n"
echo ""
