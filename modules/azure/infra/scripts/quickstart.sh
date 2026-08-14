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
# Normalize so the paths shown to the user are plain, not infra/scripts/../...
INFRA_DIR="$(cd "$INFRA_DIR" && pwd)"
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
  # Usage: _ask_choice [--default N] "prompt" "opt1" "opt2" ...
  local default=""
  if [[ "${1:-}" == "--default" ]]; then
    default="$2"; shift 2
  fi
  local prompt="$1"
  shift
  local options=("$@")
  echo ""
  printf "  ${BOLD}%s${RESET}\n" "$prompt"
  local i=1
  for opt in "${options[@]}"; do
    if [[ -n "$default" && "$i" == "$default" ]]; then
      printf "    %d) %s ${DIM}(current)${RESET}\n" "$i" "$opt"
    else
      printf "    %d) %s\n" "$i" "$opt"
    fi
    ((i++))
  done
  while true; do
    if [[ -n "$default" ]]; then
      printf "  Choice ${DIM}[%s]${RESET}: " "$default"
    else
      printf "  Choice: "
    fi
    read -r _CHOICE
    _CHOICE="${_CHOICE:-$default}"
    if [[ "$_CHOICE" =~ ^[0-9]+$ ]] && (( _CHOICE >= 1 && _CHOICE <= ${#options[@]} )); then
      break
    fi
    _red "  ERROR: enter a number between 1 and ${#options[@]}. Try again."
  done
}

# Echo the 1-based index of $1 among the remaining args (empty if absent).
# Used to pre-select the current answer when a section is re-entered.
_index_of() {
  local needle="$1"; shift
  local i=1 x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && { echo "$i"; return 0; }
    i=$((i + 1))
  done
}

# Echo "y" or "n" for use as an _ask_yn default.
_yn_default() {
  [[ "$1" == "true" ]] && echo "y" || echo "n"
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

# Compose the resource names Terraform will derive, from answers already given.
# Mirror of the naming locals in infra/main.tf — keep the two in step. The
# wizard knows every input the derivation needs, so a name that busts an Azure
# ceiling can be caught at the prompt instead of at preflight or at plan.
_derive_names() {
  local suffix="" uniq="" base hash
  [[ -n "$NAME_PREFIX" ]] && suffix="-${NAME_PREFIX}"
  if [[ "$UNIQUE_NAMES" == "true" ]]; then
    base="ls"
    if command -v shasum &>/dev/null; then
      hash=$(printf '%s' "${SUBSCRIPTION_ID}${suffix}" | shasum -a 256 | cut -c1-6)
    else
      hash=$(printf '%s' "${SUBSCRIPTION_ID}${suffix}" | sha256sum | cut -c1-6)
    fi
    uniq="-${hash}"
  else
    base="langsmith"
  fi
  _RG_NAME="${base}-rg${suffix}"
  _AKS_NAME="${base}-aks${suffix}"
  _KV_NAME="${base}-kv${suffix}${uniq}"
  _PG_NAME="${base}-postgres${suffix}${uniq}"
  _REDIS_NAME="${base}-redis${suffix}${uniq}"
  # The blob module strips the hyphens, so the 24-char limit applies to the
  # stripped form and that is also the name Azure ends up showing.
  _BLOB_NAME="${base}blob${suffix}${uniq}"
  _BLOB_NAME="${_BLOB_NAME//-/}"
  # Not derived from name_base — the workspace name predates it and renaming a
  # Log Analytics workspace destroys the logs in it.
  _LAW_NAME="langsmith-logs${suffix}"
}

# One line per derived name that busts its Azure ceiling. The count is the
# number that says how much to cut, so print it rather than just the rule.
_name_length_errors() {
  local spec label name max
  for spec in "Storage account:${_BLOB_NAME}:24" \
    "Key Vault:${_KV_NAME}:24" \
    "Postgres:${_PG_NAME}:63" \
    "Redis:${_REDIS_NAME}:60"; do
    label="${spec%%:*}"
    name="${spec#*:}"
    max="${name##*:}"
    name="${name%:*}"
    if (( ${#name} > max )); then
      printf '%s name "%s" is %d chars; Azure allows at most %d.\n' \
        "$label" "$name" "${#name}" "$max"
    fi
  done
  return 0
}

# ── Resume state ──────────────────────────────────────────────────────────────
# Answers are checkpointed after every completed section so an exit (Ctrl-C,
# `q`, a dropped SSH session) never costs more than the section in progress.
# Contains configuration only — secrets are handled by setup-env.sh.

STATE_FILE="$INFRA_DIR/.quickstart-state"

_STATE_KEYS="SECTION ANSWERED PROFILE SUBSCRIPTION_ID NAME_PREFIX LOCATION OWNER
ENVIRONMENT COST_CENTER CREATE_VNET VNET_ID AKS_SUBNET_ID POSTGRES_SUBNET_ID REDIS_SUBNET_ID
AKS_SUBNET_CIDR_LINE POSTGRES_SUBNET_CIDR_LINE REDIS_SUBNET_CIDR_LINE
AKS_SERVICE_CIDR AGIC_SUBNET_ID BASTION_SUBNET_ID
NODE_VM_SIZE NODE_MIN NODE_MAX NODE_MAX_PODS AKS_DELETION_PROTECTION INGRESS_CONTROLLER
ISTIO_ADDON_REVISION AGW_SKU_TIER TLS_SOURCE DNS_LABEL LANGSMITH_DOMAIN LE_EMAIL
CREATE_DNS_ZONE PG_SOURCE REDIS_SOURCE CH_SOURCE PG_ADMIN_USER PG_DB_NAME
PG_DELETION_PROTECTION AMR_SKU REDIS_HA KV_PURGE_PROTECTION SIZING_PROFILE UNIQUE_NAMES
BLOB_TTL_ENABLED BLOB_TTL_SHORT_DAYS BLOB_TTL_LONG_DAYS
CREATE_WAF CREATE_DIAGNOSTICS CREATE_BASTION
ENABLE_DEPLOYMENTS ENABLE_AGENT_BUILDER ENABLE_INSIGHTS ENABLE_POLLY
PRESERVE_UNKNOWN"

# Sections the user has actually been through. Profile-driven defaults apply
# only to sections still unanswered, so going back to switch dev→prod never
# overwrites a value you chose yourself.
ANSWERED=""
_answered()      { [[ " $ANSWERED " == *" $1 "* ]]; }
_mark_answered() { _answered "$1" || ANSWERED="${ANSWERED}${ANSWERED:+ }$1"; }

_save_state() {
  local k
  ( umask 077; : > "$STATE_FILE" )
  for k in $_STATE_KEYS; do
    printf '%s=%s\n' "$k" "${!k-}"
  done >> "$STATE_FILE"
}

# Read the state file back WITHOUT sourcing it: split each line on the first
# '=', accept the key only if it is on the whitelist above, then assign the
# value by reference. eval never parses the value — an assignment RHS is not
# word-split, glob-expanded, or re-evaluated — so a hostile state file can at
# worst set a whitelisted wizard variable to a literal string.
_load_state() {
  local line key val k found
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    # shellcheck disable=SC2034  # val is read by the eval below
    val="${line#*=}"
    found=false
    for k in $_STATE_KEYS; do
      [[ "$k" == "$key" ]] && { found=true; break; }
    done
    [[ "$found" == "true" ]] && eval "$key=\$val"
  done < "$STATE_FILE"
}

# Read one quoted scalar out of an existing terraform.tfvars, preserving spaces
# inside the value (_common.sh's _parse_tfvar strips them). A trailing comment
# is allowed: the writer puts one on amr_sku, and without this that line is the
# one setting a re-run cannot read back.
_tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\"[[:space:]]*\(#.*\)\{0,1\}\$/\1/p" "$OUTPUT" 2>/dev/null | head -1
}

# Read a list-valued tfvar back as its whole assignment line, which is the form
# the writer carries it in (aks_subnet_address_prefix = ["10.0.0.0/19"]).
_tfvar_line() {
  sed -n "s/^[[:space:]]*\($1[[:space:]]*=[[:space:]]*\[.*\]\)[[:space:]]*\$/\1/p" "$OUTPUT" 2>/dev/null | head -1
}

# Whether a key is assigned at all, which _tfvar cannot report: an absent key
# and one assigned "" both come back as the empty string.
_tfvar_set() {
  grep -qE "^[[:space:]]*$1[[:space:]]*=" "$OUTPUT" 2>/dev/null
}

# Seed the wizard from a terraform.tfvars written by an earlier run, so a
# re-run edits the existing config instead of retyping it from scratch.
_load_tfvars() {
  local v _TF_VAL
  # The profile is not a tfvar — it is stamped in the header comment. Without it
  # everything derived from the profile (deletion protection, Key Vault purge
  # protection, the security add-ons) silently resets to dev values on save.
  _TF_VAL=$(sed -n 's/^# Profile:[[:space:]]*\([a-z]*\).*/\1/p' "$OUTPUT" | head -1)
  [[ "$_TF_VAL" == "prod" || "$_TF_VAL" == "dev" ]] && PROFILE="$_TF_VAL"

  # name_prefix is read on its own because it is the one key whose empty value
  # is an answer: "" is the "none" choice, and _tfvar reports it exactly like an
  # absent key. Falling through to the "dev" initializer there would regenerate
  # a tfvars naming a different set of resources than the one this deployment
  # already owns, which Terraform executes as destroy-and-recreate. `identifier`
  # is the retired spelling, checked second so the current key wins when a
  # tfvars carries both. Same back-compat as _common.sh's _name_prefix.
  for v in name_prefix identifier; do
    if _tfvar_set "$v"; then
      _TF_VAL=$(_tfvar "$v")
      NAME_PREFIX="${_TF_VAL#-}"
      break
    fi
  done

  for v in subscription_id location owner environment cost_center \
           default_node_pool_vm_size ingress_controller istio_addon_revision \
           agw_sku_tier tls_certificate_source dns_label langsmith_domain \
           letsencrypt_email postgres_source redis_source clickhouse_source \
           sizing_profile postgres_admin_username postgres_database_name \
           amr_sku; do
    _TF_VAL=$(_tfvar "$v")
    [[ -z "$_TF_VAL" ]] && continue
    case "$v" in
      subscription_id)           SUBSCRIPTION_ID="$_TF_VAL" ;;
      location)                  LOCATION="$_TF_VAL" ;;
      owner)                     OWNER="$_TF_VAL" ;;
      environment)               ENVIRONMENT="$_TF_VAL" ;;
      cost_center)               COST_CENTER="$_TF_VAL" ;;
      default_node_pool_vm_size) NODE_VM_SIZE="$_TF_VAL" ;;
      ingress_controller)        INGRESS_CONTROLLER="$_TF_VAL" ;;
      istio_addon_revision)      ISTIO_ADDON_REVISION="$_TF_VAL" ;;
      agw_sku_tier)              AGW_SKU_TIER="$_TF_VAL" ;;
      tls_certificate_source)    TLS_SOURCE="$_TF_VAL" ;;
      dns_label)                 DNS_LABEL="$_TF_VAL" ;;
      langsmith_domain)          LANGSMITH_DOMAIN="$_TF_VAL" ;;
      letsencrypt_email)         LE_EMAIL="$_TF_VAL" ;;
      postgres_source)           PG_SOURCE="$_TF_VAL" ;;
      redis_source)              REDIS_SOURCE="$_TF_VAL" ;;
      clickhouse_source)         CH_SOURCE="$_TF_VAL" ;;
      sizing_profile)            SIZING_PROFILE="$_TF_VAL" ;;
      postgres_admin_username)   PG_ADMIN_USER="$_TF_VAL" ;;
      postgres_database_name)    PG_DB_NAME="$_TF_VAL" ;;
      amr_sku)                   AMR_SKU="$_TF_VAL" ;;
    esac
  done
  # Numeric + boolean tfvars are unquoted, so _tfvar (quoted-only) misses them.
  _TF_VAL=$(_parse_tfvar default_node_pool_min_count) && NODE_MIN="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar default_node_pool_max_count) && NODE_MAX="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar default_node_pool_max_pods)  && NODE_MAX_PODS="$_TF_VAL"
  # The wizard never asks about the feature flags — the generated file says to
  # edit them there and re-run `make init-values`. Reading them back is what
  # makes that true: the writer emits all four every time, so an unloaded flag
  # is written false and silently turns off a pass that is already deployed.
  _TF_VAL=$(_parse_tfvar enable_deployments)   && ENABLE_DEPLOYMENTS="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar enable_agent_builder) && ENABLE_AGENT_BUILDER="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar enable_insights)      && ENABLE_INSIGHTS="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar enable_polly)         && ENABLE_POLLY="$_TF_VAL"
  # Absent means an existing deployment predating the hash, or one that opted
  # out. Either way it stays off — the writer must not turn it on underneath a
  # deployment whose resources are already named.
  UNIQUE_NAMES="false"
  _TF_VAL=$(_parse_tfvar unique_resource_names)       && UNIQUE_NAMES="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_vnet)                 && CREATE_VNET="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar keyvault_purge_protection)   && KV_PURGE_PROTECTION="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar blob_ttl_enabled)            && BLOB_TTL_ENABLED="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar blob_ttl_short_days)         && BLOB_TTL_SHORT_DAYS="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar blob_ttl_long_days)          && BLOB_TTL_LONG_DAYS="$_TF_VAL"
  # Written only when redis_source = "external", so an absent key means either
  # in-cluster Redis or a tfvars predating the variable. false is right for both.
  _TF_VAL=$(_parse_tfvar redis_high_availability)     && REDIS_HA="$_TF_VAL"
  # The add-ons are written only when true, so an absent key is genuinely false.
  _TF_VAL=$(_parse_tfvar create_waf)                  && CREATE_WAF="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_diagnostics)          && CREATE_DIAGNOSTICS="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_bastion)              && CREATE_BASTION="$_TF_VAL"
  [[ "$CREATE_VNET" == "false" ]] && {
    VNET_ID=$(_tfvar vnet_id)
    AKS_SUBNET_ID=$(_tfvar aks_subnet_id)
    POSTGRES_SUBNET_ID=$(_tfvar postgres_subnet_id)
    REDIS_SUBNET_ID=$(_tfvar redis_subnet_id)
    # A subnet with no ID was carved by Terraform, so its prefix has to come
    # back too. Dropping it would silently re-default the CIDR and move the
    # subnet on the next apply.
    AKS_SUBNET_CIDR_LINE=$(_tfvar_line aks_subnet_address_prefix)
    POSTGRES_SUBNET_CIDR_LINE=$(_tfvar_line postgres_subnet_address_prefix)
    REDIS_SUBNET_CIDR_LINE=$(_tfvar_line redis_subnet_address_prefix)
    # Required on this path, and the variable default is only safe against the
    # VNet Terraform builds. Dropping it on a re-run would put back the
    # 10.0.64.0/20 that can sit inside the operator's own address space.
    AKS_SERVICE_CIDR=$(_tfvar aks_service_cidr)
    # AGIC and the bastion have no carve path inside a VNet Terraform does not
    # own, so their IDs are required rather than optional here. Dropping either
    # on a re-run writes a tfvars that fails its own precondition at plan.
    AGIC_SUBNET_ID=$(_tfvar agic_subnet_id)
    BASTION_SUBNET_ID=$(_tfvar bastion_subnet_id)
  }
  return 0
}

