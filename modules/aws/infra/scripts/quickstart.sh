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
# Update mode: when terraform.tfvars already exists, the wizard pre-fills all saved values from the existing file so you only need to change what you want.
# The existing file is backed up before the generated replacement is written.
# Run in a child process when sourced so shell options and exits do not affect the caller.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"
OUTPUT="$INFRA_DIR/terraform.tfvars"
OUTPUT_DISPLAY="modules/aws/infra/terraform.tfvars"
if [[ "$INFRA_DIR" != "$SCRIPT_DIR/.." ]]; then
  OUTPUT_DISPLAY="$OUTPUT"
fi
OUTPUT_BACKUP_DISPLAY="${OUTPUT_DISPLAY}.backup"

# ── Colors ───────────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

_ask() {
  local value_label="default"
  if [[ "${1:-}" == "--default" || "${1:-}" == "--current" ]]; then
    value_label="${1#--}"
    shift
  fi
  local prompt="$1" default="${2:-}"
  while true; do
    if [[ -n "$default" || "$value_label" == "current" ]]; then
      local prompt_label="$prompt" prompt_detail=""
      local display_value="${default:-not set}"
      if [[ "$prompt" == *" — "* ]]; then
        prompt_label="${prompt%% — *}"
        prompt_detail=" — ${prompt#* — }"
      fi
      printf "  %s ${DIM}(%s: %s)${RESET}%s: " "$prompt_label" "$value_label" "$display_value" "$prompt_detail"
    else
      printf "  %s: " "$prompt"
    fi
    read -r _REPLY
    _REPLY="${_REPLY:-$default}"
    if [[ "$_REPLY" =~ [\`\"\$\!\\] ]]; then
      _red "  ERROR: enter a plain value without quotes or command characters. Try again."
      continue
    fi
    break
  done
}

_ask_yn() {
  local value_label=""
  if [[ "${1:-}" == "--default" || "${1:-}" == "--current" ]]; then
    value_label="${1#--}"
    shift
  fi
  local prompt="$1" default="${2:-y}"
  local prompt_label="$prompt" prompt_detail=""
  if [[ "$prompt" == *" — "* ]]; then
    prompt_label="${prompt%% — *}"
    prompt_detail=" — ${prompt#* — }"
  fi
  local hint="Y/n"; [[ "$default" == "n" ]] && hint="y/N"
  if [[ -n "$value_label" ]]; then
    local answer="no"; [[ "$default" == "y" ]] && answer="yes"
    printf "  %s ${DIM}(%s: %s)${RESET}%s ${DIM}[%s]${RESET}: " "$prompt_label" "$value_label" "$answer" "$prompt_detail" "$hint"
  else
    printf "  %s%s ${DIM}[%s]${RESET}: " "$prompt_label" "$prompt_detail" "$hint"
  fi
  read -r _REPLY
  _REPLY="${_REPLY:-$default}"
  [[ "$_REPLY" =~ ^[Yy] ]]
}

_numbered_prompt() {
  local number="$1" label="$2" detail="${3:-}"
  printf '%b%s %s%b%s' "$BOLD" "$number" "$label" "$RESET" "$detail"
}

_ask_choice() {
  # Usage: _ask_choice [--default N|--current N] [--recommended N] "prompt" "opt1" "opt2" ...
  local default="" selection_label="default" recommended=""
  while [[ "${1:-}" == "--default" || "${1:-}" == "--current" || "${1:-}" == "--recommended" ]]; do
    case "$1" in
      --default) default="$2" ;;
      --current) default="$2"; selection_label="current" ;;
      --recommended) recommended="$2" ;;
    esac
    shift 2
  done
  local prompt="$1"; shift
  local options=("$@")
  while true; do
    echo ""
    printf "  ${BOLD}%s${RESET}\n" "$prompt"
    local i=1
    for opt in "${options[@]}"; do
      local option_label=""
      [[ -n "$recommended" && "$i" == "$recommended" ]] && option_label="recommended"
      if [[ -n "$default" && "$i" == "$default" ]]; then
        [[ -n "$option_label" ]] && option_label+=", "
        option_label+="$selection_label"
      fi
      if [[ -n "$option_label" ]]; then
        if [[ "$opt" == *" — "* ]]; then
          printf "    %d) %s ${DIM}(%s)${RESET} — %s\n" "$i" "${opt%% — *}" "$option_label" "${opt#* — }"
        else
          printf "    %d) %s ${DIM}(%s)${RESET}\n" "$i" "$opt" "$option_label"
        fi
      else
        printf "    %d) %s\n" "$i" "$opt"
      fi
      ((i++))
    done
    echo ""
    if [[ -n "$default" ]]; then
      printf "  Choice [%s]: " "$default"
    else
      printf "  Choice: "
    fi
    read -r _CHOICE
    _CHOICE="${_CHOICE:-$default}"
    if [[ "$_CHOICE" =~ ^[0-9]+$ ]] && (( _CHOICE >= 1 && _CHOICE <= ${#options[@]} )); then
      local selected_option="${options[$((_CHOICE - 1))]}"
      selected_option="${selected_option%% — *}"
      printf "  Selected: %s\n" "$(_green "$selected_option")"
      return
    fi
    if [[ ! -t 0 ]]; then
      _red "  Invalid selection."
      exit 1
    fi
    _red "  Invalid selection. Try again."
  done
}

_choice_arg() {
  local key
  if [[ "${UPDATE_MODE:-false}" == "true" ]]; then
    for key in "$@"; do
      if _parse_tfvar "$key" >/dev/null 2>&1; then
        printf '%s' "--current"
        return
      fi
    done
  fi
  printf '%s' "--default"
}

_ask_int() {
  while true; do
    _ask "$@"
    [[ "$_REPLY" =~ ^[0-9]+$ ]] && break
    _red "  ERROR: must be a number. Try again."
  done
}

_ask_required() {
  while true; do
    _ask "$@"
    [[ -n "$_REPLY" ]] && break
    _red "  ERROR: this value is required. Try again."
  done
}

_ask_environment() {
  while true; do
    _ask "$@"
    case "$_REPLY" in
      dev|staging|prod|test|uat) return ;;
      *) _red "  ERROR: environment must be one of: dev, staging, prod, test, uat." ;;
    esac
  done
}

_ask_name_prefix() {
  while true; do
    _ask "$@"
    if [[ ${#_REPLY} -le 15 ]] && [[ "$_REPLY" =~ ^[a-z][a-z0-9-]*$ ]]; then return; fi
    _red "  ERROR: 1-15 lowercase alphanumeric chars, start with a letter."
  done
}

_section() { echo ""; printf "${BOLD}── %s ──${RESET}\n" "$1"; }

_abort_unchanged() {
  echo "Aborted without changing terraform.tfvars."
  exit 0
}

_confirm_or_abort() {
  _ask_yn "$@" || _abort_unchanged
}

# Read a value from the existing terraform.tfvars, returning a default if missing.
_existing() {
  local key="$1" fallback="${2:-}"
  local val
  if [[ "${UPDATE_MODE:-false}" != "true" ]]; then
    echo "$fallback"
    return
  fi
  val=$(_parse_tfvar "$key" 2>/dev/null) || val="$fallback"
  echo "$val"
}

# Return the gateway menu choice for QuickStart.
# Fresh configurations recommend Envoy (1). Updates preserve the existing
# controller; ALB is represented by all three controller flags being false (3).
_quickstart_gateway_default() {
  local update_mode="$1"
  local envoy_enabled="$2"
  local istio_enabled="$3"
  local nginx_enabled="$4"

  if [[ "$update_mode" != "true" ]]; then
    echo "1"
  elif [[ "$envoy_enabled" == "true" ]]; then
    echo "1"
  elif [[ "$istio_enabled" == "true" ]]; then
    echo "2"
  elif [[ "$nginx_enabled" == "true" ]]; then
    echo "4"
  else
    echo "3"
  fi
}

_confirm_storage_change() {
  local service="$1" current="$2" selected="$3"
  if [[ "$UPDATE_MODE" != "true" || "$current" == "$selected" ]]; then
    return
  fi
  if [[ "$current" != "external" && "$current" != "in-cluster" ]]; then
    return
  fi
  echo ""
  _yellow "WARNING"; printf ": changing %s from %s to %s does not move existing data.\n" "$service" "$current" "$selected"
  printf "  Terraform may remove data-bearing resources or leave the old data behind.\n"
  _confirm_or_abort "Continue with this storage change?" "n"
}

# ── Conflict validation ───────────────────────────────────────────────────────
# Called in update mode to alert on contradictory values already in the file.
# Each check prints a warning but does NOT abort — user can fix via the wizard.

_validate_conflicts() {
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
    printf "  Only one gateway controller can be active. Choose one in Section 8.\n"
  fi

  # HTTP-01 and DNS-01 both active — both create ClusterIssuer/letsencrypt-prod
  if [[ "$tls" == "letsencrypt" && "$dns01" == "true" ]]; then
    _conflict_warn "tls_certificate_source = \"letsencrypt\" (HTTP-01) AND create_cert_manager_irsa = true (DNS-01)."
    printf "  Both paths create ClusterIssuer/letsencrypt-prod. Pick one in Section 9.\n"
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
SHOWED_EXISTING_FILE_PROMPT=false
if [[ -f "$OUTPUT" && "$FRESH" == "false" ]]; then
  SHOWED_EXISTING_FILE_PROMPT=true
  echo ""
  printf "${BOLD}  LangSmith on AWS — terraform.tfvars already exists${RESET}\n"
  echo ""
  printf "  ${DIM}%s (from project root)${RESET}\n" "$OUTPUT_DISPLAY"
  echo ""
  _yellow "WARNING"; printf ": QuickStart will replace the existing terraform.tfvars when you finish.\n"
  echo ""
  printf "  $(_green "✓") QuickStart-managed settings will be pre-filled.\n"
  printf "  $(_yellow "!") Hand-written settings may not carry over.\n"
  printf "  $(_green "✓") The original file will be backed up to: ${DIM}%s${RESET}\n" "$OUTPUT_BACKUP_DISPLAY"
  _ask_choice --default 1 "What would you like to do?" \
    "Update — re-run wizard using the existing values" \
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
  _validate_conflicts
fi

# ── Banner ───────────────────────────────────────────────────────────────────

if [[ "$SHOWED_EXISTING_FILE_PROMPT" != "true" ]]; then
  echo ""
  printf "${BOLD}  LangSmith on AWS — QuickStart Setup${RESET}\n"
  printf "${DIM}  Generates terraform.tfvars for your deployment.${RESET}\n"
elif [[ "$UPDATE_MODE" != "true" ]]; then
  echo ""
  printf "${DIM}  Starting fresh — existing terraform.tfvars will be replaced.${RESET}\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 1. Setup Preset
# ═══════════════════════════════════════════════════════════════════════════

_section "1. Setup Preset"

echo ""
printf "  ${DIM}Sets starting defaults for scale, security, and data protection.${RESET}\n"
printf "  ${DIM}Dev / POC favors lower cost and easy cleanup; Production favors safer retention.${RESET}\n"
if [[ "$UPDATE_MODE" == "true" ]]; then
  printf "  ${DIM}Existing settings, including pod sizing, stay unchanged in update mode.${RESET}\n"
fi

_profile_arg="--default"
_profile_default=1
if [[ "$UPDATE_MODE" == "true" ]]; then
  _profile_arg=""
  _profile_default=""
  _current_profile=$(sed -nE 's/^# (QuickStart setup preset|Profile):[[:space:]]*(dev|prod|production)[[:space:]]*$/\2/p' "$OUTPUT" | head -1)
  if [[ "$_current_profile" == "dev" ]]; then
    _profile_arg="--current"
    _profile_default=1
  elif [[ "$_current_profile" == "prod" || "$_current_profile" == "production" ]]; then
    _profile_arg="--current"
    _profile_default=2
  fi
fi

_profile_options=(
  "Dev / POC — smaller-scale defaults for development, evaluation, and testing"
  "Production — production-oriented defaults and security questions"
)
if [[ -n "$_profile_arg" ]]; then
  _ask_choice "$_profile_arg" "$_profile_default" "$(_numbered_prompt "1.1" "Which setup preset should QuickStart use?")" "${_profile_options[@]}"
else
  _ask_choice "$(_numbered_prompt "1.1" "Which setup preset should QuickStart use?")" "${_profile_options[@]}"
fi

PROFILE="dev"
[[ "$_CHOICE" == "2" ]] && PROFILE="prod"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Deployment Details
# ═══════════════════════════════════════════════════════════════════════════

_section "2. Deployment Details"
echo ""

_env_default="dev"; [[ "$PROFILE" == "prod" ]] && _env_default="prod"
if [[ "$UPDATE_MODE" == "true" ]]; then
  NAME_PREFIX="$(_existing "name_prefix" "")"
  ENVIRONMENT="$(_existing "environment" "")"
  REGION="$(_existing "region" "")"

  if [[ -z "$NAME_PREFIX" ]]; then
    _ask_name_prefix --default "$(_numbered_prompt "2.1" "Company/team prefix" " — max 15 chars, lowercase")" "myco"
    NAME_PREFIX="$_REPLY"
  fi
  if [[ -z "$ENVIRONMENT" ]]; then
    _ask_environment --default "$(_numbered_prompt "2.2" "Environment")" "$_env_default"
    ENVIRONMENT="$_REPLY"
  fi
  if [[ -z "$REGION" ]]; then
    _ask --default "$(_numbered_prompt "2.3" "AWS region")" "us-west-2"
    REGION="$_REPLY"
  fi

  printf "  ${BOLD}Deployment identity (kept unchanged)${RESET}\n"
  printf "    %-22s %s\n" "2.1 Name prefix:" "$NAME_PREFIX"
  printf "    %-22s %s\n" "2.2 Environment:" "$ENVIRONMENT"
  printf "    %-22s %s\n" "2.3 AWS region:" "$REGION"
  echo ""
  printf "  ${DIM}These values identify your resources and SSM secrets.${RESET}\n"
  echo ""
  printf "  ${BOLD}Editable tags${RESET}\n"
  echo ""
else
  _ask_name_prefix --default "$(_numbered_prompt "2.1" "Company/team prefix" " — max 15 chars, lowercase")" "myco"
  NAME_PREFIX="$_REPLY"
  _ask_environment --default "$(_numbered_prompt "2.2" "Environment")" "$_env_default"
  ENVIRONMENT="$_REPLY"
  _ask --default "$(_numbered_prompt "2.3" "AWS region")" "us-west-2"
  REGION="$_REPLY"
fi

_ask "$(_choice_arg "owner")" "$(_numbered_prompt "2.4" "Owner" " — team or person used for tagging")" "$(_existing "owner" "platform-team")"
OWNER="$_REPLY"

_ask "$(_choice_arg "cost_center")" "$(_numbered_prompt "2.5" "Cost center" " — billing label, leave blank to skip")" "$(_existing "cost_center" "")"
COST_CENTER="$_REPLY"

echo ""
printf "  Resources will be named: $(_cyan "${NAME_PREFIX}-${ENVIRONMENT}")-{resource}\n"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Networking
# ═══════════════════════════════════════════════════════════════════════════

_section "3. Networking"
echo ""

_existing_create_vpc=$(_existing "create_vpc" "true")
CREATE_VPC="true"
VPC_ID=""; VPC_CIDR=""; PRIVATE_SUBNETS=""; PUBLIC_SUBNETS=""

if [[ "$UPDATE_MODE" == "true" ]]; then
  if [[ "$_existing_create_vpc" == "true" ]]; then
    CREATE_VPC="true"
    printf "  ${DIM}Keeping the current Terraform-managed VPC.${RESET}\n"
  else
    CREATE_VPC="false"
    VPC_ID="$(_existing "vpc_id" "")"
    VPC_CIDR="$(_existing "vpc_cidr_block" "")"
    PRIVATE_SUBNETS="$(_existing "private_subnets" "")"
    PUBLIC_SUBNETS="$(_existing "public_subnets" "")"
    printf "  ${DIM}Keeping the current existing VPC and subnet IDs.${RESET}\n"
  fi
elif _ask_yn "$(_choice_arg "create_vpc")" "$(_numbered_prompt "3.1" "Create a new VPC?")" "$([[ "$_existing_create_vpc" == "true" ]] && echo "y" || echo "n")"; then
  CREATE_VPC="true"
else
  CREATE_VPC="false"
fi

if [[ "$CREATE_VPC" == "false" && "$UPDATE_MODE" != "true" ]]; then
  echo ""
  printf "  ${DIM}Bring Your Own VPC — provide existing resource IDs${RESET}\n"
  _ask_required "$(_numbered_prompt "3.2" "VPC ID")" "$(_existing "vpc_id" "")"
  VPC_ID="$_REPLY"
  _ask_required "$(_numbered_prompt "3.3" "VPC CIDR block")" "$(_existing "vpc_cidr_block" "")"
  VPC_CIDR="$_REPLY"
  _ask_required "$(_numbered_prompt "3.4" "Private subnet IDs" " — comma-separated")" "$(_existing "private_subnets" "")"
  PRIVATE_SUBNETS="$_REPLY"
  _ask "$(_numbered_prompt "3.5" "Public subnet IDs" " — comma-separated, blank = use an internal ALB")" "$(_existing "public_subnets" "")"
  PUBLIC_SUBNETS="$_REPLY"
fi

if [[ "$CREATE_VPC" == "false" && "$UPDATE_MODE" == "true" ]]; then
  [[ -n "$VPC_ID" ]] || { _ask_required "$(_numbered_prompt "3.2" "VPC ID")" ""; VPC_ID="$_REPLY"; }
  [[ -n "$VPC_CIDR" ]] || { _ask_required "$(_numbered_prompt "3.3" "VPC CIDR block")" ""; VPC_CIDR="$_REPLY"; }
  [[ -n "$PRIVATE_SUBNETS" ]] || { _ask_required "$(_numbered_prompt "3.4" "Private subnet IDs" " — comma-separated")" ""; PRIVATE_SUBNETS="$_REPLY"; }
fi

if [[ "$CREATE_VPC" == "false" && -z "$PUBLIC_SUBNETS" ]]; then
  ALB_SCHEME="internal"
  printf '\n  %sNo public subnets — alb_scheme will be set to "internal"%s\n' "$DIM" "$RESET"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4. EKS
# ═══════════════════════════════════════════════════════════════════════════

_section "4. EKS Cluster"
echo ""

_ask "$(_choice_arg "eks_cluster_version")" "$(_numbered_prompt "4.1" "EKS Kubernetes version")" "$(_existing "eks_cluster_version" "1.34")"
EKS_VERSION="$_REPLY"

_existing_eks_public=$(_existing "enable_public_eks_cluster" "true")
_existing_eks_public_cidrs=$(_existing "eks_public_access_cidrs" "0.0.0.0/0")
EKS_PUBLIC="$_existing_eks_public"; EKS_PUBLIC_CIDRS="$_existing_eks_public_cidrs"; CREATE_BASTION="false"

if [[ "$PROFILE" == "prod" ]]; then
  _eks_access_default=1; [[ "$_existing_eks_public" == "false" ]] && _eks_access_default=2
  _ask_choice "$(_choice_arg "enable_public_eks_cluster")" "$_eks_access_default" "$(_numbered_prompt "4.2" "EKS API endpoint access:")" \
    "Public — accessible from the internet (restrict with CIDRs)" \
    "Private — accessible only from within the VPC (bastion recommended)"
  if [[ "$_CHOICE" == "2" ]]; then
    EKS_PUBLIC="false"
    if [[ "$UPDATE_MODE" == "true" && "$_existing_eks_public" == "false" ]]; then
      CREATE_BASTION="$(_existing "create_bastion" "false")"
    else
      CREATE_BASTION="true"
      printf "\n  $(_dim "Bastion will be created for private cluster access via SSM.")\n"
    fi
  else
    EKS_PUBLIC="true"
    echo ""
    _ask "$(_choice_arg "eks_public_access_cidrs")" "$(_numbered_prompt "4.3" "Restrict EKS API to specific CIDRs?" " — comma-separated")" "$(_existing "eks_public_access_cidrs" "0.0.0.0/0")"
    EKS_PUBLIC_CIDRS="$_REPLY"
  fi
else
  if [[ "$UPDATE_MODE" == "true" ]]; then
    printf "  $(_dim "Dev profile: keeping the current EKS API endpoint access and CIDRs.")\n"
  else
    printf "  $(_dim "Dev profile: EKS API endpoint will be public.")\n"
  fi
fi

NODE_INSTANCE="$(_existing "instance_types" "$([[ "$PROFILE" == "prod" ]] && echo "m5.4xlarge" || echo "m5.2xlarge")")"
NODE_MIN="$(_existing "min_size" "$([[ "$PROFILE" == "prod" ]] && echo "3" || echo "2")")"
NODE_MAX="$(_existing "max_size" "$([[ "$PROFILE" == "prod" ]] && echo "10" || echo "5")")"

echo ""
_ask "$(_choice_arg "instance_types")" "$(_numbered_prompt "4.4" "Node group instance type")" "$NODE_INSTANCE"
NODE_INSTANCE="$_REPLY"
_ask_int "$(_choice_arg "min_size")" "$(_numbered_prompt "4.5" "Node group min size")" "$NODE_MIN"
NODE_MIN="$_REPLY"
_ask_int "$(_choice_arg "max_size")" "$(_numbered_prompt "4.6" "Node group max size")" "$NODE_MAX"
NODE_MAX="$_REPLY"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Backend Services
# ═══════════════════════════════════════════════════════════════════════════

_section "5. Backend Services"

_ex_pg=$(_existing "postgres_source" "")
_ex_redis=$(_existing "redis_source" "")

if [[ "$PROFILE" == "prod" ]]; then
  echo ""
  printf "  $(_dim "Production: external RDS + ElastiCache recommended.")\n"
fi

_pg_source_default=1; [[ "$_ex_pg" == "in-cluster" ]] && _pg_source_default=2
_ask_choice "$(_choice_arg "postgres_source")" "$_pg_source_default" --recommended 1 "$(_numbered_prompt "5.1" "Where should PostgreSQL run?")" \
  "Amazon RDS — external and managed by AWS" \
  "In-cluster — runs as Kubernetes pods"
PG_SOURCE="external"; [[ "$_CHOICE" == "2" ]] && PG_SOURCE="in-cluster"
_confirm_storage_change "PostgreSQL" "$_ex_pg" "$PG_SOURCE"

PG_INSTANCE="$(_existing "postgres_instance_type" "$([[ "$PROFILE" == "prod" ]] && echo "db.r6g.xlarge" || echo "db.t3.large")")"
PG_STORAGE="$(_existing "postgres_storage_gb" "$([[ "$PROFILE" == "prod" ]] && echo "50" || echo "20")")"
PG_MAX_STORAGE="$(_existing "postgres_max_storage_gb" "$([[ "$PROFILE" == "prod" ]] && echo "500" || echo "100")")"
if [[ "$PROFILE" == "prod" ]]; then
  PG_DELETION_PROTECTION="true"
  PG_SKIP_FINAL_SNAPSHOT="false"
else
  PG_DELETION_PROTECTION="false"
  PG_SKIP_FINAL_SNAPSHOT="true"
fi
if [[ "$UPDATE_MODE" == "true" ]]; then
  PG_DELETION_PROTECTION="$(_existing "postgres_deletion_protection" "$PG_DELETION_PROTECTION")"
  PG_SKIP_FINAL_SNAPSHOT="$(_existing "postgres_skip_final_snapshot" "$PG_SKIP_FINAL_SNAPSHOT")"
fi

if [[ "$PG_SOURCE" == "external" ]]; then
  echo ""
  _ask "$(_choice_arg "postgres_instance_type")" "$(_numbered_prompt "5.2" "RDS instance type")" "$PG_INSTANCE"; PG_INSTANCE="$_REPLY"
  _ask_int "$(_choice_arg "postgres_storage_gb")" "$(_numbered_prompt "5.3" "RDS initial storage (GB)")" "$PG_STORAGE"; PG_STORAGE="$_REPLY"
  _ask_int "$(_choice_arg "postgres_max_storage_gb")" "$(_numbered_prompt "5.4" "RDS max storage (GB)")" "$PG_MAX_STORAGE"; PG_MAX_STORAGE="$_REPLY"
fi

_redis_source_default=1; [[ "$_ex_redis" == "in-cluster" ]] && _redis_source_default=2
_ask_choice "$(_choice_arg "redis_source")" "$_redis_source_default" --recommended 1 "$(_numbered_prompt "5.5" "Where should Redis run?")" \
  "Amazon ElastiCache — external and managed by AWS" \
  "In-cluster — runs as Kubernetes pods"
REDIS_SOURCE="external"; [[ "$_CHOICE" == "2" ]] && REDIS_SOURCE="in-cluster"
_confirm_storage_change "Redis" "$_ex_redis" "$REDIS_SOURCE"

REDIS_INSTANCE="$(_existing "redis_instance_type" "$([[ "$PROFILE" == "prod" ]] && echo "cache.m6g.xlarge" || echo "cache.m6g.large")")"
if [[ "$REDIS_SOURCE" == "external" ]]; then
  echo ""
  _ask "$(_choice_arg "redis_instance_type")" "$(_numbered_prompt "5.6" "ElastiCache instance type")" "$REDIS_INSTANCE"
  REDIS_INSTANCE="$_REPLY"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 6. ClickHouse
# ═══════════════════════════════════════════════════════════════════════════

_section "6. ClickHouse"

_ex_ch=$(_existing "clickhouse_source" "")
_ch_default=1; [[ "$_ex_ch" == "external" ]] && _ch_default=2
_ask_choice "$(_choice_arg "clickhouse_source")" "$_ch_default" --recommended 1 "$(_numbered_prompt "6.1" "Where should ClickHouse run?")" \
  "In-cluster — supported for production" \
  "External — managed separately"
CH_SOURCE="in-cluster"; [[ "$_CHOICE" == "2" ]] && CH_SOURCE="external"
_confirm_storage_change "ClickHouse" "$_ex_ch" "$CH_SOURCE"

# ═══════════════════════════════════════════════════════════════════════════
# 7. SmithDB
# ═══════════════════════════════════════════════════════════════════════════

_section "7. SmithDB"

_ex_smithdb=$(_existing "enable_smithdb" "false")
_ex_smithdb_ingestion=$(_existing "smithdb_ingestion_enabled" "false")
_ex_smithdb_migration=$(_existing "smithdb_migration_enabled" "false")
_ex_smithdb_query=$(_existing "smithdb_query_enabled" "false")
ENABLE_SMITHDB="false"
SMITHDB_INGESTION="false"; SMITHDB_MIGRATION="false"; SMITHDB_QUERY="false"

if [[ "$PROFILE" == "prod" ]]; then
  SMITHDB_DELETION_PROTECTION="true"
  SMITHDB_SKIP_FINAL_SNAPSHOT="false"
  SMITHDB_S3_FORCE_DESTROY="false"
else
  SMITHDB_DELETION_PROTECTION="false"
  SMITHDB_SKIP_FINAL_SNAPSHOT="true"
  SMITHDB_S3_FORCE_DESTROY="true"
fi
if [[ "$UPDATE_MODE" == "true" ]]; then
  SMITHDB_DELETION_PROTECTION="$(_existing "smithdb_metastore_deletion_protection" "$SMITHDB_DELETION_PROTECTION")"
  SMITHDB_SKIP_FINAL_SNAPSHOT="$(_existing "smithdb_metastore_skip_final_snapshot" "$SMITHDB_SKIP_FINAL_SNAPSHOT")"
  SMITHDB_S3_FORCE_DESTROY="$(_existing "smithdb_s3_force_destroy" "false")"
fi

echo ""
printf "  ${DIM}SmithDB is LangChain's purpose-built trace database for LangSmith.${RESET}\n"
printf "  ${DIM}Enabling it adds:${RESET}\n"
printf "  ${DIM}  - A dedicated RDS PostgreSQL metastore${RESET}\n"
printf "  ${DIM}  - A dedicated S3 object-store bucket${RESET}\n"
printf "  ${DIM}  - An IRSA role for the SmithDB Kubernetes ServiceAccount${RESET}\n"
printf "  ${DIM}  - A Kubernetes Secret containing the metastore connection${RESET}\n"
printf "  ${DIM}  - Karpenter with two EC2 node pools: local NVMe storage and general compute${RESET}\n"
printf "  ${DIM}Ingestion, migration, and query cutover stay disabled initially.${RESET}\n"
echo ""
if _ask_yn "$(_choice_arg "enable_smithdb")" "$(_numbered_prompt "7.1" "Enable SmithDB?")" \
  "$([[ "$_ex_smithdb" == "true" ]] && echo "y" || echo "n")"; then
  ENABLE_SMITHDB="true"
  [[ "$_ex_smithdb_ingestion" == "true" ]] && SMITHDB_INGESTION="true"
  [[ "$_ex_smithdb_migration" == "true" ]] && SMITHDB_MIGRATION="true"
  [[ "$_ex_smithdb_query" == "true" ]] && SMITHDB_QUERY="true"
fi
if [[ "$UPDATE_MODE" == "true" && "$_ex_smithdb" == "true" && "$ENABLE_SMITHDB" != "true" ]]; then
  echo ""
  _yellow "WARNING"; printf ": disabling SmithDB may remove its metastore, S3 bucket, and storage nodes.\n"
  printf "  QuickStart does not move or preserve the data stored in those resources.\n"
  _confirm_or_abort "Continue with disabling SmithDB?" "n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 8. Traffic Routing
# ═══════════════════════════════════════════════════════════════════════════

_section "8. Traffic Routing"

echo ""
printf "  ${DIM}Choose how traffic reaches LangSmith. These options are mutually exclusive:${RESET}\n"
printf "  ${DIM}only one gateway controller can be active at a time.${RESET}\n"
printf "  ${DIM}Envoy Gateway is recommended for new configurations. ALB is simplest if${RESET}\n"
printf "  ${DIM}you don't need Gateway API. Istio is another split-dataplane option.${RESET}\n"

_ex_envoy=$(_existing "enable_envoy_gateway" "false")
_ex_istio=$(_existing "enable_istio_gateway" "false")
_ex_nginx=$(_existing "enable_nginx_ingress" "false")
_gw_default=$(_quickstart_gateway_default \
  "$UPDATE_MODE" "$_ex_envoy" "$_ex_istio" "$_ex_nginx")

_ask_choice "$(_choice_arg "enable_envoy_gateway" "enable_istio_gateway" "enable_nginx_ingress")" "$_gw_default" --recommended 1 "$(_numbered_prompt "8.1" "Ingress / Gateway mode:")" \
  "Envoy Gateway — modern routing with the Kubernetes Gateway API" \
  "Istio Gateway — service-mesh routing with VirtualServices" \
  "Application Load Balancer (ALB) — simplest path using AWS load balancing" \
  "NGINX Ingress Controller — legacy ingress compatibility"

GATEWAY_MODE="envoy"
ENABLE_ENVOY="true"
ENABLE_ISTIO="false"
ENABLE_NGINX="false"

case "$_CHOICE" in
  1) GATEWAY_MODE="envoy"; ENABLE_ENVOY="true" ;;
  2) GATEWAY_MODE="istio"; ENABLE_ENVOY="false"; ENABLE_ISTIO="true" ;;
  3) GATEWAY_MODE="alb"; ENABLE_ENVOY="false" ;;
  4) GATEWAY_MODE="nginx"; ENABLE_ENVOY="false"; ENABLE_NGINX="true" ;;
esac

# For NGINX: brief note (ALB TGB wires automatically, no extra input needed)
if [[ "$GATEWAY_MODE" == "nginx" ]]; then
  echo ""
  printf "  ${DIM}NGINX: ALB → TargetGroupBinding → NGINX controller pods → LangSmith.${RESET}\n"
  printf "  ${DIM}TLS terminates at the ALB using ACM.${RESET}\n"
fi

# For Istio: brief note. No input is needed because the gateway service is ClusterIP and the ALB in front of it decides whether it is public or internal.
if [[ "$GATEWAY_MODE" == "istio" ]]; then
  echo ""
  printf "  ${DIM}Istio: ALB → TargetGroupBinding → istio-ingressgateway pods → LangSmith.${RESET}\n"
  printf "  ${DIM}Terraform installs the gateway chart with service.type=ClusterIP, so it${RESET}\n"
  printf "  ${DIM}provisions no NLB of its own. alb_scheme is what makes this public or${RESET}\n"
  printf "  ${DIM}internal (asked below on the prod profile; dev stays internet-facing).${RESET}\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 9. Domain & HTTPS
# ═══════════════════════════════════════════════════════════════════════════

_section "9. Domain & HTTPS"

_ex_tls=$(_existing "tls_certificate_source" "none")
_ex_domain=$(_existing "langsmith_domain" "")
_ex_acm=$(_existing "acm_certificate_arn" "")
_ex_le_email=$(_existing "letsencrypt_email" "")
_ex_cert_manager=$(_existing "create_cert_manager_irsa" "false")

ACM_ARN=""; LE_EMAIL=""; DOMAIN=""; CREATE_CERT_MANAGER="false"; HOSTED_ZONE_ID=""
DNS_CREATE_ZONE="true"; DNS_EXISTING_ZONE_ID=""

echo ""
if [[ "$UPDATE_MODE" == "true" && -n "$_ex_domain" ]]; then
  DOMAIN="$_ex_domain"
  printf "  %s ${DIM}(current: %s)${RESET} — kept unchanged in update mode\n" "$(_numbered_prompt "9.1" "Custom domain for LangSmith")" "$DOMAIN"
else
  _ask "$(_choice_arg "langsmith_domain")" "$(_numbered_prompt "9.1" "Custom domain for LangSmith" " — e.g. langsmith.example.com, blank = use LB hostname")" "$_ex_domain"
  DOMAIN="$_REPLY"
fi

# ACM terminates TLS at the ALB before forwarding HTTP to either gateway.
# Keep the existing Istio DNS-01 path available.
if [[ "$GATEWAY_MODE" == "istio" ]]; then
  echo ""
  _tls_default_istio=2
  [[ "$_ex_tls" == "acm" ]] && _tls_default_istio=3
  [[ "$_ex_cert_manager" == "true" ]] && _tls_default_istio=1
  _ask_choice "$(_choice_arg "create_cert_manager_irsa" "tls_certificate_source")" "$_tls_default_istio" "$(_numbered_prompt "9.2" "HTTPS readiness (Istio mode):")" \
    "Let's Encrypt DNS-01 — automated through Route 53" \
    "None — HTTP only (useful for initial deploy, add TLS later)" \
    "ACM — HTTPS at the ALB, HTTP to Istio Gateway"
  case "$_CHOICE" in
    1) TLS_SOURCE="none" ;;
    2) TLS_SOURCE="none" ;;
    3) TLS_SOURCE="acm" ;;
  esac
  TLS_MODE="$_CHOICE"  # 1=dns01, 2=no_tls, 3=acm
elif [[ "$GATEWAY_MODE" == "envoy" ]]; then
  echo ""
  printf "  ${DIM}The existing ALB terminates TLS and forwards HTTP to Envoy Gateway.${RESET}\n"
  _tls_default_envoy=2; [[ "$_ex_tls" == "acm" ]] && _tls_default_envoy=1
  _tls_recommended_envoy=""
  [[ "$UPDATE_MODE" != "true" ]] && _tls_recommended_envoy=2
  _ask_choice "$(_choice_arg "tls_certificate_source")" "$_tls_default_envoy" --recommended "$_tls_recommended_envoy" "$(_numbered_prompt "9.2" "HTTPS readiness (Envoy mode):")" \
    "ACM — configure HTTPS through AWS Certificate Manager" \
    "None — prepare DNS and an ACM certificate first, then enable HTTPS on a later run"
  case "$_CHOICE" in
    1) TLS_SOURCE="acm"  ;;
    2) TLS_SOURCE="none"   ;;
  esac
  TLS_MODE="$_CHOICE"  # 1=acm, 2=no_tls
else
  _tls_default_alb=3
  [[ "$_ex_tls" == "acm" ]] && _tls_default_alb=1
  [[ "$_ex_tls" == "letsencrypt" ]] && _tls_default_alb=2
  _tls_recommended_alb=""
  [[ "$UPDATE_MODE" != "true" ]] && _tls_recommended_alb=3
  _ask_choice "$(_choice_arg "tls_certificate_source")" "$_tls_default_alb" --recommended "$_tls_recommended_alb" "$(_numbered_prompt "9.2" "HTTPS readiness:")" \
    "ACM — configure HTTPS through AWS Certificate Manager" \
    "Let's Encrypt — auto-provisioned through cert-manager HTTP-01" \
    "None — prepare DNS and an ACM certificate first, then enable HTTPS on a later run"
  TLS_MODE="$_CHOICE"
  case "$_CHOICE" in
    1) TLS_SOURCE="acm" ;;
    2) TLS_SOURCE="letsencrypt" ;;
    3) TLS_SOURCE="none" ;;
  esac
fi

if [[ "$UPDATE_MODE" == "true" && -n "$_ex_acm" && "$TLS_SOURCE" != "acm" ]]; then
  echo ""
  _yellow "WARNING"; printf ": this removes the saved external ACM certificate ARN.\n"
  printf "  With a custom domain, Terraform may start managing certificate and DNS resources.\n"
  _confirm_or_abort "Continue only if you have planned that migration?" "n"
fi

# ACM certificate ownership
if [[ "$TLS_SOURCE" == "acm" ]]; then
  if [[ -n "$DOMAIN" ]]; then
    _cert_default=1
    [[ -n "$_ex_acm" ]] && _cert_default=2
    _ask_choice "$(_choice_arg "langsmith_domain" "acm_certificate_arn")" "$_cert_default" \
      "$(_numbered_prompt "9.3" "ACM certificate management for ${DOMAIN}:")" \
      "Terraform-managed certificate — choose after DNS preparation when ACM status is ISSUED" \
      "Existing certificate — enter its ARN; you manage the certificate and DNS outside this Terraform deployment"

    _selected_cert_management="terraform"
    [[ "$_CHOICE" == "2" ]] && _selected_cert_management="external"
    _existing_cert_management=""
    if [[ "$UPDATE_MODE" == "true" ]]; then
      if [[ -n "$_ex_acm" ]]; then
        _existing_cert_management="external"
      elif _parse_tfvar "langsmith_domain" >/dev/null 2>&1; then
        _existing_cert_management="terraform"
      fi
    fi
    if [[ -n "$_existing_cert_management" && \
          "$_selected_cert_management" != "$_existing_cert_management" ]]; then
      echo ""
      _yellow "WARNING"; printf ": this changes certificate and DNS management.\n"
      if [[ "$_existing_cert_management" == "terraform" ]]; then
        printf "  Terraform may remove its current certificate, hosted zone, and DNS records.\n"
      else
        printf "  Terraform will create a certificate and may also create a hosted zone.\n"
      fi
      _confirm_or_abort "Continue only if you have planned that migration?" "n"
    fi

    if [[ "$_CHOICE" == "2" ]]; then
      while [[ -z "$ACM_ARN" ]]; do
        _ask "$(_choice_arg "acm_certificate_arn")" "$(_numbered_prompt "9.4" "Existing ACM certificate ARN")" "$_ex_acm"
        ACM_ARN="$_REPLY"
        [[ -n "$ACM_ARN" ]] || _red "  ERROR: enter the certificate ARN."
      done
    else
      echo ""
      printf "  %s ${DIM}(skipped: Terraform manages the certificate)${RESET}\n" "$(_numbered_prompt "9.4" "Existing ACM certificate ARN")"
    fi
  else
    printf "\n  ${DIM}ACM needs a certificate for a domain. Enter an existing certificate ARN.${RESET}\n"
    _ask "$(_choice_arg "acm_certificate_arn")" "$(_numbered_prompt "9.4" "Existing ACM certificate ARN" " — blank = continue with HTTP only")" "$_ex_acm"
    ACM_ARN="$_REPLY"
    if [[ -z "$ACM_ARN" ]]; then
      TLS_SOURCE="none"
      printf "  Continuing with HTTP only.\n"
    fi
  fi
fi

# The DNS module is enabled whenever a custom domain is set and no existing ACM certificate ARN is supplied, regardless of the selected TLS mode.
if [[ -n "$DOMAIN" && -z "$ACM_ARN" ]]; then
  _ex_dns_create_zone=$(_existing "dns_create_zone" "true")
  _dns_zone_default=1
  [[ "$_ex_dns_create_zone" == "false" ]] && _dns_zone_default=2

  _ask_choice "$(_choice_arg "dns_create_zone")" "$_dns_zone_default" "$(_numbered_prompt "9.5" "Route 53 hosted zone for ${DOMAIN}:")" \
    "Terraform-managed public hosted zone — exactly matching ${DOMAIN}" \
    "Existing public hosted zone — parent or same-name"

  _selected_dns_create_zone="true"
  [[ "$_CHOICE" == "2" ]] && _selected_dns_create_zone="false"
  if [[ "$UPDATE_MODE" == "true" && -n "$_ex_domain" && -z "$_ex_acm" ]] && \
     [[ "$_selected_dns_create_zone" != "$_ex_dns_create_zone" ]]; then
    echo ""
    _yellow "WARNING"; printf ": this changes who manages the hosted zone.\n"
    printf "  Terraform may create or remove the current zone and its DNS records.\n"
    _confirm_or_abort "Continue only if you have planned the DNS and state migration?" "n"
  fi

  if [[ "$_selected_dns_create_zone" == "false" ]]; then
    DNS_CREATE_ZONE="false"
    echo ""
    printf "  ${DIM}Find the zone ID: aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table${RESET}\n"
    while true; do
      _ask "$(_choice_arg "dns_existing_zone_id")" "$(_numbered_prompt "9.6" "Existing Route 53 hosted zone ID" " — e.g. Z1ABCDEF123456")" "$(_existing "dns_existing_zone_id" "")"
      DNS_EXISTING_ZONE_ID="$_REPLY"
      if [[ "$DNS_EXISTING_ZONE_ID" =~ ^Z[A-Z0-9]{1,31}$ ]]; then
        break
      fi
      _red "  ERROR: enter a valid Route 53 hosted zone ID starting with Z."
      echo ""
    done
  fi
fi

# Let's Encrypt email (HTTP-01 or DNS-01)
if [[ "$TLS_SOURCE" == "letsencrypt" ]] || \
   [[ "$GATEWAY_MODE" == "istio" && "$TLS_MODE" == "1" ]]; then
  echo ""
  _ask "$(_choice_arg "letsencrypt_email")" "$(_numbered_prompt "9.7" "Email for Let's Encrypt expiry notifications")" "$_ex_le_email"
  LE_EMAIL="$_REPLY"
fi

# cert-manager IRSA for DNS-01 (Istio)
if [[ "$GATEWAY_MODE" == "istio" && "$TLS_MODE" == "1" ]]; then
  CREATE_CERT_MANAGER="true"
  echo ""
  printf "  ${DIM}cert-manager uses IRSA (no static credentials) to create DNS TXT records.${RESET}\n"
  printf "  ${DIM}Find your hosted zone: aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table${RESET}\n"
  _ask "$(_choice_arg "cert_manager_hosted_zone_id")" "$(_numbered_prompt "9.8" "Route 53 hosted zone ID" " — e.g. Z1ABCDEF123456")" "$(_existing "cert_manager_hosted_zone_id" "")"
  HOSTED_ZONE_ID="$_REPLY"
  if [[ -z "$HOSTED_ZONE_ID" ]]; then
    _yellow "NOTE"; printf ": set cert_manager_hosted_zone_id in terraform.tfvars before applying.\n"
  fi
fi

if [[ "$UPDATE_MODE" == "true" && "$_ex_cert_manager" == "true" && "$CREATE_CERT_MANAGER" != "true" ]]; then
  echo ""
  _yellow "WARNING"; printf ": this disables the saved Let's Encrypt DNS-01 setup.\n"
  printf "  Terraform will remove its cert-manager IAM role and DNS-01 certificate resources.\n"
  _confirm_or_abort "Continue with this HTTPS change?" "n"
fi

if [[ "$TLS_SOURCE" == "none" && "$PROFILE" == "prod" ]]; then
  echo ""
  _yellow "WARNING"; printf ": Running production without TLS is not recommended.\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 10. Security & Access
# ═══════════════════════════════════════════════════════════════════════════

_section "10. Security & Access"
echo ""

if [[ -z "${ALB_SCHEME:-}" ]]; then
  ALB_SCHEME="internet-facing"
  [[ "$PROFILE" == "dev" ]] && ALB_SCHEME="$(_existing "alb_scheme" "internet-facing")"
fi
ALB_LOGS="$(_existing "alb_access_logs_enabled" "false")"
CREATE_CLOUDTRAIL="$(_existing "create_cloudtrail" "false")"
CREATE_WAF="$(_existing "create_waf" "false")"
CREATE_FIREWALL="$(_existing "create_firewall" "false")"
[[ "$CREATE_VPC" == "false" ]] && CREATE_FIREWALL="false"

if [[ "$PROFILE" == "prod" ]]; then
  if [[ "${ALB_SCHEME:-}" == "internal" ]]; then
    printf "  %s ${DIM}(selected: yes)${RESET} — required because there are no public subnets\n" "$(_numbered_prompt "10.1" "Use an internal ALB?")"
  elif _ask_yn "$(_choice_arg "alb_scheme")" "$(_numbered_prompt "10.1" "Use an internal ALB?" " — private subnets only")" "$([[ "$(_existing "alb_scheme" "internet-facing")" == "internal" ]] && echo "y" || echo "n")"; then
    ALB_SCHEME="internal"
  fi

  echo ""
  _ask_yn "$(_choice_arg "alb_access_logs_enabled")" "$(_numbered_prompt "10.2" "Enable ALB access logs?")" "$([[ "$(_existing "alb_access_logs_enabled" "false")" == "true" ]] && echo "y" || echo "n")" && ALB_LOGS="true" || ALB_LOGS="false"
  echo ""
  _ask_yn "$(_choice_arg "create_cloudtrail")" "$(_numbered_prompt "10.3" "Create CloudTrail?" " — skip if an organization-level trail exists")" "$([[ "$(_existing "create_cloudtrail" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_CLOUDTRAIL="true" || CREATE_CLOUDTRAIL="false"
  echo ""
  _ask_yn "$(_choice_arg "create_waf")" "$(_numbered_prompt "10.4" "Enable WAF on the ALB?" " — ~\$10/month")" "$([[ "$(_existing "create_waf" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_WAF="true" || CREATE_WAF="false"
  echo ""
  if [[ "$CREATE_VPC" == "true" ]]; then
    _ask_yn "$(_choice_arg "create_firewall")" "$(_numbered_prompt "10.5" "Enable AWS Network Firewall?" " — FQDN egress filtering, ~\$0.40/hour")" "$([[ "$(_existing "create_firewall" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_FIREWALL="true" || CREATE_FIREWALL="false"
  else
    printf "  %s ${DIM}(unavailable: requires a Terraform-managed VPC)${RESET}\n" "$(_numbered_prompt "10.5" "AWS Network Firewall")"
  fi
  echo ""
  if [[ "${CREATE_BASTION:-false}" != "true" ]]; then
    _ask_yn "$(_choice_arg "create_bastion")" "$(_numbered_prompt "10.6" "Create a bastion host?")" "$([[ "$(_existing "create_bastion" "false")" == "true" ]] && echo "y" || echo "n")" && CREATE_BASTION="true" || CREATE_BASTION="${CREATE_BASTION:-false}"
  else
    printf "  %s ${DIM}(selected: yes)${RESET} — used for private EKS access\n" "$(_numbered_prompt "10.6" "Create a bastion host?")"
  fi
else
  CREATE_BASTION="$(_existing "create_bastion" "false")"
  printf "  $(_dim "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 11. S3 Data Retention
# ═══════════════════════════════════════════════════════════════════════════

_section "11. S3 Data Retention"
echo ""

S3_TTL="$(_existing "s3_ttl_enabled" "true")"
S3_SHORT="$(_existing "s3_ttl_short_days" "14")"
S3_LONG="$(_existing "s3_ttl_long_days" "400")"

if [[ "$PROFILE" == "prod" ]]; then
  _ask_int "$(_choice_arg "s3_ttl_short_days")" "$(_numbered_prompt "11.1" "S3 short-lived trace TTL (days)")" "$S3_SHORT"; S3_SHORT="$_REPLY"
  _ask_int "$(_choice_arg "s3_ttl_long_days")" "$(_numbered_prompt "11.2" "S3 long-lived trace TTL (days)")" "$S3_LONG"; S3_LONG="$_REPLY"
elif [[ "$UPDATE_MODE" == "true" ]]; then
  printf "  $(_dim "Keeping the current S3 expiry setting and TTL values.")\n"
else
  printf "  $(_dim "Using defaults: short=${S3_SHORT}d, long=${S3_LONG}d. Edit terraform.tfvars to change.")\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 12. LangSmith Pod Sizing
# ═══════════════════════════════════════════════════════════════════════════

_section "12. LangSmith Pod Sizing"

echo ""
printf "  ${DIM}This saved setting controls resource requests, replica counts, and HPA/KEDA autoscaling for LangSmith pods.${RESET}\n"
printf "  ${DIM}It is independent of the QuickStart setup preset in Section 1.${RESET}\n"

_ex_sizing=$(_existing "sizing_profile" "")
_size_options=(
  "minimum — cost parking or CI; minimal resources"
  "dev — development and testing; single-replica baseline"
  "production — real workloads; multi-replica baseline"
  "production-large — high-volume workloads; larger baseline"
)
_size_default=2
[[ "$PROFILE" == "prod" ]] && _size_default=3
_size_recommended="$_size_default"
_size_arg="--default"
_size_offset=0
if [[ "$UPDATE_MODE" == "true" ]]; then
  case "$_ex_sizing" in
    minimum) _size_default=1 ;;
    dev) _size_default=2 ;;
    production) _size_default=3 ;;
    production-large) _size_default=4 ;;
    *)
      _size_options=("keep current sizing" "${_size_options[@]}")
      _size_default=1
      _size_offset=1
      ;;
  esac
  _size_recommended=""
  if [[ "$_size_offset" == "0" ]]; then
    _size_arg="--current"
    _size_options[$((_size_default - 1))]="${_ex_sizing} — keep existing sizing values"
  fi
fi

_ask_choice "$_size_arg" "$_size_default" --recommended "$_size_recommended" "$(_numbered_prompt "12.1" "LangSmith pod sizing:")" "${_size_options[@]}"

case "$((_CHOICE - _size_offset))" in
  0) SIZING="${_ex_sizing:-default}" ;;
  1) SIZING="minimum" ;;
  2) SIZING="dev" ;;
  3) SIZING="production" ;;
  4) SIZING="production-large" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# 13. Add-on Features
# ═══════════════════════════════════════════════════════════════════════════

_section "13. Add-on Features"

echo ""
printf "  ${DIM}Optional add-ons — each requires the matching license entitlement.${RESET}\n"
echo ""

_ex_deploys=$(_existing "enable_deployments" "false")
_ex_fleet=$(_existing "enable_fleet" "false")
_ex_fleet_storage=$(_existing "fleet_storage" "external")
_ex_fleet_external="false"
[[ "$_ex_fleet_storage" == "external" ]] && _ex_fleet_external="true"
_ex_insights_primary=$(_existing "enable_insights" "false")
_ex_standalone_insights=$(_existing "enable_standalone_insights" "false")
_ex_insights_storage=$(_existing "insights_storage" "")
if [[ -z "$_ex_insights_storage" ]]; then
  _ex_insights_storage="in-cluster"
  [[ "$_ex_standalone_insights" == "true" ]] && _ex_insights_storage="external"
fi
_ex_insights_external="false"
[[ "$_ex_insights_storage" == "external" ]] && _ex_insights_external="true"
_ex_insights="false"
[[ "$_ex_insights_primary" == "true" || "$_ex_standalone_insights" == "true" ]] && _ex_insights="true"
_ex_insights_storage_guard="$_ex_insights"
_ex_polly_primary=$(_existing "enable_polly" "false")
_ex_standalone_polly=$(_existing "enable_standalone_polly" "false")
_ex_polly_storage=$(_existing "polly_storage" "")
if [[ -z "$_ex_polly_storage" ]]; then
  _ex_polly_storage="in-cluster"
  [[ "$_ex_standalone_polly" == "true" ]] && _ex_polly_storage="external"
fi
_ex_polly_external="false"
[[ "$_ex_polly_storage" == "external" ]] && _ex_polly_external="true"
_ex_polly="false"
[[ "$_ex_polly_primary" == "true" || "$_ex_standalone_polly" == "true" ]] && _ex_polly="true"
_ex_polly_storage_guard="$_ex_polly"
_ex_sandboxes=$(_existing "enable_sandboxes" "false")

ENABLE_DEPLOYMENTS="false"; ENABLE_FLEET="false"
FLEET_STORAGE="$_ex_fleet_storage"
ENABLE_INSIGHTS="false"; ENABLE_POLLY="false"
INSIGHTS_STORAGE="$_ex_insights_storage"
POLLY_STORAGE="$_ex_polly_storage"
ENABLE_INSIGHTS_PRIMARY="false"; ENABLE_POLLY_PRIMARY="false"
ENABLE_STANDALONE_POLLY="false"; ENABLE_STANDALONE_INSIGHTS="false"
ENABLE_SANDBOXES="false"

_select_feature_storage() {
  local feature="$1" existing_enabled="$2" existing_external="$3" storage_key="$4" question_number="$5"
  local default=1 selected="in-cluster" current="in-cluster"

  if [[ "$existing_enabled" == "true" && "$existing_external" == "true" ]]; then
    default=2
    current="external"
  elif [[ "$existing_enabled" != "true" && "$PG_SOURCE" == "external" && "$REDIS_SOURCE" == "external" ]]; then
    default=2
  fi

  local storage_choice_arg recommended=""
  storage_choice_arg=$(_choice_arg "$storage_key")
  if [[ "$PG_SOURCE" == "external" && "$REDIS_SOURCE" == "external" ]]; then
    recommended=2
  fi
  _ask_choice "$storage_choice_arg" "$default" --recommended "$recommended" "$(_numbered_prompt "$question_number" "$feature storage (Postgres and Redis):")" \
    "In-cluster — dedicated pods with persistent volumes" \
    "External — use the same RDS and ElastiCache as LangSmith; $feature gets a separate Postgres database and Redis index"
  [[ "$_CHOICE" == "2" ]] && selected="external"

  # Helm does not move feature data between database locations during an upgrade.
  if [[ "$UPDATE_MODE" == "true" && "$existing_enabled" == "true" && "$selected" != "$current" ]]; then
    _red "  ERROR: Changing $feature storage requires a separate data migration."
    printf "  Keep the current %s storage here and migrate it separately.\n" "$current"
    exit 1
  fi
  if [[ "$selected" == "external" && ( "$PG_SOURCE" != "external" || "$REDIS_SOURCE" != "external" ) ]]; then
    _red "  ERROR: External $feature storage requires external Postgres and Redis."
    printf "  Re-run QuickStart and choose both external services in Section 5.\n"
    exit 1
  fi

  [[ "$selected" == "external" ]]
}

_ask_yn "$(_choice_arg "enable_deployments")" "$(_numbered_prompt "13.1" "Enable LangSmith Deployments?" " — listener + operator + host-backend")" \
  "$([[ "$_ex_deploys" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_DEPLOYMENTS="true" || ENABLE_DEPLOYMENTS="false"

echo ""
_ask_yn "$(_choice_arg "enable_fleet")" "$(_numbered_prompt "13.2" "Enable Fleet?" " — no-code agents; includes host-backend")" \
  "$([[ "$_ex_fleet" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_FLEET="true" || ENABLE_FLEET="false"

if [[ "$ENABLE_FLEET" == "true" ]]; then
  if _select_feature_storage "Fleet" "$_ex_fleet" "$_ex_fleet_external" "fleet_storage" "13.3"; then
    FLEET_STORAGE="external"
  else
    FLEET_STORAGE="in-cluster"
  fi
fi

echo ""
_ask_yn "$(_choice_arg "enable_polly" "enable_standalone_polly")" "$(_numbered_prompt "13.4" "Enable LangSmith Chat (formerly Polly)?" " — chat for traces, threads, prompts, and experiments")" \
  "$([[ "$_ex_polly" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_POLLY="true" || ENABLE_POLLY="false"

ENABLE_POLLY_PRIMARY="$ENABLE_POLLY"
if [[ "$UPDATE_MODE" == "true" && "$_ex_polly" == "true" && "$ENABLE_POLLY" == "true" ]]; then
  ENABLE_POLLY_PRIMARY="$_ex_polly_primary"
fi

# Existing features keep their storage model.
# Newly enabled features follow the selected storage location; external storage requires both services to be external.
if [[ "$ENABLE_POLLY" == "true" ]]; then
  if _select_feature_storage "LangSmith Chat" "$_ex_polly_storage_guard" "$_ex_polly_external" "polly_storage" "13.5"; then
    POLLY_STORAGE="external"
    ENABLE_STANDALONE_POLLY="true"
  else
    POLLY_STORAGE="in-cluster"
  fi
fi

echo ""
_ask_yn "$(_choice_arg "enable_insights" "enable_standalone_insights")" "$(_numbered_prompt "13.6" "Enable Insights?" " — AI-powered trace analysis for patterns and failure modes")" \
  "$([[ "$_ex_insights" == "true" ]] && echo "y" || echo "n")" \
  && ENABLE_INSIGHTS="true" || ENABLE_INSIGHTS="false"

ENABLE_INSIGHTS_PRIMARY="$ENABLE_INSIGHTS"
if [[ "$UPDATE_MODE" == "true" && "$_ex_insights" == "true" && "$ENABLE_INSIGHTS" == "true" ]]; then
  ENABLE_INSIGHTS_PRIMARY="$_ex_insights_primary"
fi

if [[ "$ENABLE_INSIGHTS" == "true" ]]; then
  if _select_feature_storage "Insights" "$_ex_insights_storage_guard" "$_ex_insights_external" "insights_storage" "13.7"; then
    INSIGHTS_STORAGE="external"
    ENABLE_STANDALONE_INSIGHTS="true"
  else
    INSIGHTS_STORAGE="in-cluster"
  fi
fi

echo ""
printf "  ${DIM}Sandboxes run untrusted code on dedicated EC2 nodes and create a dedicated${RESET}\n"
printf "  ${DIM}external Redis instance for JuiceFS metadata. They also require a Linux${RESET}\n"
printf "  ${DIM}KVM-compatible host. The matching Sandbox image is selected during deployment.${RESET}\n"
echo ""
if _ask_yn "$(_choice_arg "enable_sandboxes")" "$(_numbered_prompt "13.8" "Enable LangSmith Sandboxes?")" \
  "$([[ "$_ex_sandboxes" == "true" ]] && echo "y" || echo "n")"; then
  ENABLE_SANDBOXES="true"
fi

_summary_section() {
  printf "\n  ${BOLD}%s${RESET}\n" "$1"
}

_summary_row() {
  printf "    %-38s %s\n" "$1" "$2"
}

_summary_bool_row() {
  local state="disabled"; [[ "$2" == "true" ]] && state="enabled"
  _summary_row "$1" "$state"
}

_show_summary() {
  _summary_section "1. Setup Preset"
  _summary_row "Preset:" "$PROFILE"

  _summary_section "2. Deployment Details"
  _summary_row "Name prefix:" "$NAME_PREFIX"
  _summary_row "Environment:" "$ENVIRONMENT"
  _summary_row "AWS region:" "$REGION"
  _summary_row "Owner:" "$OWNER"
  [[ -n "$COST_CENTER" ]] && _summary_row "Cost center:" "$COST_CENTER"

  _summary_section "3. Networking"
  _summary_row "VPC:" "$([[ "$CREATE_VPC" == "true" ]] && echo "Terraform-managed" || echo "existing ($VPC_ID)")"
  if [[ "$CREATE_VPC" == "false" ]]; then
    _summary_row "VPC CIDR:" "$VPC_CIDR"
    _summary_row "Private subnets:" "$PRIVATE_SUBNETS"
    _summary_row "Public subnets:" "${PUBLIC_SUBNETS:-none}"
  fi

  _summary_section "4. EKS Cluster"
  _summary_row "Kubernetes version:" "$EKS_VERSION"
  local eks_api_summary="public"
  if [[ "$EKS_PUBLIC" != "true" ]]; then
    eks_api_summary="private"
    [[ "$CREATE_BASTION" == "true" ]] && eks_api_summary="private + bastion"
  fi
  _summary_row "EKS API:" "$eks_api_summary"
  [[ "$EKS_PUBLIC" == "true" && -n "$EKS_PUBLIC_CIDRS" ]] && _summary_row "EKS public CIDRs:" "$EKS_PUBLIC_CIDRS"
  _summary_row "Node instance type:" "$NODE_INSTANCE"
  _summary_row "Node minimum:" "$NODE_MIN"
  _summary_row "Node maximum:" "$NODE_MAX"

  _summary_section "5. Backend Services"
  _summary_row "Postgres:" "$PG_SOURCE"
  if [[ "$PG_SOURCE" == "external" ]]; then
    _summary_row "RDS instance type:" "$PG_INSTANCE"
    _summary_row "RDS storage:" "${PG_STORAGE}-${PG_MAX_STORAGE} GB"
  fi
  _summary_row "Redis:" "$REDIS_SOURCE"
  [[ "$REDIS_SOURCE" == "external" ]] && _summary_row "ElastiCache instance type:" "$REDIS_INSTANCE"

  _summary_section "6. ClickHouse"
  _summary_row "ClickHouse:" "$CH_SOURCE"

  _summary_section "7. SmithDB"
  _summary_bool_row "SmithDB:" "$ENABLE_SMITHDB"
  if [[ "$ENABLE_SMITHDB" == "true" ]]; then
    _summary_bool_row "  Ingestion:" "$SMITHDB_INGESTION"
    _summary_bool_row "  Migration:" "$SMITHDB_MIGRATION"
    _summary_bool_row "  Query:" "$SMITHDB_QUERY"
  fi

  _summary_section "8. Traffic Routing"
  _summary_row "Gateway mode:" "$GATEWAY_MODE"

  _summary_section "9. Domain & HTTPS"
  _summary_row "Custom domain:" "${DOMAIN:-load balancer hostname}"
  _summary_row "HTTPS:" "$([[ "$CREATE_CERT_MANAGER" == "true" ]] && echo "Let's Encrypt DNS-01 (Route 53)" || echo "$TLS_SOURCE")"
  if [[ -n "$ACM_ARN" ]]; then
    _summary_row "ACM certificate:" "external ($ACM_ARN)"
  elif [[ -n "$DOMAIN" ]]; then
    _summary_row "ACM certificate:" "Terraform-managed"
  fi
  if [[ -n "$DOMAIN" && -z "$ACM_ARN" ]]; then
    _summary_row "Route 53 zone:" \
      "$([[ "$DNS_CREATE_ZONE" == "true" ]] && echo "Terraform-managed ($DOMAIN)" || echo "existing ($DNS_EXISTING_ZONE_ID)")"
  fi

  _summary_section "10. Security & Access"
  _summary_row "ALB scheme:" "$ALB_SCHEME"
  _summary_bool_row "ALB access logs:" "$ALB_LOGS"
  _summary_bool_row "CloudTrail:" "$CREATE_CLOUDTRAIL"
  _summary_bool_row "WAF:" "$CREATE_WAF"
  _summary_bool_row "Network Firewall:" "$CREATE_FIREWALL"
  _summary_bool_row "Bastion:" "$CREATE_BASTION"

  _summary_section "11. S3 Data Retention"
  _summary_bool_row "S3 TTL:" "$S3_TTL"
  _summary_row "Short-lived trace TTL:" "${S3_SHORT} days"
  _summary_row "Long-lived trace TTL:" "${S3_LONG} days"

  _summary_section "12. LangSmith Pod Sizing"
  _summary_row "Pod sizing:" "$SIZING"

  _summary_section "13. Add-on Features"
  _summary_bool_row "LangSmith Deployments:" "$ENABLE_DEPLOYMENTS"
  _summary_bool_row "Fleet:" "$ENABLE_FLEET"
  [[ "$ENABLE_FLEET" == "true" ]] && _summary_row "Fleet storage:" "$FLEET_STORAGE"
  _summary_bool_row "LangSmith Chat (formerly Polly):" "$ENABLE_POLLY"
  [[ "$ENABLE_POLLY" == "true" ]] && _summary_row "LangSmith Chat storage:" "$POLLY_STORAGE"
  _summary_bool_row "Insights:" "$ENABLE_INSIGHTS"
  [[ "$ENABLE_INSIGHTS" == "true" ]] && _summary_row "Insights storage:" "$INSIGHTS_STORAGE"
  _summary_bool_row "Sandboxes:" "$ENABLE_SANDBOXES"
}

_section "Review your configuration"
_show_summary
echo ""
_confirm_or_abort "Write $OUTPUT_DISPLAY?" "y"

# ═══════════════════════════════════════════════════════════════════════════
# Write terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

_section "Generating terraform.tfvars"

if [[ -f "$OUTPUT" ]]; then
  echo ""
  cp -p "$OUTPUT" "${OUTPUT}.backup"
  printf "  $(_green "✔")  Backed up existing file to: $(_bold "$OUTPUT_BACKUP_DISPLAY")\n"
fi

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
# QuickStart setup preset: ${PROFILE}
# Re-run: make quickstart  (will pre-fill current values from this file)

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
postgres_source = "${PG_SOURCE}"
redis_source    = "${REDIS_SOURCE}"
TFVARS

if [[ "$PG_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# PostgreSQL (RDS)
postgres_instance_type       = "${PG_INSTANCE}"
postgres_storage_gb          = ${PG_STORAGE}
postgres_max_storage_gb      = ${PG_MAX_STORAGE}
postgres_deletion_protection = ${PG_DELETION_PROTECTION}
postgres_skip_final_snapshot = ${PG_SKIP_FINAL_SNAPSHOT}
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
# ClickHouse
#------------------------------------------------------------------------------
clickhouse_source = "${CH_SOURCE}"

#------------------------------------------------------------------------------
# SmithDB
#------------------------------------------------------------------------------
enable_smithdb                           = ${ENABLE_SMITHDB}
smithdb_ingestion_enabled                = ${SMITHDB_INGESTION}
smithdb_migration_enabled                = ${SMITHDB_MIGRATION}
smithdb_query_enabled                    = ${SMITHDB_QUERY}
smithdb_metastore_deletion_protection    = ${SMITHDB_DELETION_PROTECTION}
smithdb_metastore_skip_final_snapshot    = ${SMITHDB_SKIP_FINAL_SNAPSHOT}
smithdb_s3_force_destroy                 = ${SMITHDB_S3_FORCE_DESTROY}
TFVARS

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Traffic Routing
# Only one of enable_nginx_ingress / enable_envoy_gateway / enable_istio_gateway should be true at a time.
#------------------------------------------------------------------------------
enable_nginx_ingress = ${ENABLE_NGINX}
enable_envoy_gateway = ${ENABLE_ENVOY}
enable_istio_gateway = ${ENABLE_ISTIO}
TFVARS

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Domain & HTTPS
#------------------------------------------------------------------------------
tls_certificate_source = "${TLS_SOURCE}"
TFVARS

[[ -n "$ACM_ARN" ]]  && echo "acm_certificate_arn    = \"${ACM_ARN}\""  >> "$OUTPUT"
[[ -n "$LE_EMAIL" ]] && echo "letsencrypt_email      = \"${LE_EMAIL}\""  >> "$OUTPUT"
[[ -n "$DOMAIN" ]]   && echo "langsmith_domain       = \"${DOMAIN}\""    >> "$OUTPUT"

if [[ -n "$DOMAIN" && -z "$ACM_ARN" ]]; then
  echo "dns_create_zone        = ${DNS_CREATE_ZONE}" >> "$OUTPUT"
  if [[ "$DNS_CREATE_ZONE" == "false" ]]; then
    echo "dns_existing_zone_id   = \"${DNS_EXISTING_ZONE_ID}\"" >> "$OUTPUT"
  fi
fi

if [[ "$CREATE_CERT_MANAGER" == "true" ]]; then
  cat >> "$OUTPUT" << TFVARS

# cert-manager IRSA for Let's Encrypt DNS-01 (Istio + Route 53)
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
# Security & Access
#------------------------------------------------------------------------------
alb_scheme              = "${ALB_SCHEME}"
alb_access_logs_enabled = ${ALB_LOGS}
create_cloudtrail       = ${CREATE_CLOUDTRAIL}
create_waf              = ${CREATE_WAF}
create_firewall         = ${CREATE_FIREWALL}
create_bastion          = ${CREATE_BASTION}

#------------------------------------------------------------------------------
# S3 Data Retention
#------------------------------------------------------------------------------
s3_ttl_enabled    = ${S3_TTL}
s3_ttl_short_days = ${S3_SHORT}
s3_ttl_long_days  = ${S3_LONG}

#------------------------------------------------------------------------------
# Namespace
#------------------------------------------------------------------------------
langsmith_namespace = "langsmith"

#------------------------------------------------------------------------------
# LangSmith Pod Sizing
# Controls resource requests, replica counts, and HPA/KEDA autoscaling.
# Docs: https://docs.langchain.com/langsmith/self-host-scale
#------------------------------------------------------------------------------
sizing_profile = "${SIZING}"

#------------------------------------------------------------------------------
# Add-on Features
# Set to true to enable add-ons. Each requires a matching license entitlement.
# deploy.sh reads these flags to select the right Helm values overlays.
#------------------------------------------------------------------------------
enable_deployments   = ${ENABLE_DEPLOYMENTS}
enable_fleet         = ${ENABLE_FLEET}
fleet_storage        = "${FLEET_STORAGE}"
enable_insights      = ${ENABLE_INSIGHTS_PRIMARY}
insights_storage     = "${INSIGHTS_STORAGE}"
enable_polly         = ${ENABLE_POLLY_PRIMARY}
polly_storage        = "${POLLY_STORAGE}"
enable_standalone_polly = ${ENABLE_STANDALONE_POLLY}
enable_standalone_insights = ${ENABLE_STANDALONE_INSIGHTS}
enable_sandboxes = ${ENABLE_SANDBOXES}
TFVARS

if command -v terraform >/dev/null 2>&1; then
  if ! terraform fmt "$OUTPUT" >/dev/null; then
    _red "ERROR"; printf ": %s was written, but Terraform could not format it.\n" "$OUTPUT_DISPLAY"
    printf "  Fix the errors above, then run from modules/aws: terraform fmt infra/terraform.tfvars\n"
    exit 1
  fi
else
  _yellow "WARNING"; printf ": Terraform is not installed, so %s was not formatted.\n" "$OUTPUT_DISPLAY"
  printf "  Run from modules/aws: terraform fmt infra/terraform.tfvars\n"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Next Steps
# ═══════════════════════════════════════════════════════════════════════════

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT_DISPLAY") ${DIM}(from project root)${RESET}\n"

echo ""
printf "${BOLD}── Next Steps ──${RESET}\n"
echo ""
printf "  1. Review the generated file:\n"
printf "     ${CYAN}cat infra/terraform.tfvars${RESET}\n"
if [[ "$UPDATE_MODE" == "true" ]]; then
  echo ""
  printf "     Compare it with the backup:\n"
  printf "     ${CYAN}diff -u infra/terraform.tfvars.backup infra/terraform.tfvars${RESET}\n"
  printf "     ${DIM}Restore any hand-written settings you still need before running make plan.${RESET}\n"
fi
echo ""
printf "  2. Set up secrets (auto-generates passwords, stores in SSM):\n"
printf "     ${CYAN}source infra/scripts/setup-env.sh${RESET}\n"
echo ""
printf "  3. Deploy infrastructure:\n"
printf "     ${CYAN}make init && make plan${RESET}\n"
printf "     ${CYAN}make apply${RESET}\n"
echo ""

if [[ -n "$DOMAIN" && -z "$ACM_ARN" && "$TLS_SOURCE" == "none" && "$CREATE_CERT_MANAGER" != "true" ]]; then
  printf "  ${DIM}This apply prepares Route 53 and requests the ACM certificate without${RESET}\n"
  printf "  ${DIM}enabling HTTPS. Complete DNS delegation if needed, wait for the certificate${RESET}\n"
  printf "  ${DIM}to become ISSUED, then re-run make quickstart and choose ACM.${RESET}\n"
  echo ""
fi

printf "  4. Deploy LangSmith:\n"
printf "     ${CYAN}make init-values && make deploy${RESET}\n"

if [[ "$GATEWAY_MODE" == "istio" ]]; then
  echo ""
  printf "  ${DIM}Note: terraform apply installs Istio and creates the Gateway/TargetGroupBinding.${RESET}\n"
  printf "  ${DIM}No separate controller install step needed — handled by k8s-bootstrap.${RESET}\n"
  if [[ "$CREATE_CERT_MANAGER" == "true" ]]; then
    printf "  ${DIM}Terraform also installs cert-manager and configures DNS-01 through Route 53.${RESET}\n"
  fi
elif [[ "$GATEWAY_MODE" == "nginx" ]]; then
  echo ""
  printf "  ${DIM}Note: terraform apply installs NGINX ingress-nginx chart and creates a${RESET}\n"
  printf "  ${DIM}TargetGroupBinding to wire the ALB target group to the NGINX controller.${RESET}\n"
  printf "  ${DIM}No separate controller install step needed — handled by k8s-bootstrap.${RESET}\n"
elif [[ "$GATEWAY_MODE" == "envoy" ]]; then
  echo ""
  printf "  ${DIM}Note: terraform apply installs Envoy Gateway and creates the GatewayClass/Gateway.${RESET}\n"
  printf "  ${DIM}No separate controller install step needed — handled by k8s-bootstrap.${RESET}\n"
  if [[ -z "$DOMAIN" ]]; then
    echo ""
    printf "  ${DIM}No custom domain was set. The external endpoint is the Terraform-managed ALB.${RESET}\n"
    printf "     ${CYAN}terraform -chdir=infra output -raw alb_dns_name${RESET}\n"
  fi
fi

if [[ "$ENABLE_SMITHDB" == "true" ]]; then
  echo ""
  printf "  ${DIM}SmithDB uses the repository's pinned 0.16.x chart line.${RESET}\n"
fi

echo ""
printf "  ${DIM}To change options later, re-run:  make quickstart${RESET}\n"
echo ""