# Any exit that still leaves a checkpoint behind — Ctrl-C, `q`, a closed
# terminal, an aborted command — tells the user how to pick it back up. A
# completed run deletes the checkpoint first, so this stays silent on success.
_on_exit() {
  [[ -f "$STATE_FILE" ]] || return 0
  echo ""
  printf "  Answers through the last completed section were saved to\n"
  printf "  $(_bold "$STATE_FILE")\n"
  printf "  Resume where you left off: ${CYAN}make quickstart${RESET}\n"
  echo ""
}
trap _on_exit EXIT

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

  _hint "Changing this later leaves answers you have already given untouched —"
  _hint "it only affects the defaults of sections you have not filled in yet."

  local profile_choice=""
  _answered 1 && profile_choice="$(_index_of "$PROFILE" dev prod)"
  _ask_choice --default "$profile_choice" \
    "What kind of deployment is this?" \
    "Dev / POC  — minimal resources, in-cluster services OK" \
    "Production — HA resources, external managed services"

  PROFILE="dev"
  [[ "$_CHOICE" == "2" ]] && PROFILE="prod"
  echo ""
  printf "  Profile: $(_green "$PROFILE")\n"
}

# -- 2. Subscription & Naming ------------------------------------------------
SUBSCRIPTION_ID=""
NAME_PREFIX="dev"
LOCATION="eastus"
# True for a new deployment, so the globally-unique names carry the hash. An
# existing tfvars overrides this on the way in: turning it on after the fact
# renames Postgres, Redis, Storage and Key Vault, which Terraform executes as
# destroy-and-recreate.
UNIQUE_NAMES="true"
# Left blank on purpose. The module omits the tag entirely when it is empty, and
# an unanswered "platform-team" is a worse answer than no tag at all.
OWNER=""
ENVIRONMENT=""
COST_CENTER=""

_run_section_2() {
  _section "2. Subscription & Naming"
  _hint "The deployment name is appended to every Azure resource name (RG, AKS, KV, blob...)"
  _hint "and is the default 'environment' tag. Write it without a hyphen — we add the separator."
  _hint "Example: prod → ls-rg-prod, ls-aks-prod, ls-kv-prod-<hash>"
  _hint "Postgres, Redis, Storage and Key Vault names must be unique across all of Azure,"
  _hint "so those four get a hash of your subscription appended. Keep it under ~12 chars."
  _hint "Changing it later creates entirely new resources — choose something stable."

  # Defaults come from the current values, so a resumed or re-entered section
  # prefills what you answered before. Profile-driven defaults apply only when
  # the field is still untouched, so switching profiles never eats an edit.
  AUTO_SUB="$SUBSCRIPTION_ID"
  if [[ -z "$AUTO_SUB" ]] && command -v az &>/dev/null; then
    AUTO_SUB=$(az account show --query id --output tsv 2>/dev/null) || AUTO_SUB=""
  fi

  while true; do
    if [[ -n "$AUTO_SUB" ]]; then
      _ask "Azure subscription ID" "$AUTO_SUB"
    else
      _ask "Azure subscription ID (az account show --query id -o tsv)" ""
    fi
    SUBSCRIPTION_ID="$_REPLY"
    if [[ "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      break
    fi
    _red "  ERROR: must be a GUID, not a subscription name or a row number from 'az account list -o table'."
  done

  # A resumed no-suffix deployment carries NAME_PREFIX="", and _ask substitutes
  # the default on a blank reply, so an empty default would make Enter fail the
  # regex below and re-prompt forever. Offer the sentinel back instead.
  local name_default="${NAME_PREFIX:-none}"
  local name_errors="" name_error_line
  [[ "$PROFILE" == "prod" ]] && ! _answered 2 && name_default="prod"
  while true; do
    _ask "Deployment name, or \"none\" for no suffix (lowercase, e.g. prod, staging, myco)" "$name_default"
    NAME_PREFIX="${_REPLY#-}" # tolerate a pasted leading hyphen from an older tfvars
    # "none" is the only route to the empty name_prefix variables.tf allows,
    # since _ask substitutes the default on a blank reply.
    if [[ "$NAME_PREFIX" == "none" ]]; then
      NAME_PREFIX=""
      break
    fi
    # Same rule as the name_prefix validation in variables.tf: hyphens only
    # between alphanumerics, since a trailing or doubled hyphen produces a
    # Key Vault and AKS name Azure rejects at apply. A leading digit is fine,
    # because the prefix always lands on the end of "ls-<resource>" and the
    # composed name still starts with a letter.
    if [[ "$NAME_PREFIX" =~ ^[a-z0-9](-?[a-z0-9])*$ ]]; then
      # Storage and Key Vault cap at 24 characters including the resource word
      # and the uniqueness hash, so ~12 characters is the practical ceiling here
      # and the wizard can say so with the actual name rather than a rule of
      # thumb. The plan-time preconditions stay as the backstop for a
      # hand-written tfvars.
      _derive_names
      name_errors="$(_name_length_errors)"
      [[ -z "$name_errors" ]] && break
      while IFS= read -r name_error_line; do
        _red "  ERROR: $name_error_line"
      done <<< "$name_errors"
      _hint "Shorten the deployment name, or pin the name yourself with storage_account_name /"
      _hint "keyvault_name in terraform.tfvars once this run has written it."
      continue
    fi
    _red "  ERROR: must be lowercase alphanumerics separated by single hyphens (e.g. prod, dev-dz), or \"none\" for no suffix. No trailing or doubled hyphen."
  done

  _ask "Azure region" "$LOCATION"
  LOCATION="$_REPLY"

  # These three are Azure tags and nothing else: they name no resource and grant
  # no one access. "Owner tag" read like it might do the latter.
  echo ""
  _hint "The last three answers are Azure tags, used for cost reporting and policy."
  _hint "None of them grants access or appears in a resource name. Blank omits the tag."
  _hint "The environment tag defaults to the deployment name — set it only when the"
  _hint "deployment name carries more (name \"prod-eastus\", environment tag \"prod\")."
  _ask "Environment tag (blank = the deployment name)" "$ENVIRONMENT"
  ENVIRONMENT="$_REPLY"

  _ask "Owner tag (team or person, for cost attribution)" "$OWNER"
  OWNER="$_REPLY"

  _ask "Cost center tag (billing code)" "$COST_CENTER"
  COST_CENTER="$_REPLY"

  echo ""
  _derive_names
  printf "  Resource group  $(_cyan "$_RG_NAME")  in  $(_cyan "$LOCATION")\n"
  printf "  Cluster $(_cyan "$_AKS_NAME") · Key Vault $(_cyan "$_KV_NAME") · Storage $(_cyan "$_BLOB_NAME")\n"
}

# -- 3. Networking -----------------------------------------------------------
CREATE_VNET="true"
VNET_ID=""
AKS_SUBNET_ID=""
POSTGRES_SUBNET_ID=""
REDIS_SUBNET_ID=""
AKS_SUBNET_CIDR_LINE=""
POSTGRES_SUBNET_CIDR_LINE=""
REDIS_SUBNET_CIDR_LINE=""
AKS_SERVICE_CIDR=""

# Ask for one subnet in bring-your-own-VNet mode. An empty answer means
# "Terraform creates it", which then needs a CIDR to carve out of the VNet.
# Sets _SUBNET_ID and _SUBNET_CIDR_LINE.
_ask_subnet() {
  local label="$1" cidr_var="$2" default_cidr="$3" note="$4"
  _SUBNET_ID=""
  _SUBNET_CIDR_LINE=""
  echo ""
  _hint "$note"
  _ask "${label} subnet resource ID (Enter = let Terraform create it)" ""
  _SUBNET_ID="$_REPLY"
  if [[ -z "$_SUBNET_ID" ]]; then
    _ask "CIDR for the new ${label} subnet" "$default_cidr"
    # Padded so the three prefix lines line up with each other in the tfvars.
    _SUBNET_CIDR_LINE="$(printf '%-30s = ["%s"]' "$cidr_var" "$_REPLY")"
  fi
}

# A subnet that has to already exist. AGIC and the bastion have no carve path
# inside a VNet Terraform does not own, so an ID is required rather than optional.
# Lowercased before matching for the same reason as vnet_re below, and the
# optional third argument enforces a name Azure demands.
_ask_required_subnet() {
  local label="$1" note="$2" want_name="$3" id_lc want_lc
  local subnet_re='^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.network/virtualnetworks/[^/]+/subnets/[^/]+$'
  want_lc=$(printf '%s' "$want_name" | tr '[:upper:]' '[:lower:]')
  echo ""
  _hint "$note"
  while true; do
    _ask "${label} subnet resource ID" ""
    _REQUIRED_SUBNET_ID="$_REPLY"
    id_lc=$(printf '%s' "$_REQUIRED_SUBNET_ID" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$id_lc" =~ $subnet_re ]]; then
      _red "  ERROR: expected /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
      echo ""
      continue
    fi
    if [[ -n "$want_lc" && "${id_lc##*/}" != "$want_lc" ]]; then
      _red "  ERROR: Azure requires this subnet be named ${want_name}."
      echo ""
      continue
    fi
    break
  done
}

# One subnet's line on the review screen: the ID being reused, or the CIDR
# Terraform will carve. Lets an operator catch a pasted ID before anything runs.
_subnet_review() {
  local id="$1" cidr_line="$2"
  if [[ -n "$id" ]]; then
    echo "reuse   $id"
  else
    echo "create  ${cidr_line#*= }"
  fi
}

_run_section_3() {
  _section "3. Networking"
  _hint "Most deployments use a new VNet — Terraform manages address space and subnets."
  _hint "Choose 'existing VNet' only if you're integrating into a corporate network"
  _hint "where network teams manage VNets centrally."

  if _ask_yn "Create a new VNet? (recommended)" "$(_yn_default "$CREATE_VNET")"; then
    CREATE_VNET="true"
    # Clear any BYO IDs and carved CIDRs from a previous pass — meaningless here.
    VNET_ID=""; AKS_SUBNET_ID=""; POSTGRES_SUBNET_ID=""; REDIS_SUBNET_ID=""
    AKS_SUBNET_CIDR_LINE=""; POSTGRES_SUBNET_CIDR_LINE=""; REDIS_SUBNET_CIDR_LINE=""
    AKS_SERVICE_CIDR=""
    AGIC_SUBNET_ID=""; BASTION_SUBNET_ID=""
    return
  fi

  CREATE_VNET="false"

  echo ""
  _hint "Bring Your Own VNet — LangSmith deploys into a VNet you already own."
  _hint "Each subnet below is optional. Paste a subnet resource ID to reuse an"
  _hint "existing subnet, or press Enter and Terraform creates it inside your VNet"
  _hint "with the settings that service needs."
  _hint "The CIDRs offered as defaults below describe the VNet Terraform builds, not"
  _hint "yours. Replace each with a free range inside your own address space."
  echo ""

  # Matched against the same shape the vnet_id variable validates, so a typo is
  # caught here rather than at terraform plan. That validation is
  # case-insensitive because Azure hands back "resourcegroups" in some contexts
  # and "resourceGroups" in others, so lowercase a copy before comparing — bash
  # 3.2 has no ${var,,}. Only the comparison is lowered; Terraform gets what was
  # pasted.
  local vnet_re='^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.network/virtualnetworks/[^/]+$'
  local vnet_lc
  while true; do
    _ask "VNet resource ID (/subscriptions/.../virtualNetworks/...)" "$VNET_ID"
    VNET_ID="$_REPLY"
    vnet_lc=$(printf '%s' "$VNET_ID" | tr '[:upper:]' '[:lower:]')
    [[ "$vnet_lc" =~ $vnet_re ]] && break
    _red "  ERROR: expected /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>"
    echo ""
  done

  _ask_subnet "AKS" "aks_subnet_address_prefix" "10.0.0.0/19" \
    "Holds AKS node and pod IPs (Azure CNI). An existing subnet needs the Microsoft.Storage and Microsoft.KeyVault service endpoints."
  AKS_SUBNET_ID="$_SUBNET_ID"; AKS_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  _ask_subnet "PostgreSQL" "postgres_subnet_address_prefix" "10.0.32.0/20" \
    "An existing subnet must already be delegated to Microsoft.DBforPostgreSQL/flexibleServers and contain nothing else. A new one gets that delegation automatically."
  POSTGRES_SUBNET_ID="$_SUBNET_ID"; POSTGRES_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  _ask_subnet "Redis" "redis_subnet_address_prefix" "10.0.48.0/20" \
    "Holds the Azure Managed Redis private endpoint. This subnet must NOT be delegated — a delegated subnet would reject the endpoint."
  REDIS_SUBNET_ID="$_SUBNET_ID"; REDIS_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  # Kubernetes ClusterIPs are internal to the cluster, but AKS still requires the
  # range to be unused by anything on or connected to the VNet. The default only
  # dodges the VNet Terraform builds, so on this path the operator must name one.
  echo ""
  _hint "Kubernetes assigns ClusterIPs from a range that must not be used by anything"
  _hint "in your VNet or any network peered to it. It is not carved from your VNet —"
  _hint "pick a range that sits outside your VNet's address space entirely."
  # Four subnet ID prompts run immediately above this one, and a resource ID
  # pasted here reaches Terraform as a string the locals hand to cidrhost() —
  # an invalid-CIDR error against a main.tf line the operator never wrote.
  while true; do
    _ask "Kubernetes service CIDR" "${AKS_SERVICE_CIDR:-10.0.64.0/20}"
    if _valid_cidr "$_REPLY"; then break; fi
    if _valid_subnet_id "$_REPLY"; then
      _red "  ERROR: that is a subnet resource ID. No subnet is created for this range — Kubernetes allocates ClusterIPs from it, so it takes an address range like 10.0.64.0/20."
    else
      _red "  ERROR: expected an IPv4 CIDR, e.g. 10.0.64.0/20."
    fi
    echo ""
  done
  AKS_SERVICE_CIDR="$_REPLY"

  # This section can be re-run from the review menu, after AGIC or a bastion has
  # already been chosen. Neither is carved inside a VNet Terraform does not own,
  # so collect the subnet each one needs. On a first pass through the wizard both
  # are still at their defaults and the prompts below ask at the point of choice.
  if [[ "$INGRESS_CONTROLLER" == "agic" ]]; then
    _ask_required_subnet "Application Gateway" \
      "AGIC needs an existing subnet to itself, /24 recommended. Terraform will not create one inside a VNet you own." ""
    AGIC_SUBNET_ID="$_REQUIRED_SUBNET_ID"
  fi
  if [[ "$CREATE_BASTION" == "true" ]]; then
    _ask_required_subnet "Azure Bastion" \
      "Azure Bastion needs an existing subnet named AzureBastionSubnet, /26 or larger." "AzureBastionSubnet"
    BASTION_SUBNET_ID="$_REQUIRED_SUBNET_ID"
  fi

  echo ""
  _hint "Any CIDR you entered must fit inside your VNet's address space, not overlap"
  _hint "an existing subnet, and not overlap the Kubernetes service CIDR above."
}

# -- 4. AKS ------------------------------------------------------------------
NODE_VM_SIZE="Standard_D4s_v3"
NODE_MIN=2
NODE_MAX=5
NODE_MAX_PODS=60
AKS_DELETION_PROTECTION="false"

_run_section_4() {
  _section "4. AKS Cluster"
  _hint "Node sizing determines how many LangSmith services fit per node."
  _hint "Standard_D4s_v3 (4 vCPU, 16 GiB) — OK for dev/POC with in-cluster services."
  _hint "Standard_D8s_v3 (8 vCPU, 32 GiB) — required for production sizing profile."
  _hint "Cost estimate (eastus, on-demand): D4s_v3 ~\$0.19/hr, D8s_v3 ~\$0.38/hr per node."
  _hint "The autoscaler handles bursts — min_count is the always-on floor."

  local vm_default="$NODE_VM_SIZE"
  local min_default="$NODE_MIN"
  local max_default="$NODE_MAX"
  if [[ "$PROFILE" == "prod" ]]; then
    if ! _answered 4; then
      vm_default="Standard_D8s_v3"
      min_default=3
      max_default=10
    fi
    _hint "Production defaults: D8s_v3 ×3 min (fits Pass 2 at ~76% CPU utilization)."
  fi

  _ask "Node VM size" "$vm_default"
  NODE_VM_SIZE="$_REPLY"
  _ask_int "Node pool min count (always-on nodes)" "$min_default"
  NODE_MIN="$_REPLY"
  _ask_int "Node pool max count (autoscaler ceiling)" "$max_default"
  NODE_MAX="$_REPLY"

  # Azure CNI draws pod IPs from the AKS subnet, so this multiplies the subnet
  # size: the cluster needs (max_count + 1) x (max_pods + 1) addresses. It is one
  # of the two knobs the capacity check tells operators to lower, so it needs to
  # be reachable from here.
  _hint "Max pods per node multiplies the AKS subnet requirement, at"
  _hint "(max count + 1) x (max pods + 1) addresses. 60 suits most deployments;"
  _hint "lower it if your subnet is fixed and tight."
  _ask_int "Max pods per node" "$NODE_MAX_PODS"
  NODE_MAX_PODS="$_REPLY"

  AKS_DELETION_PROTECTION="false"
  if [[ "$PROFILE" == "prod" ]]; then
    AKS_DELETION_PROTECTION="true"
    _hint "Production: aks_deletion_protection = true (prevents accidental terraform destroy)."
  fi
}

# -- 5. Ingress Controller ---------------------------------------------------
INGRESS_CONTROLLER="nginx"
ISTIO_ADDON_REVISION=""
AGW_SKU_TIER=""

_run_section_5() {
  _section "5. Ingress Controller"
  _hint "The ingress controller routes external HTTP/HTTPS traffic to LangSmith pods."
  _hint "nginx       — standard K8s ingress, supported everywhere, easiest to debug."
  _hint "istio-addon — AKS managed Istio mesh; best for multi-dataplane + mTLS use cases."
  _hint "istio       — self-managed Istio via Helm; more control, more operational overhead."
  _hint "agic        — Azure Application Gateway; enterprise WAF built-in. Needs a"
  _hint "              dedicated /24 subnet, carved for you or named with agic_subnet_id."
  _hint "envoy-gateway — Gateway API native; useful if you're standardizing on Gateway API."
  _hint "Start with nginx unless you have a specific reason to use another."

  local ingress_choice=""
  _answered 5 && ingress_choice="$(_index_of "$INGRESS_CONTROLLER" nginx istio-addon istio agic envoy-gateway none)"

  while true; do
    _ask_choice --default "$ingress_choice" \
      "Which ingress controller?" \
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

    # Terraform will not carve an Application Gateway subnet inside a VNet it
    # does not own, so on that path the operator names one that already exists.
    if [[ "$INGRESS_CONTROLLER" == "agic" && "$CREATE_VNET" == "false" ]]; then
      _ask_required_subnet "Application Gateway" \
        "AGIC needs an existing subnet to itself, /24 recommended. Terraform will not create one inside a VNet you own." ""
      AGIC_SUBNET_ID="$_REQUIRED_SUBNET_ID"
    fi
    break
  done

  echo ""
  printf "  Ingress: $(_cyan "$INGRESS_CONTROLLER")\n"

  # Clear settings that belong to a controller no longer selected. The subnet ID
  # goes with them: it is written whenever non-empty, so leaving it behind after
  # a switch away from AGIC emits an agic_subnet_id for a gateway never created.
  [[ "$INGRESS_CONTROLLER" != "istio-addon" ]] && ISTIO_ADDON_REVISION=""
  [[ "$INGRESS_CONTROLLER" != "agic" ]]        && { AGW_SKU_TIER=""; AGIC_SUBNET_ID=""; }

  if [[ "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
    echo ""
    _hint "The Istio addon revision must match what AKS supports in your region."
    _hint "Check available revisions after cluster creation:"
    _hint "  az aks mesh get-upgrades -g <rg> -n <cluster>"
    _ask "Istio addon revision" "${ISTIO_ADDON_REVISION:-asm-1-22}"
    ISTIO_ADDON_REVISION="$_REPLY"
  fi

  if [[ "$INGRESS_CONTROLLER" == "agic" ]]; then
    echo ""
    _hint "AGIC provisions an Azure Application Gateway v2 with a dedicated /24 subnet."
    _hint "The gateway runs Standard_v2. Answering yes to the WAF policy later attaches"
    _hint "one and moves the gateway to WAF_v2, the only tier Azure allows it on."
    _hint "Switching an existing deployment to AGIC updates the cluster in place — the"
    _hint "add-on is an argument on the cluster resource, not a new cluster."
    _hint "With a VNet you own, supply the Application Gateway subnet."
  fi
}

# -- 6. DNS + TLS ------------------------------------------------------------
TLS_SOURCE="none"
DNS_LABEL=""
LANGSMITH_DOMAIN=""
LE_EMAIL=""
CREATE_DNS_ZONE="false"

# Suggests langsmith-<name_prefix> but still asks, because the DNS label lives in
# a namespace shared with every other Azure tenant in the region: the FQDN
# <label>.<region>.cloudapp.azure.com must be unique region-wide, so a derived
# name can be taken by someone else. Same class of collision as the Key Vault
# name. Asking here means the operator picks a free one instead of hitting
# DnsRecordCreateConflict at apply.
_ask_dns_label() {
  # A label already in use is the answer to keep — the suggestion is only for a
  # deployment that has not claimed one yet. Reoffering the derived name would
  # move the FQDN operators have already handed out.
  _ask "DNS label — must be unique across the whole $LOCATION region (e.g. langsmith-prod)" \
    "${DNS_LABEL:-langsmith${NAME_PREFIX:+-$NAME_PREFIX}}"
  DNS_LABEL="$_REPLY"
}

_run_section_6() {
  _section "6. DNS + TLS"
  _hint "Determines how LangSmith is accessed and whether traffic is encrypted."
  _hint ""
  _hint "None          — HTTP only. Fastest setup, zero cert config. Good for dev/internal."
  _hint "              URL: http://<label>.<region>.cloudapp.azure.com"
  _hint ""
  _hint "Both HTTPS options are free certificates from Let's Encrypt. What differs is how"
  _hint "Let's Encrypt proves you control the name, and both register an ACME account."
  _hint ""
  _hint "HTTP-01       — Let's Encrypt fetches a token over port 80. Needs a public DNS label."
  _hint "              Works with: nginx, istio (self-managed), envoy-gateway."
  _hint "              Does NOT work with istio-addon or agic (no IngressClass / path rewrite)."
  _hint ""
  _hint "DNS-01        — cert-manager writes a TXT record to Azure DNS. No HTTP port needed,"
  _hint "              so it works with ALL controllers."
  _hint "              Requires a custom domain and an Azure DNS zone (NS delegation)."
  _hint "              Best for: private clusters, firewalled environments, istio-addon."
  _hint ""
  _hint "Existing      — Bring a pre-issued K8s TLS secret (manual cert management)."

  local tls_choice=""
  _answered 6 && tls_choice="$(_index_of "$TLS_SOURCE" none letsencrypt dns01 existing)"
  _ask_choice --default "$tls_choice" \
    "TLS certificate source:" \
    "None                    — HTTP only (quickstart default, zero setup)" \
    "Let's Encrypt (HTTP-01) — nginx, istio, envoy-gateway only" \
    "Let's Encrypt (DNS-01)  — all controllers, requires a custom domain" \
    "Existing                — bring your own K8s TLS secret"

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
    # DNS-01 has no DNS-label path at all: cert-manager has to write a TXT record
    # into the zone, and Azure owns cloudapp.azure.com. Offering the choice here
    # offered an answer that left langsmith_domain empty and the cert unissuable.
    local want_domain=false
    [[ "$TLS_SOURCE" == "dns01" ]] && want_domain=true

    if [[ "$want_domain" == "false" ]]; then
      _hint "How do you want to expose the LangSmith URL?"
      _hint "  Azure DNS label — free Azure subdomain, no domain purchase needed."
      _hint "                    Azure assigns <label>.<region>.cloudapp.azure.com to the LB IP."
      _hint "  Custom domain   — bring your own domain (e.g. langsmith.mycompany.com)."
      _hint "                    You'll delegate a subdomain's NS records to Azure DNS."
      echo ""

      local dns_choice=""
      _answered 6 && { [[ -n "$LANGSMITH_DOMAIN" ]] && dns_choice=2 || dns_choice=1; }
      _ask_choice --default "$dns_choice" \
        "DNS approach:" \
        "Azure public IP DNS label — simplest, free subdomain" \
        "Custom domain — your own domain"
      [[ "$_CHOICE" == "2" ]] && want_domain=true
    fi

    if [[ "$want_domain" == "true" ]]; then
      DNS_LABEL=""
      echo ""
      _hint "Example: langsmith.mycompany.com or azurelangsmith.mycompany.com"
      while true; do
        _ask "Custom domain" "$LANGSMITH_DOMAIN"
        LANGSMITH_DOMAIN="$_REPLY"
        [[ -n "$LANGSMITH_DOMAIN" ]] && break
        _red "  ERROR: a domain is required here — the certificate is issued for this name."
      done
    else
      LANGSMITH_DOMAIN=""
      _ask_dns_label
    fi

    _hint "Both challenge types register an ACME account with Let's Encrypt, which needs"
    _hint "an email. Used for expiry notices only."
    _ask "Email for the ACME account" "$LE_EMAIL"
    LE_EMAIL="$_REPLY"

  elif [[ "$TLS_SOURCE" == "none" ]]; then
    LANGSMITH_DOMAIN=""; LE_EMAIL=""
    echo ""
    _hint "Azure assigns a free DNS label to your load balancer public IP."
    _hint "Format: <label>.<region>.cloudapp.azure.com"
    _ask_dns_label
  else
    # existing — no hostname prompts apply
    DNS_LABEL=""; LANGSMITH_DOMAIN=""; LE_EMAIL=""
  fi

  CREATE_DNS_ZONE="false"
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
AMR_SKU="Balanced_B1"
REDIS_HA="false"
# Storage is not optional — LangSmith needs a blob container for run artifacts —
# but how long those artifacts live is a policy choice, so section 7 asks.
BLOB_TTL_ENABLED="true"
BLOB_TTL_SHORT_DAYS="14"
BLOB_TTL_LONG_DAYS="400"

_run_section_7() {
  _section "7. Backend Services"
  _hint "PostgreSQL, Redis, and ClickHouse are required by LangSmith."
  _hint ""
  _hint "In-cluster  — runs as pods. Simple to deploy, but no backups, limited HA."
  _hint "              OK for dev/POC. Do NOT use for production workloads."
  _hint ""
  _hint "External    — Azure managed services (Postgres Flexible Server, Managed Redis)."
  _hint "              Automated backups, geo-redundancy, independent scaling."
  _hint "              Recommended for production and long-running POCs."
  _hint ""
  _hint "ClickHouse  — in-cluster is a single StatefulSet with no backups."
  _hint "              For production traces, use LangChain Managed ClickHouse instead."

  if [[ "$PROFILE" == "prod" ]]; then
    echo ""
    _hint "Production: external Postgres and Redis are strongly recommended."
    # Prod fresh-run default is external; on re-entry, whatever you picked.
    local pg_yn="y" redis_yn="y"
    if _answered 7; then
      [[ "$PG_SOURCE"    == "in-cluster" ]] && pg_yn="n"
      [[ "$REDIS_SOURCE" == "in-cluster" ]] && redis_yn="n"
    fi
    if ! _ask_yn "Use external PostgreSQL (Azure DB for PostgreSQL Flexible Server)?" "$pg_yn"; then
      PG_SOURCE="in-cluster"
    else
      PG_SOURCE="external"
    fi
    if ! _ask_yn "Use external Redis (Azure Managed Redis Balanced_B3 — 3 GB, HA)?" "$redis_yn"; then
      REDIS_SOURCE="in-cluster"
    else
      REDIS_SOURCE="external"
      # Fresh run only: a re-entry has already parsed the operator's SKU and HA
      # choice out of tfvars, and resetting here would discard it.
      if ! _answered 7; then
        AMR_SKU="Balanced_B3"
        REDIS_HA="true"
      fi
    fi
  else
    # No default until the section has been answered once — a fresh run still
    # forces an explicit choice rather than quietly picking one.
    local pg_choice=""
    _answered 7 && { [[ "$PG_SOURCE" == "external" ]] && pg_choice=1 || pg_choice=2; }
    _ask_choice --default "$pg_choice" \
      "Postgres + Redis:" \
      "External — Azure managed services (recommended even for dev — keeps data on destroy)" \
      "In-cluster — all services run as pods (fastest setup, data lost on destroy)"
    if [[ "$_CHOICE" == "1" ]]; then
      PG_SOURCE="external"
      REDIS_SOURCE="external"
    else
      PG_SOURCE="in-cluster"
      REDIS_SOURCE="in-cluster"
    fi
  fi

  if [[ "$PG_SOURCE" == "external" ]]; then
    PG_DELETION_PROTECTION="false"
    [[ "$PROFILE" == "prod" ]] && PG_DELETION_PROTECTION="true"
  fi

  # Without this prompt every quickstart deployment silently took the Balanced_B0
  # module default, which some regions cannot allocate.
  if [[ "$REDIS_SOURCE" == "external" ]]; then
    echo ""
    _hint "Azure Managed Redis SKU. Balanced_B0 is the smallest; bump to Balanced_B1/B3"
    _hint "if the region reports AllocationFailed."
    # Default to the SKU already chosen, never a literal: the prod branch above
    # picks Balanced_B3 with HA on, and a hardcoded B0 default overwrites it into
    # a pair the redis module rejects — so pressing Enter here failed plan.
    while true; do
      _ask "Azure Managed Redis SKU" "$AMR_SKU"
      AMR_SKU="$_REPLY"
      [[ "$AMR_SKU" == "Balanced_B0" && "$REDIS_HA" == "true" ]] || break
      # amr_sku and redis_high_availability are written to tfvars independently,
      # so the pair has to be checked at the prompt. Same two remedies the
      # module's validation names, offered now instead of 20 lines into a plan.
      echo ""
      _yellow "NOTE"; printf ": Balanced_B0 cannot run zone-redundant HA.\n"
      if _ask_yn "Turn Redis HA off and keep Balanced_B0?" "n"; then
        REDIS_HA="false"
        break
      fi
    done
  fi

  echo ""
  local ch_choice=""
  _answered 7 && { [[ "$CH_SOURCE" == "external" ]] && ch_choice=2 || ch_choice=1; }
  _ask_choice --default "$ch_choice" "ClickHouse:" \
    "In-cluster — single pod, dev/POC only (data lost on pod restart without PV backup)" \
    "External   — LangChain Managed ClickHouse (production-grade, contact LangChain)"

  [[ "$_CHOICE" == "2" ]] && CH_SOURCE="external" || CH_SOURCE="in-cluster"

  if [[ "$PROFILE" == "prod" && "$CH_SOURCE" == "in-cluster" ]]; then
    echo ""
    _yellow "NOTE"; printf ": In-cluster ClickHouse is not recommended for production.\n"
    printf "  See: https://docs.langchain.com/langsmith/langsmith-managed-clickhouse\n"
  fi

  # Storage came with the deployment whether or not anyone asked, and the
  # retention defaults were written into tfvars unasked with it. A customer with
  # a data-retention policy has to see this as a choice.
  echo ""
  _hint "LangSmith stores run inputs, outputs and attachments in an Azure Storage account"
  _hint "this module creates. Retention expires them on a schedule: short-lived covers the"
  _hint "per-run payloads, long-lived covers datasets and exports."
  local ttl_yn
  ttl_yn="$(_yn_default "$BLOB_TTL_ENABLED")"
  if _ask_yn "Expire stored artifacts on a schedule?" "$ttl_yn"; then
    BLOB_TTL_ENABLED="true"
    _ask_int "Days to keep short-lived artifacts" "$BLOB_TTL_SHORT_DAYS"
    BLOB_TTL_SHORT_DAYS="$_REPLY"
    _ask_int "Days to keep long-lived artifacts" "$BLOB_TTL_LONG_DAYS"
    BLOB_TTL_LONG_DAYS="$_REPLY"
  else
    BLOB_TTL_ENABLED="false"
    _hint "Artifacts are kept until you delete them. Storage cost grows with trace volume."
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
  _hint "                           Downside: cannot reuse the same deployment name for 90 days."
  _hint ""
  _hint "Purge protection = false → KV is immediately purged on destroy."
  _hint "                           Good for dev/POC where you want to reuse the deployment name."

  if [[ "$PROFILE" == "prod" ]]; then
    echo ""
    local kv_yn="y"
    _answered 8 && kv_yn="$(_yn_default "$KV_PURGE_PROTECTION")"
    if _ask_yn "Enable Key Vault purge protection? (recommended for production)" "$kv_yn"; then
      KV_PURGE_PROTECTION="true"
    else
      KV_PURGE_PROTECTION="false"
    fi
  else
    KV_PURGE_PROTECTION="false"
    _hint "Dev profile: keyvault_purge_protection = false (name reusable immediately after destroy)."
  fi
}

# -- 9. Sizing Profile -------------------------------------------------------
SIZING_PROFILE="dev"
# Not prompted anywhere: a first deployment is Pass 1/2 only, and the later
# passes are turned on by editing the generated file. Held as variables so a
# re-run writes back what is already deployed instead of a hardcoded false.
ENABLE_DEPLOYMENTS="false"
ENABLE_AGENT_BUILDER="false"
ENABLE_INSIGHTS="false"
ENABLE_POLLY="false"

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

  local sizing_choice=""
  _answered 9 && sizing_choice="$(_index_of "$SIZING_PROFILE" minimum dev production production-large)"
  _ask_choice --default "$sizing_choice" "Sizing profile:" \
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

  if [[ "$PROFILE" == "prod" ]]; then
    local waf_yn="n" diag_yn="y" bastion_yn="n"
    if _answered 10; then
      waf_yn="$(_yn_default "$CREATE_WAF")"
      diag_yn="$(_yn_default "$CREATE_DIAGNOSTICS")"
      bastion_yn="$(_yn_default "$CREATE_BASTION")"
    fi

    echo ""
    _hint "WAF policy      — Azure WAF with OWASP 3.2 rules + bot protection."
    _hint "                  With ingress_controller = agic the policy is attached to the"
    _hint "                  Application Gateway, which moves it to the WAF_v2 tier (~\$250/mo"
    _hint "                  more). Starts in Detection mode — logs matches without blocking."
    _hint "                  Say yes to diagnostics too, or nothing collects the firewall log and"
    _hint "                  you cannot see what to exclude before switching to Prevention."
    _hint "                  For nginx/istio the policy is created but nothing references it —"
    _hint "                  use Azure Front Door or DDoS Protection instead."
    if _ask_yn "Enable Azure WAF policy? (OWASP 3.2 + bot protection)" "$waf_yn"; then
      CREATE_WAF="true"
    else
      CREATE_WAF="false"
    fi

    echo ""
    _hint "Log Analytics   — sends AKS control plane logs + metrics to Log Analytics workspace."
    _hint "                  Required for audit trails, compliance, and live troubleshooting."
    if _ask_yn "Enable Log Analytics + diagnostics? (recommended for production)" "$diag_yn"; then
      CREATE_DIAGNOSTICS="true"
    else
      CREATE_DIAGNOSTICS="false"
    fi

    echo ""
    _hint "Bastion host    — jump VM for direct SSH to AKS nodes (private cluster debugging)."
    _hint "                  Not needed for most deployments unless nodes are on a private subnet."
    if _ask_yn "Create bastion host? (for node-level troubleshooting)" "$bastion_yn"; then
      CREATE_BASTION="true"
      # Terraform carves the bastion subnet only out of a VNet it owns, so on the
      # bring-your-own path the operator names an existing one.
      if [[ "$CREATE_VNET" == "false" ]]; then
        _ask_required_subnet "Azure Bastion" \
          "Azure Bastion needs an existing subnet named AzureBastionSubnet, /26 or larger." "AzureBastionSubnet"
        BASTION_SUBNET_ID="$_REQUIRED_SUBNET_ID"
      fi
    else
      CREATE_BASTION="false"
      BASTION_SUBNET_ID=""
    fi
  else
    CREATE_WAF="false"
    CREATE_DIAGNOSTICS="false"
    CREATE_BASTION="false"
    BASTION_SUBNET_ID=""
    _hint "Dev profile: security add-ons skipped. Edit terraform.tfvars to enable after deploy."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Startup — resume an interrupted run, or seed from an existing tfvars
# ═══════════════════════════════════════════════════════════════════════════
# Runs here, after every section default has been initialized above, so loaded
# answers are not overwritten by the initializers.

TOTAL_SECTIONS=10
SECTION=1
# Whether settings the wizard cannot ask about survive the rewrite. Set before
# the checkpoint is read so a resumed run keeps the answer it was given, and
# true by default so a checkpoint written by an older version of this script
# does not delete them.
PRESERVE_UNKNOWN="true"

if [[ -f "$STATE_FILE" ]]; then
  echo ""
  _cyan "Found an unfinished run"; printf ": %s\n" "$STATE_FILE"
  if _ask_yn "Resume it? (answering 'n' discards those answers)" "y"; then
    # SECTION in the file is the last one completed; pick up at the next one.
    # A run interrupted mid-section therefore replays only that section.
    _load_state
    # Arithmetic evaluation expands its operands recursively, so a truncated or
    # hand-edited checkpoint must never reach it as anything but a number.
    [[ "$SECTION" =~ ^[0-9]+$ ]] || SECTION=0
    SECTION=$((SECTION + 1))
    if (( SECTION > TOTAL_SECTIONS )); then
      printf "  All sections answered — going straight to review.\n"
    else
      printf "  Resuming at section $(_bold "$SECTION") of ${TOTAL_SECTIONS}.\n"
    fi
  else
    rm -f "$STATE_FILE"
    ANSWERED=""
    SECTION=1
  fi
fi

if [[ -z "$ANSWERED" && -f "$OUTPUT" ]]; then
  echo ""
  _yellow "WARNING"; printf ": %s already exists.\n" "$OUTPUT"
  _ask_choice "What would you like to do?" \
    "Edit it     — load its values as answers, change what you need" \
    "Start fresh — ignore it and answer every question again (discards hand-edits too)" \
    "Quit        — leave it untouched"
  case "$_CHOICE" in
    1) _load_tfvars
       ANSWERED="1 2 3 4 5 6 7 8 9 10"
       printf "  Loaded existing values. Press Enter at a prompt to keep the current answer.\n" ;;
    2) PRESERVE_UNKNOWN="false"
       # The wizard never writes create_cluster or create_keyvault, so both ride
       # through a re-run as preserved unknown keys — except on this branch,
       # which drops them. That is not one more discarded hand-edit: it turns an
       # attached deployment back into a greenfield one, and the next plan builds
       # a second cluster and vault beside the ones already in use.
       _attached=""
       if grep -qE '^[[:space:]]*create_cluster[[:space:]]*=[[:space:]]*false' "$OUTPUT"; then
         _attached="an AKS cluster"
       fi
       if grep -qE '^[[:space:]]*create_keyvault[[:space:]]*=[[:space:]]*false' "$OUTPUT"; then
         _attached="${_attached:+${_attached} and }a Key Vault"
       fi
       if [[ -n "$_attached" ]]; then
         echo ""
         _yellow "NOTE"; printf ": that file attaches to %s you already own.\n" "$_attached"
         printf "  Starting fresh drops those settings, and the next plan creates new ones\n"
         printf "  instead of reusing yours. To keep attaching, copy them back from\n"
         printf "  %s.bak when the wizard finishes.\n" "$OUTPUT"
       fi ;;
    3) echo "Aborted."; exit 0 ;;
  esac
fi

# ═══════════════════════════════════════════════════════════════════════════
# Run sections — Enter advances, b goes back, r jumps to review, q saves & quits
# ═══════════════════════════════════════════════════════════════════════════

while (( SECTION <= TOTAL_SECTIONS )); do
  "_run_section_$SECTION"
  _mark_answered "$SECTION"
  _save_state

  echo ""
  printf "  ${DIM}[Enter] next · [b] back · [r] jump to review · [q] save & quit${RESET}\n"
  while true; do
    printf "  Section %d/%d: " "$SECTION" "$TOTAL_SECTIONS"
    read -r _NAV
    case "$_NAV" in
      "")
        SECTION=$((SECTION + 1)); break ;;
      b|B)
        if (( SECTION > 1 )); then
          SECTION=$((SECTION - 1)); break
        fi
        _red "  Already at the first section." ;;
      r|R)
        SECTION=$((TOTAL_SECTIONS + 1)); break ;;
      q|Q)
        _save_state
        exit 0 ;;
      *)
        _red "  Press Enter, or type b, r, or q." ;;
    esac
  done
done

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
  printf "  %-24s %s\n" "2. Deployment name:" "${NAME_PREFIX:-(none, no suffix)}"
  printf "  %-24s %s\n" "   Subscription:"    "$SUBSCRIPTION_ID"
  printf "  %-24s %s\n" "   Location:"        "$LOCATION"
  # An unanswered environment tag falls back to the deployment name, and to "dev"
  # when there is no deployment name either, so show what the tag will say.
  printf "  %-24s %s\n" "   Environment tag:" "${ENVIRONMENT:-${NAME_PREFIX:-dev}}"
  [[ -n "$OWNER" ]]       && printf "  %-24s %s\n" "   Owner tag:"       "$OWNER"
  [[ -n "$COST_CENTER" ]] && printf "  %-24s %s\n" "   Cost center tag:" "$COST_CENTER"
  printf "  %-24s %s\n" "3. VNet:"            "$( [[ "$CREATE_VNET" == "true" ]] && echo "new (auto-created)" || echo "existing" )"
  if [[ "$CREATE_VNET" == "false" ]]; then
    printf "  %-24s %s\n" "   VNet ID:"           "$VNET_ID"
    printf "  %-24s %s\n" "   AKS subnet:"        "$(_subnet_review "$AKS_SUBNET_ID" "$AKS_SUBNET_CIDR_LINE")"
    printf "  %-24s %s\n" "   PostgreSQL subnet:" "$(_subnet_review "$POSTGRES_SUBNET_ID" "$POSTGRES_SUBNET_CIDR_LINE")"
    printf "  %-24s %s\n" "   Redis subnet:"      "$(_subnet_review "$REDIS_SUBNET_ID" "$REDIS_SUBNET_CIDR_LINE")"
    printf "  %-24s %s\n" "   Service CIDR:"      "$AKS_SERVICE_CIDR"
    [[ -n "$AGIC_SUBNET_ID" ]]    && printf "  %-24s %s\n" "   AGIC subnet:"    "reuse   $AGIC_SUBNET_ID"
    [[ -n "$BASTION_SUBNET_ID" ]] && printf "  %-24s %s\n" "   Bastion subnet:" "reuse   $BASTION_SUBNET_ID"
  fi
  printf "  %-24s %s\n" "4. Node size:"       "$NODE_VM_SIZE  min=$NODE_MIN  max=$NODE_MAX  max_pods=$NODE_MAX_PODS"
  printf "  %-24s %s\n" "5. Ingress:"         "$INGRESS_CONTROLLER"
  [[ -n "$ISTIO_ADDON_REVISION" ]] && printf "  %-24s %s\n" "   Istio revision:"  "$ISTIO_ADDON_REVISION"
  [[ -n "$AGW_SKU_TIER" ]]         && printf "  %-24s %s\n" "   AGW SKU:"         "$AGW_SKU_TIER"
  # Both HTTPS values are Let's Encrypt, which "letsencrypt" and "dns01" alone
  # hide — the review screen is the last place that misreading can be caught.
  _TLS_REVIEW="$TLS_SOURCE"
  [[ "$TLS_SOURCE" == "letsencrypt" ]] && _TLS_REVIEW="letsencrypt  (Let's Encrypt, HTTP-01 challenge)"
  [[ "$TLS_SOURCE" == "dns01" ]]       && _TLS_REVIEW="dns01  (Let's Encrypt, DNS-01 challenge)"
  printf "  %-24s %s\n" "6. TLS:"             "$_TLS_REVIEW"
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
  # What the answers add up to. The resource group and the storage account are
  # never asked about, so this is the only place an operator with a naming or a
  # storage policy sees that they are part of the deployment at all.
  _derive_names
  echo ""
  printf "  ${BOLD}Terraform creates, in resource group %s:${RESET}\n" "$_RG_NAME"
  printf "    %-18s %s\n" "AKS cluster"     "$_AKS_NAME"
  printf "    %-18s %s\n" "Key Vault"       "$_KV_NAME"
  printf "    %-18s %s\n" "Storage account" "$_BLOB_NAME  (LangSmith run artifacts)"
  [[ "$PG_SOURCE" == "external" ]]    && printf "    %-18s %s\n" "PostgreSQL"     "$_PG_NAME"
  [[ "$REDIS_SOURCE" == "external" ]] && printf "    %-18s %s\n" "Redis"          "$_REDIS_NAME  ($AMR_SKU)"
  # 90 days is the log_retention_days default; the wizard does not ask for it.
  [[ "$CREATE_DIAGNOSTICS" == "true" ]] && printf "    %-18s %s\n" "Log Analytics" "$_LAW_NAME  (90-day retention)"
  if [[ "$BLOB_TTL_ENABLED" == "true" ]]; then
    printf "    %-18s %s\n" "Blob retention" "short-lived ${BLOB_TTL_SHORT_DAYS}d, long-lived ${BLOB_TTL_LONG_DAYS}d"
  else
    printf "    %-18s %s\n" "Blob retention" "off — artifacts are kept until you delete them"
  fi
  printf "  ${DIM}Deleting that resource group deletes every one of them.${RESET}\n"

  echo ""
  printf "  ${DIM}Press Enter to write terraform.tfvars, a section number (1-10) to change it,${RESET}\n"
  printf "  ${DIM}or q to save your answers and quit without writing.${RESET}\n"
  printf "  Choice [Enter to confirm]: "
  read -r _REDO

  # Empty input = confirm
  if [[ -z "$_REDO" ]]; then
    break
  fi

  if [[ "$_REDO" == "q" || "$_REDO" == "Q" ]]; then
    _save_state
    exit 0
  fi

  # Validate input is a number 1-10
  if ! [[ "$_REDO" =~ ^([1-9]|10)$ ]]; then
    _red "  Enter a section number (1-10), q to quit, or press Enter to confirm."
    continue
  fi

  # Re-run the chosen section
  "_run_section_$_REDO"
  _mark_answered "$_REDO"
  _save_state
done

# ═══════════════════════════════════════════════════════════════════════════
# Generate terraform.tfvars
# ═══════════════════════════════════════════════════════════════════════════

_section "Generating terraform.tfvars"

# Every key the writer below can emit, across all of its branches. Anything else
# in an existing terraform.tfvars was put there by hand — a pinned resource
# name, a tuned SKU, an authorized-IP range — and the rewrite would destroy it,
# so those lines are carried across instead. `identifier` is on the list as the
# retired spelling of name_prefix: it has already been read back, and carrying
# it forward would leave two keys naming the deployment.
_WRITER_KEYS="subscription_id identifier name_prefix location unique_resource_names
environment owner cost_center
create_vnet vnet_id aks_subnet_id postgres_subnet_id redis_subnet_id
aks_subnet_address_prefix postgres_subnet_address_prefix redis_subnet_address_prefix
aks_service_cidr agic_subnet_id bastion_subnet_id
default_node_pool_vm_size default_node_pool_min_count default_node_pool_max_count
default_node_pool_max_pods aks_deletion_protection
ingress_controller istio_addon_revision agw_sku_tier
tls_certificate_source dns_label langsmith_domain letsencrypt_email create_dns_zone
postgres_source redis_source clickhouse_source
postgres_admin_username postgres_database_name postgres_deletion_protection
amr_sku redis_high_availability keyvault_purge_protection
blob_ttl_enabled blob_ttl_short_days blob_ttl_long_days
langsmith_namespace langsmith_release_name sizing_profile
enable_deployments enable_agent_builder enable_insights enable_polly
create_waf create_diagnostics create_bastion"

PRESERVED=""
PRESERVED_PARTIAL=""
if [[ -f "$OUTPUT" ]]; then
  # The rewrite truncates, so the previous file is only recoverable from here.
  cp "$OUTPUT" "$OUTPUT.bak"
  if [[ "$PRESERVE_UNKNOWN" != "false" ]]; then
    _depth=0
    while IFS= read -r _line; do
      # Brackets inside a string or a comment do not open a block, so take them
      # out before counting. Without this, `foo = "a { b"` swallows the rest of
      # the file.
      _bare=$(printf '%s' "$_line" | sed 's/"[^"]*"//g; s/#.*//')
      # The closing brace needs the backslash: an unescaped one inside a bracket
      # expression still ends the ${...} expansion.
      _open="${_bare//[^\[{]/}"
      _close="${_bare//[^]\}]/}"
      _delta=$(( ${#_open} - ${#_close} ))

      # Inside a value that opened on an earlier line. Its inner lines look like
      # assignments themselves (`foo = "bar"` inside a map), so they have to be
      # consumed here rather than treated as settings of their own.
      if (( _depth > 0 )); then
        _depth=$(( _depth + _delta ))
        (( _depth < 0 )) && _depth=0
        continue
      fi
      _depth=$_delta
      (( _depth < 0 )) && _depth=0

      [[ "$_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
      _key="${BASH_REMATCH[1]}"
      _known=false
      for _k in $_WRITER_KEYS; do
        [[ "$_k" == "$_key" ]] && { _known=true; break; }
      done
      [[ "$_known" == "true" ]] && continue
      # Only a value that closes on its own line can be copied verbatim. A list
      # or map spanning several lines would arrive as a fragment, which is worse
      # than naming it and leaving the operator to paste it back from the .bak.
      if [[ "$_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(\"[^\"]*\"|\[[^][]*\]|\{[^{}]*\}|[A-Za-z0-9._-]+)[[:space:]]*(#.*)?$ ]]; then
        PRESERVED="${PRESERVED}${_line}"$'\n'
      else
        PRESERVED_PARTIAL="${PRESERVED_PARTIAL} ${_key}"
      fi
    done < "$OUTPUT"
  fi
fi

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}

#------------------------------------------------------------------------------
# Subscription & Identity
#------------------------------------------------------------------------------
subscription_id = "${SUBSCRIPTION_ID}"
name_prefix     = "${NAME_PREFIX}"
location        = "${LOCATION}"

# Per-subscription hash on the globally-unique names (Postgres, Redis, Storage,
# Key Vault) so they cannot collide with another LangSmith deployment.
unique_resource_names = ${UNIQUE_NAMES}
TFVARS

# Tags are written only when answered: the module omits an empty owner or
# cost_center tag, and an empty environment falls back to the deployment name.
[[ -n "$ENVIRONMENT" ]] && echo "environment     = \"${ENVIRONMENT}\"" >> "$OUTPUT"
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
TFVARS
  # A subnet ID reuses an existing subnet; its absence plus a CIDR tells
  # Terraform to create that subnet inside the VNet above.
  [[ -n "$AKS_SUBNET_ID" ]]      && echo "aks_subnet_id      = \"${AKS_SUBNET_ID}\"" >> "$OUTPUT"
  [[ -n "$POSTGRES_SUBNET_ID" ]] && echo "postgres_subnet_id = \"${POSTGRES_SUBNET_ID}\"" >> "$OUTPUT"
  [[ -n "$REDIS_SUBNET_ID" ]]    && echo "redis_subnet_id    = \"${REDIS_SUBNET_ID}\"" >> "$OUTPUT"
  [[ -n "$AKS_SUBNET_CIDR_LINE" ]]      && echo "$AKS_SUBNET_CIDR_LINE" >> "$OUTPUT"
  [[ -n "$POSTGRES_SUBNET_CIDR_LINE" ]] && echo "$POSTGRES_SUBNET_CIDR_LINE" >> "$OUTPUT"
  [[ -n "$REDIS_SUBNET_CIDR_LINE" ]]    && echo "$REDIS_SUBNET_CIDR_LINE" >> "$OUTPUT"
  # Required on this path: the variable default is only safe against the VNet
  # Terraform builds, so terraform plan rejects an empty value here.
  printf '%-30s = "%s"\n' "aks_service_cidr" "$AKS_SERVICE_CIDR" >> "$OUTPUT"
  # Also required on this path, whenever the feature that needs them is on.
  [[ -n "$AGIC_SUBNET_ID" ]]    && printf '%-30s = "%s"\n' "agic_subnet_id" "$AGIC_SUBNET_ID" >> "$OUTPUT"
  [[ -n "$BASTION_SUBNET_ID" ]] && printf '%-30s = "%s"\n' "bastion_subnet_id" "$BASTION_SUBNET_ID" >> "$OUTPUT"
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
default_node_pool_max_pods  = ${NODE_MAX_PODS}
aks_deletion_protection     = ${AKS_DELETION_PROTECTION}

#------------------------------------------------------------------------------
# Ingress
#------------------------------------------------------------------------------
ingress_controller = "${INGRESS_CONTROLLER}"
TFVARS

[[ -n "$ISTIO_ADDON_REVISION" ]] && echo "istio_addon_revision = \"${ISTIO_ADDON_REVISION}\"" >> "$OUTPUT"
[[ -n "$AGW_SKU_TIER" ]]         && echo "agw_sku_tier = \"${AGW_SKU_TIER}\""                 >> "$OUTPUT"

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

# Azure Managed Redis (Microsoft.Cache/redisEnterprise, Redis 7.x, private endpoint)
# B1 = 1 GB, B3 = 3 GB. Set redis_location if the region reports InsufficientCapacity.
amr_sku                 = "${AMR_SKU}"
redis_high_availability = ${REDIS_HA}
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
blob_ttl_enabled    = ${BLOB_TTL_ENABLED}
blob_ttl_short_days = ${BLOB_TTL_SHORT_DAYS}
blob_ttl_long_days  = ${BLOB_TTL_LONG_DAYS}

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
enable_deployments   = ${ENABLE_DEPLOYMENTS}

# Pass 4 — Agent Builder UI
enable_agent_builder = ${ENABLE_AGENT_BUILDER}

# Pass 5 — Insights (ClickHouse-backed analytics)
enable_insights      = ${ENABLE_INSIGHTS}

# Pass 5 — Polly
enable_polly         = ${ENABLE_POLLY}
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

if [[ -n "$PRESERVED" ]]; then
  # Quoted delimiter and a literal printf: these lines come out of a file on
  # disk and are never expanded on the way through.
  cat >> "$OUTPUT" << 'TFVARS'

#------------------------------------------------------------------------------
# Kept from your previous terraform.tfvars
# The wizard does not ask about these, so it carries them across a rewrite
# rather than dropping them. Edit or delete them by hand.
#------------------------------------------------------------------------------
TFVARS
  printf '%s' "$PRESERVED" >> "$OUTPUT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════════════

# terraform.tfvars is now the source of truth — drop the resume checkpoint so a
# later run offers to edit the real file instead of replaying stale answers.
rm -f "$STATE_FILE"

echo ""
printf "  $(_green "✔")  Written to: $(_bold "$OUTPUT")\n"
[[ -f "$OUTPUT.bak" ]] && printf "     Previous file: $(_bold "$OUTPUT.bak")\n"
if [[ -n "$PRESERVED_PARTIAL" ]]; then
  echo ""
  _yellow "  WARNING"
  printf ": these were set in the previous file, span more than one line,\n"
  printf "  and were not carried over:%s\n" "$PRESERVED_PARTIAL"
  printf "  Copy them back from %s if you still need them.\n" "$OUTPUT.bak"
fi
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
# make apply runs -auto-approve across three targeted stages, so the summary
# above is the last look at a first deployment before it is built. Deliberately
# silent on whether make plan works beforehand: that depends on whether any
# kubernetes_manifest is left in the config, which is in flux.
printf "     ${DIM}apply auto-approves. The summary above is your review.${RESET}\n"
printf "     ${DIM}Run ${RESET}${CYAN}make plan${RESET}${DIM} before any later apply.${RESET}\n"
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
