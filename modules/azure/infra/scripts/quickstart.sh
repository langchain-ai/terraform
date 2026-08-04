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
# Normalise so the paths shown to the user are plain, not infra/scripts/../...
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

# ── Resume state ──────────────────────────────────────────────────────────────
# Answers are checkpointed after every completed section so an exit (Ctrl-C,
# `q`, a dropped SSH session) never costs more than the section in progress.
# Contains configuration only — secrets are handled by setup-env.sh.

STATE_FILE="$INFRA_DIR/.quickstart-state"

_STATE_KEYS="SECTION ANSWERED PROFILE SUBSCRIPTION_ID NAME_PREFIX LOCATION OWNER
COST_CENTER CREATE_CLUSTER EXISTING_CLUSTER_NAME EXISTING_CLUSTER_RG
EXISTING_CLUSTER_POOLS_MANAGED
CREATE_VNET VNET_ID AKS_SUBNET_ID POSTGRES_SUBNET_ID REDIS_SUBNET_ID
AKS_SUBNET_CIDR_LINE POSTGRES_SUBNET_CIDR_LINE REDIS_SUBNET_CIDR_LINE
AKS_SERVICE_CIDR AGIC_SUBNET_ID BASTION_SUBNET_ID MANAGE_BYO_ENDPOINTS
NODE_VM_SIZE NODE_MIN NODE_MAX NODE_MAX_PODS INSTALL_KEDA INSTALL_CERT_MANAGER
INGRESS_CONTROLLER
ISTIO_ADDON_REVISION AGW_SKU_TIER TLS_SOURCE DNS_LABEL LANGSMITH_DOMAIN LE_EMAIL
CREATE_DNS_ZONE PG_SOURCE REDIS_SOURCE CH_SOURCE PG_ADMIN_USER PG_DB_NAME
AMR_SKU REDIS_HA KV_PURGE_PROTECTION KV_MANAGE_TF_ADMIN SIZING_PROFILE UNIQUE_NAMES
CREATE_WAF CREATE_DIAGNOSTICS CREATE_BASTION"

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
# inside the value (_common.sh's _parse_tfvar strips them).
_tfvar() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" "$OUTPUT" 2>/dev/null | head -1
}

# Read a list-valued tfvar back as its whole assignment line, which is the form
# the writer carries it in (aks_subnet_address_prefix = ["10.0.0.0/19"]).
_tfvar_line() {
  sed -n "s/^[[:space:]]*\($1[[:space:]]*=[[:space:]]*\[.*\]\)[[:space:]]*\$/\1/p" "$OUTPUT" 2>/dev/null | head -1
}

# Seed the wizard from a terraform.tfvars written by an earlier run, so a
# re-run edits the existing config instead of retyping it from scratch.
_load_tfvars() {
  local v _TF_VAL _v
  # The profile is not a tfvar — it is stamped in the header comment. Without it
  # everything derived from the profile (deletion protection, Key Vault purge
  # protection, the security add-ons) silently resets to dev values on save.
  _TF_VAL=$(sed -n 's/^# Profile:[[:space:]]*\([a-z]*\).*/\1/p' "$OUTPUT" | head -1)
  [[ "$_TF_VAL" == "prod" || "$_TF_VAL" == "dev" ]] && PROFILE="$_TF_VAL"

  # `identifier` is read before `name_prefix` so that a tfvars carrying both
  # lets the current key win. Accepting the retired key matters more here than
  # elsewhere: dropping it would leave NAME_PREFIX at its "dev" default and
  # regenerate a tfvars naming a different set of resources than the one this
  # deployment already owns. Same back-compat as _common.sh's _name_prefix.
  for v in subscription_id identifier name_prefix location owner cost_center \
           default_node_pool_vm_size ingress_controller istio_addon_revision \
           agw_sku_tier tls_certificate_source dns_label langsmith_domain \
           letsencrypt_email postgres_source redis_source clickhouse_source \
           sizing_profile postgres_admin_username postgres_database_name amr_sku; do
    _TF_VAL=$(_tfvar "$v")
    [[ -z "$_TF_VAL" ]] && continue
    case "$v" in
      subscription_id)           SUBSCRIPTION_ID="$_TF_VAL" ;;
      identifier | name_prefix)  NAME_PREFIX="${_TF_VAL#-}" ;;
      location)                  LOCATION="$_TF_VAL" ;;
      owner)                     OWNER="$_TF_VAL" ;;
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
  _TF_VAL=$(_parse_tfvar redis_high_availability)     && REDIS_HA="$_TF_VAL"
  # Absent means an existing deployment predating the hash, or one that opted
  # out. Either way it stays off — the writer must not turn it on underneath a
  # deployment whose resources are already named.
  UNIQUE_NAMES="false"
  _TF_VAL=$(_parse_tfvar unique_resource_names)       && UNIQUE_NAMES="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_vnet)                 && CREATE_VNET="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_cluster)              && CREATE_CLUSTER="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar existing_cluster_node_pools_managed) && EXISTING_CLUSTER_POOLS_MANAGED="$_TF_VAL"
  # Written only when false, since true is both the Terraform default and what
  # every create-path deploy wants, so an absent key genuinely means true.
  _TF_VAL=$(_parse_tfvar install_cert_manager)        && INSTALL_CERT_MANAGER="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar install_keda)                && INSTALL_KEDA="$_TF_VAL"
  # Re-validated on the way in, not just at the prompt. This file may have been
  # hand-edited between runs, and an invalid value would otherwise flow straight
  # back into the writer. A rejected value is dropped so section 3 re-asks.
  [[ "$CREATE_CLUSTER" == "false" ]] && {
    EXISTING_CLUSTER_NAME=$(_tfvar existing_cluster_name)
    EXISTING_CLUSTER_RG=$(_tfvar existing_cluster_resource_group_name)
    _valid_cluster_name "$EXISTING_CLUSTER_NAME" || EXISTING_CLUSTER_NAME=""
    _valid_rg_name      "$EXISTING_CLUSTER_RG"   || EXISTING_CLUSTER_RG=""
  }
  _TF_VAL=$(_parse_tfvar keyvault_purge_protection)   && KV_PURGE_PROTECTION="$_TF_VAL"
  # Written only when false. The Terraform default is null, which follows
  # create_keyvault, so an absent key has to stay absent rather than come back as
  # an explicit true — that would force the deployer's grant onto a vault the
  # customer's platform team owns. Read back because losing it re-attempts a
  # roleAssignments/write an ABAC condition on principalType may reject, which
  # fails the apply before any secret is written.
  _TF_VAL=$(_parse_tfvar keyvault_manage_terraform_admin_assignment) && KV_MANAGE_TF_ADMIN="$_TF_VAL"
  # The add-ons are written only when true, so an absent key is genuinely false.
  _TF_VAL=$(_parse_tfvar create_waf)                  && CREATE_WAF="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_diagnostics)          && CREATE_DIAGNOSTICS="$_TF_VAL"
  _TF_VAL=$(_parse_tfvar create_bastion)              && CREATE_BASTION="$_TF_VAL"
  # Written only when true, the non-default. Read back because dropping it takes
  # azapi_update_resource out of the config, and plan then requires the two
  # service endpoints to already be on a subnet Terraform no longer maintains.
  _TF_VAL=$(_parse_tfvar manage_byo_subnet_service_endpoints) && MANAGE_BYO_ENDPOINTS="$_TF_VAL"
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
    # Same re-validation as the two cluster fields above, for the same reason:
    # these reach the writer without passing a prompt. A dropped ID re-asks in
    # section 3, or fails at terraform plan — either beats emitting it unchecked.
    for _v in AKS_SUBNET_ID POSTGRES_SUBNET_ID REDIS_SUBNET_ID \
              AGIC_SUBNET_ID BASTION_SUBNET_ID; do
      if [[ -n "${!_v}" ]] && ! _valid_subnet_id "${!_v}"; then
        _red "  Ignoring malformed $_v in terraform.tfvars."
        eval "$_v="
      fi
    done
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
OWNER="platform-team"
COST_CENTER=""

_run_section_2() {
  _section "2. Subscription & Naming"
  _hint "The deployment name is appended to every Azure resource name (RG, AKS, KV, blob...)"
  _hint "and becomes the 'environment' tag. Write it without a hyphen — we add the separator."
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
      break
    fi
    _red "  ERROR: must be lowercase alphanumerics separated by single hyphens (e.g. prod, dev-dz), or \"none\" for no suffix. No trailing or doubled hyphen."
  done

  # Section 3 reads the region off an attached cluster, and it is not a choice
  # once it has: LangSmith's private endpoints have to sit in the region of the
  # subnet holding them. Re-entering this section from the review menu would
  # otherwise be a way to set a region that fails at apply. Empty on a first
  # pass, since section 3 has not run yet.
  if [[ -n "$_AKS_LOCATION" ]]; then
    LOCATION="$_AKS_LOCATION"
    _hint "Azure region: ${LOCATION} — fixed by ${EXISTING_CLUSTER_NAME}, the cluster you are attaching to."
  else
    _ask "Azure region" "$LOCATION"
    LOCATION="$_REPLY"
  fi

  _ask "Owner tag (team or person, for cost attribution)" "$OWNER"
  OWNER="$_REPLY"

  _ask "Cost center tag (leave blank to skip)" "$COST_CENTER"
  COST_CENTER="$_REPLY"

  echo ""
  printf "  Resources: ls-{resource}$(_cyan "${NAME_PREFIX:+-$NAME_PREFIX}")  in  $(_cyan "$LOCATION")\n"
}

# -- 3. Cluster & Networking -------------------------------------------------
# Both cluster defaults match the Terraform variable defaults, so an unanswered
# section 3 generates the same config the module would assume on its own.
CREATE_CLUSTER="true"
EXISTING_CLUSTER_NAME=""
EXISTING_CLUSTER_RG=""
EXISTING_CLUSTER_POOLS_MANAGED="false"
CREATE_VNET="true"
VNET_ID=""
# Matches the Terraform default. Only meaningful with a supplied AKS subnet, where
# turning it on has Terraform add the Microsoft.Storage and Microsoft.KeyVault
# service endpoints the storage and Key Vault firewalls need.
MANAGE_BYO_ENDPOINTS="false"
AKS_SUBNET_ID=""
POSTGRES_SUBNET_ID=""
REDIS_SUBNET_ID=""
AKS_SUBNET_CIDR_LINE=""
POSTGRES_SUBNET_CIDR_LINE=""
REDIS_SUBNET_CIDR_LINE=""
AKS_SERVICE_CIDR=""

# Azure's documented name shapes for the bring-your-own cluster inputs. Both
# values are interpolated into double-quoted HCL by the writer, so a value
# carrying a quote, a newline, or an HCL ${...} sequence could close the string
# early and append Terraform configuration that then applies with the deploying
# identity's credentials. Whitelisting the character set removes that, and it
# catches a typo at the prompt instead of at terraform plan.
#
# Both are applied twice: once where the operator types, and again in
# _load_tfvars, because a terraform.tfvars from an earlier run is read back with
# sed and would otherwise reach the writer having never seen a prompt.
_valid_cluster_name() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9_-]{0,61}[a-zA-Z0-9])?$ ]]; }
_valid_rg_name()      { [[ "$1" =~ ^[a-zA-Z0-9._()-]{0,89}[a-zA-Z0-9_()-]$ ]]; }

# A subnet resource ID, same shape and same case-insensitive comparison as the
# VNet ID below. Azure returns "resourcegroups" in some contexts and
# "resourceGroups" in others, and bash 3.2 has no ${var,,}, so lowercase a copy.
_valid_subnet_id() {
  local lc
  lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$lc" =~ ^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.network/virtualnetworks/[^/]+/subnets/[^/]+$ ]]
}

# An IPv4 CIDR, the only form the three *_subnet_address_prefix variables are
# ever written with. Shape only: an out-of-range octet still fails at plan, where
# Terraform's own message is clear. Checked here for the reason the IDs are —
# it lands in double-quoted HCL, and none of the three variables carries a
# validation block, so an empty or typo'd answer otherwise surfaces as a cidr
# function error several steps later.
_valid_cidr() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]
}

# Ask for one subnet in bring-your-own-VNet mode, either reusing one that exists
# or having Terraform carve it out of the VNet. Sets _SUBNET_ID (reuse) or
# _SUBNET_CIDR_LINE (carve), and never both — the writer reads the pair that way.
#
# required = "required" makes the ID mandatory and drops the carve branch.
# Used for the AKS subnet when attaching to an existing cluster, where Terraform
# cannot carve the subnet: it has to be one the cluster already runs nodes in.
#
# cur_id and cur_cidr_line are this subnet's current answers. Both are offered
# back, so re-entering the section from the review menu confirms what is already
# configured rather than starting the question over. Passing them is not optional
# polish: without cur_id, Enter on a re-entered section used to read as "I have
# no subnet", which silently moved the subnet from one Terraform reuses to one it
# creates. cur_id doubles as the prefill for an ID read off an attached cluster.
_ask_subnet() {
  local label="$1" cidr_var="$2" default_cidr="$3" note="$4" required="${5:-}" \
        cur_id="${6:-}" cur_cidr_line="${7:-}"
  _SUBNET_ID=""
  _SUBNET_CIDR_LINE=""
  echo ""
  _hint "$note"

  # Which of the two this is used to be a blank Enter on the ID prompt, with the
  # carve branch named only in a parenthetical. That hid it both ways: an
  # operator without an ID to hand pressed Enter and Terraform began carving a
  # subnet inside a VNet a network team may own, and an operator who did have
  # subnets provisioned had no sign they could be reused. Ask it outright.
  # No default on a first pass, deliberately: carving a subnet inside a VNet a
  # network team owns and reusing one they already provisioned are not equally
  # safe guesses, and section 1 already requires an explicit answer the same way.
  # A re-entered section pre-selects whichever is configured.
  local choice_default=""
  if [[ -n "$cur_id" ]]; then
    choice_default="1"
  elif [[ -n "$cur_cidr_line" ]]; then
    choice_default="2"
  fi

  # The carve branch returns from inside the loop; a reuse answer with no ID
  # comes back here to re-ask, since a blank is no longer a way to pick carve.
  local mode="1"
  while true; do
    if [[ "$required" != "required" ]]; then
      _ask_choice --default "$choice_default" \
        "The ${label} subnet — reuse an existing one, or have Terraform create it?" \
        "Reuse a subnet that already exists in your VNet (you paste its resource ID)" \
        "Terraform creates it inside your VNet (you pick a CIDR)"
      mode="$_CHOICE"
    fi

    if [[ "$mode" == "2" ]]; then
      # Offered back on a re-entered section for the same reason the ID is: a
      # re-defaulted prefix would move the subnet on the next apply. The stored
      # form is the whole assignment line, so unwrap it back to the CIDR.
      local cidr_default="$default_cidr" cur=""
      if [[ -n "$cur_cidr_line" ]]; then
        # aks_subnet_address_prefix = ["10.0.0.0/19"] -> 10.0.0.0/19. Cut on the
        # quotes, not the bracket, which would open a pattern character class.
        cur="${cur_cidr_line#*\"}"
        cur="${cur%%\"*}"
        if _valid_cidr "$cur"; then cidr_default="$cur"; fi
      fi
      while true; do
        _ask "CIDR for the new ${label} subnet" "$cidr_default"
        if _valid_cidr "$_REPLY"; then break; fi
        _red "  ERROR: expected an IPv4 CIDR, e.g. ${default_cidr:-10.0.32.0/20}."
        echo ""
      done
      # Padded so the three prefix lines line up with each other in the tfvars.
      _SUBNET_CIDR_LINE="$(printf '%-30s = ["%s"]' "$cidr_var" "$_REPLY")"
      return
    fi

    while true; do
      _ask "${label} subnet resource ID" "$cur_id"
      _SUBNET_ID="$_REPLY"
      if [[ -z "$_SUBNET_ID" ]]; then
        if [[ "$required" == "required" ]]; then
          _red "  ERROR: required on this path — Terraform cannot create this subnet."
          echo ""
          continue
        fi
        _red "  ERROR: no ID given. Answer 2 above to have Terraform create this subnet."
        echo ""
        break
      fi
      _valid_subnet_id "$_SUBNET_ID" && return
      _red "  ERROR: expected /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<name>"
      echo ""
    done
  done
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

# Read off the attached cluster in section 3, then used by sections 2 and 3.
# Never checkpointed: they describe the cluster, not a decision the operator
# made, so a resumed run reads them again rather than trusting a stale copy.
_AKS_LOCATION=""
_AKS_SUBNET_IDS=()
_AKS_PREFILL_SUBNET=""

# Reads the cluster the operator just named and keeps what Azure already knows:
# the region it runs in and the subnet each of its node pools sits in. Leaves
# both empty when az or python3 is missing, the login has expired, or the
# cluster is not there, so every caller falls back to asking.
#
# Every value Azure hands back goes through the validator a typed value gets.
# These end up interpolated into double-quoted HCL in terraform.tfvars, and a
# remote API is a remote input channel — the fact that it is not the keyboard
# earns it nothing. A value that fails is dropped rather than repaired, which
# leaves the operator at the prompt they would have seen anyway.
_lookup_existing_cluster() {
  _AKS_LOCATION=""
  _AKS_SUBNET_IDS=()
  local json parsed line first=1

  command -v az &>/dev/null || return 0
  json=$(az aks show --name "$EXISTING_CLUSTER_NAME" \
                     --resource-group "$EXISTING_CLUSTER_RG" \
                     --output json 2>/dev/null) || return 0
  [[ -n "$json" ]] || return 0

  # Region on the first line, then one subnet ID per pool, deduplicated. Pools
  # on an AKS-managed VNet carry no vnetSubnetId at all and contribute nothing.
  parsed=$(printf '%s' "$json" | python3 -c '
import json, sys

try:
    c = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
if not isinstance(c, dict):
    sys.exit(0)

subnets = []
for p in c.get("agentPoolProfiles") or []:
    s = p.get("vnetSubnetId")
    if s and s not in subnets:
        subnets.append(s)
print("\n".join([c.get("location") or ""] + subnets))
' 2>/dev/null) || return 0

  while IFS= read -r line; do
    if [[ "$first" == 1 ]]; then
      first=0
      # Azure region names are lowercase alphanumeric, "eastus2".
      [[ "$line" =~ ^[a-z0-9]+$ ]] && _AKS_LOCATION="$line"
      continue
    fi
    # An ID offered as a prompt default has to be one _ask would accept. The
    # subnet-ID shape allows these four characters inside a segment and _ask
    # refuses them, which would leave Enter re-erroring on its own default.
    [[ "$line" =~ [\`\$\!\\] ]] && continue
    # An `if` rather than `&&`: a failing test as the last command in the loop
    # body would trip errexit and take the wizard down over a subnet ID it is
    # supposed to be discarding.
    if _valid_subnet_id "$line"; then
      _AKS_SUBNET_IDS+=("$line")
    fi
  done <<<"$parsed"
}

_run_section_3() {
  _section "3. Cluster & Networking"

  # Asked before the VNet question because the answer constrains it. Attaching to
  # an existing cluster forces an existing VNet: aks_subnet_id has to be a subnet
  # that cluster already runs nodes in, and a subnet Terraform is about to carve
  # never is.
  _hint "LangSmith can create its own AKS cluster, or deploy onto one you already run."
  _hint "Attaching leaves your cluster's lifecycle with your platform team — Terraform"
  _hint "reads it and never creates, modifies, or destroys it."
  echo ""

  if _ask_yn "Create a new AKS cluster? (recommended)" "$(_yn_default "$CREATE_CLUSTER")"; then
    CREATE_CLUSTER="true"
    EXISTING_CLUSTER_NAME=""
    EXISTING_CLUSTER_RG=""
    EXISTING_CLUSTER_POOLS_MANAGED="false"
    # A cluster Terraform is about to create runs neither component yet, and
    # sections 4 and 6 stop asking, so restore both rather than carry an answer
    # about a cluster no longer being attached into the new one's config.
    INSTALL_KEDA="true"
    INSTALL_CERT_MANAGER="true"
    # Drop anything read off a cluster on an earlier pass. Left set, section 2
    # would still call the region fixed by a cluster no longer being attached.
    _AKS_LOCATION=""
    _AKS_SUBNET_IDS=()
    _AKS_PREFILL_SUBNET=""
  else
    CREATE_CLUSTER="false"
    echo ""
    _hint "Your cluster needs, before you continue: the OIDC issuer and Workload"
    _hint "Identity both enabled, local accounts NOT disabled, a network policy"
    _hint "engine, and an API server reachable from this host."
    _hint "  az aks update --name <cluster> --resource-group <rg> \\"
    _hint "    --enable-oidc-issuer --enable-workload-identity"
    echo ""

    while true; do
      _ask "Existing AKS cluster name" "$EXISTING_CLUSTER_NAME"
      EXISTING_CLUSTER_NAME="$_REPLY"
      _valid_cluster_name "$EXISTING_CLUSTER_NAME" && break
      _red "  ERROR: 1-63 characters, letters/numbers/hyphens/underscores, starting and ending alphanumeric."
      echo ""
    done

    while true; do
      _ask "Resource group holding that cluster" "$EXISTING_CLUSTER_RG"
      EXISTING_CLUSTER_RG="$_REPLY"
      _valid_rg_name "$EXISTING_CLUSTER_RG" && break
      _red "  ERROR: 1-90 characters, letters/numbers/period/underscore/hyphen/parentheses, not ending in a period."
      echo ""
    done

    # Azure already holds the answers to the next few questions: the region the
    # cluster runs in, its VNet, and the subnet its nodes sit in. Read them
    # rather than ask for a paste. A subnet ID naming the wrong network still
    # matches the regex, and this one ID drives the Blob and Key Vault firewall
    # allowlists, so that typo opens both to a network LangSmith never runs in.
    _AKS_PREFILL_SUBNET=""
    _lookup_existing_cluster

    if [[ -z "$_AKS_LOCATION" && ${#_AKS_SUBNET_IDS[@]} -eq 0 ]]; then
      echo ""
      _hint "Could not read ${EXISTING_CLUSTER_NAME} from Azure. Check 'az login' and the"
      _hint "two names above — the network questions below then have to be answered by hand."
    fi

    # The cluster's region wins over the answer in section 2. Every private
    # endpoint LangSmith creates has to sit in the region of the subnet holding
    # it, so a mismatch here is an apply failure several minutes in.
    if [[ -n "$_AKS_LOCATION" && "$_AKS_LOCATION" != "$LOCATION" ]]; then
      echo ""
      _hint "Region changed from ${LOCATION} to ${_AKS_LOCATION}, where ${EXISTING_CLUSTER_NAME} runs."
      _hint "LangSmith's private endpoints have to sit in the same region as the subnet"
      _hint "holding them, so ${LOCATION} would have failed at apply."
      LOCATION="$_AKS_LOCATION"
    fi

    if [[ ${#_AKS_SUBNET_IDS[@]} -eq 1 ]]; then
      _AKS_PREFILL_SUBNET="${_AKS_SUBNET_IDS[0]}"
    elif [[ ${#_AKS_SUBNET_IDS[@]} -gt 1 ]]; then
      # Pools spread across subnets is normal on a cluster a platform team runs.
      # One ID goes into tfvars and it sets the storage and Key Vault
      # allowlists, so it has to be the subnet LangSmith's own pods land in.
      echo ""
      _hint "This cluster's node pools span several subnets. Pick the one LangSmith's pods"
      _hint "will run in — that choice sets the Blob and Key Vault firewall allowlists."
      # Pre-selects the subnet already in tfvars when this section is re-entered.
      # Empty when there is none, which _ask_choice reads as no default.
      _ask_choice --default "$(_index_of "$AKS_SUBNET_ID" "${_AKS_SUBNET_IDS[@]}")" \
        "Which subnet do LangSmith's pods run in?" "${_AKS_SUBNET_IDS[@]}"
      _AKS_PREFILL_SUBNET="${_AKS_SUBNET_IDS[$((_CHOICE - 1))]}"
    fi

    # The VNet is the subnet ID minus its /subnets/<name> tail. Deriving it beats
    # a second lookup: it cannot end up naming a VNet the chosen subnet is not in.
    [[ -n "$_AKS_PREFILL_SUBNET" ]] && VNET_ID="${_AKS_PREFILL_SUBNET%/subnets/*}"

    # 'istio-addon' is configured through arguments on the azurerm_kubernetes_cluster
    # resource, which does not exist in state on this path, so it would silently
    # never apply. Reset it here as section 5 does for AGIC.
    if [[ "$INGRESS_CONTROLLER" == "istio-addon" ]]; then
      INGRESS_CONTROLLER="nginx"
      ISTIO_ADDON_REVISION=""
      echo ""
      _red "  The Istio add-on needs a Terraform-created cluster — ingress controller reset to nginx."
    fi
  fi

  echo ""
  _hint "Most deployments use a new VNet — Terraform manages address space and subnets."
  _hint "Choose 'existing VNet' only if you're integrating into a corporate network"
  _hint "where network teams manage VNets centrally."

  # Only a real question when Terraform owns the cluster. Attaching pins it.
  if [[ "$CREATE_CLUSTER" == "false" ]]; then
    CREATE_VNET="false"
    echo ""
    _hint "Attaching to an existing cluster means using its VNet, so the questions"
    _hint "below cover the network your cluster already runs in."
    [[ -n "$_AKS_PREFILL_SUBNET" ]] && \
      _hint "The VNet and node subnet were read off ${EXISTING_CLUSTER_NAME} — press Enter to accept."
  elif _ask_yn "Create a new VNet? (recommended)" "$(_yn_default "$CREATE_VNET")"; then
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
  _hint "For each subnet below, choose whether to reuse one that already exists or"
  _hint "have Terraform create it inside your VNet with the settings that service"
  _hint "needs. Reusing takes the subnet's resource ID; creating takes a CIDR."
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

  # Terraform can carve this one only when it owns the cluster. Attached to an
  # existing cluster it has to be a subnet that cluster already runs nodes in,
  # because the same ID drives the Blob and Key Vault firewall allowlists.
  if [[ "$CREATE_CLUSTER" == "false" ]]; then
    # The ID read off the cluster when the lookup worked, otherwise whatever is
    # already configured. Falling back matters on a re-entered section: a lookup
    # that failed this time (expired login) would otherwise blank an ID that a
    # successful lookup, or the operator, had already established.
    _ask_subnet "AKS node" "aks_subnet_address_prefix" "" \
      "The subnet your cluster's nodes already run in. It needs the Microsoft.Storage and Microsoft.KeyVault service endpoints, and room for (max_count + 1) x (max_pods + 1) addresses." \
      required "${_AKS_PREFILL_SUBNET:-$AKS_SUBNET_ID}"
  else
    _ask_subnet "AKS" "aks_subnet_address_prefix" "10.0.0.0/19" \
      "Holds AKS node and pod IPs (Azure CNI). An existing subnet needs the Microsoft.Storage and Microsoft.KeyVault service endpoints." \
      "" "$AKS_SUBNET_ID" "$AKS_SUBNET_CIDR_LINE"
  fi
  AKS_SUBNET_ID="$_SUBNET_ID"; AKS_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  _ask_subnet "PostgreSQL" "postgres_subnet_address_prefix" "10.0.32.0/20" \
    "An existing subnet must already be delegated to Microsoft.DBforPostgreSQL/flexibleServers and contain nothing else. A new one gets that delegation automatically." \
    "" "$POSTGRES_SUBNET_ID" "$POSTGRES_SUBNET_CIDR_LINE"
  POSTGRES_SUBNET_ID="$_SUBNET_ID"; POSTGRES_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  _ask_subnet "Redis" "redis_subnet_address_prefix" "10.0.48.0/20" \
    "Holds the Azure Managed Redis private endpoint. This subnet must NOT be delegated — a delegated subnet would reject the endpoint." \
    "" "$REDIS_SUBNET_ID" "$REDIS_SUBNET_CIDR_LINE"
  REDIS_SUBNET_ID="$_SUBNET_ID"; REDIS_SUBNET_CIDR_LINE="$_SUBNET_CIDR_LINE"

  # Kubernetes ClusterIPs are internal to the cluster, but AKS still requires the
  # range to be unused by anything on or connected to the VNet. The default only
  # dodges the VNet Terraform builds, so on this path the operator must name one.
  #
  # Asked only when Terraform creates the cluster. The range is fixed on the
  # cluster at creation, so an existing cluster keeps whatever Azure gave it and
  # an answer here would configure nothing. Cleared on that path so the review
  # screen and the tfvars writer both skip it.
  if [[ "$CREATE_CLUSTER" == "true" ]]; then
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
  else
    AKS_SERVICE_CIDR=""
  fi

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
# Matches the Terraform default. Only ever turned off on the attach path, where
# the cluster may already run KEDA.
INSTALL_KEDA="true"

_run_section_4() {
  _section "4. AKS Cluster"

  if [[ "$CREATE_CLUSTER" == "false" ]]; then
    # The default-pool sizing variables live inside the cluster resource, which is
    # counted off when attaching, and the subnet capacity check no longer counts a
    # default pool Terraform will not create. So they configure nothing here and
    # asking would only invite the operator to describe pools that go unread.
    _hint "Attached to ${EXISTING_CLUSTER_NAME}. Terraform never creates or resizes its"
    _hint "default node pool, so node size and count are not asked here: they would"
    _hint "configure nothing, and the subnet check does not count them."
    echo ""
    _hint "Terraform can still add a 'large' pool (Standard_D16s_v3) for ClickHouse and"
    _hint "LangGraph. Declining leaves every pool with your platform team, and the"
    _hint "cluster then needs that capacity already."
    if _ask_yn "Let Terraform manage node pools on this cluster?" \
               "$(_yn_default "$EXISTING_CLUSTER_POOLS_MANAGED")"; then
      EXISTING_CLUSTER_POOLS_MANAGED="true"
    else
      EXISTING_CLUSTER_POOLS_MANAGED="false"
    fi
    echo ""

    # Asked only on this path. Helm will not adopt a release it does not own, so
    # installing over one that is already there fails on the CRDs already
    # registered, partway through an apply that has built Azure resources.
    # The question is phrased about their cluster, not about the flag, so the
    # default reads as "no" for the common case of a cluster without it.
    _hint "KEDA scales the LangSmith queue workers on Redis queue depth. Terraform"
    _hint "installs it, and something has to provide it, so answer yes only if it is"
    _hint "already running — a second install fails on KEDA's existing CRDs."
    local keda_default="n"
    [[ "$INSTALL_KEDA" == "false" ]] && keda_default="y"
    if _ask_yn "Does this cluster already run KEDA?" "$keda_default"; then
      INSTALL_KEDA="false"
    else
      INSTALL_KEDA="true"
    fi
    echo ""
  else
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
  _hint "agic        — Azure Application Gateway; enterprise WAF built-in, but requires a"
  _hint "              dedicated /24 subnet in a Terraform-managed VNet."
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

    # Both add-ons are set through arguments on the azurerm_kubernetes_cluster
    # resource, which is absent from state when attaching, so they would apply to
    # nothing at all rather than erroring.
    if [[ "$INGRESS_CONTROLLER" == "istio-addon" && "$CREATE_CLUSTER" == "false" ]]; then
      _red "  The Istio add-on is not available on a cluster Terraform did not create."
      echo ""
      _hint "It is an AKS-managed add-on, settable only through a cluster resource"
      _hint "Terraform owns. Pick 'istio' to install it with Helm instead, or nginx"
      _hint "or envoy-gateway."
      continue
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
    _hint "Note: AGIC requires a full cluster rebuild to enable (the add-on is part of the"
    _hint "cluster resource). With a VNet you own, supply the Application Gateway subnet."
  fi
}

# -- 6. DNS + TLS ------------------------------------------------------------
TLS_SOURCE="none"
DNS_LABEL=""
LANGSMITH_DOMAIN=""
LE_EMAIL=""
CREATE_DNS_ZONE="false"
# Asked here rather than with the cluster, because cert-manager is what issues
# the certificate on both ACME paths. Answering it in the same section as the TLS
# source keeps the one pair Terraform refuses (dns01 without it) from being
# assembled by visiting two sections in the wrong order.
INSTALL_CERT_MANAGER="true"

# Suggests langsmith-<name_prefix> but still asks, because the DNS label lives in
# a namespace shared with every other Azure tenant in the region: the FQDN
# <label>.<region>.cloudapp.azure.com must be unique region-wide, so a derived
# name can be taken by someone else. Same class of collision as the Key Vault
# name. Asking here means the operator picks a free one instead of hitting
# DnsRecordCreateConflict at apply.
_ask_dns_label() {
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

  # Asked before the TLS source, because the answer rules one of the four out.
  if [[ "$CREATE_CLUSTER" == "false" ]]; then
    echo ""
    _hint "cert-manager issues the certificates on the Let's Encrypt and DNS-01 paths."
    _hint "Terraform installs it, and Helm will not adopt a release it does not own, so"
    _hint "a second install fails on cert-manager's existing CRDs."
    local cm_default="n"
    [[ "$INSTALL_CERT_MANAGER" == "false" ]] && cm_default="y"
    if _ask_yn "Does this cluster already run cert-manager?" "$cm_default"; then
      INSTALL_CERT_MANAGER="false"
    else
      INSTALL_CERT_MANAGER="true"
    fi
    echo ""
  fi

  local tls_choice=""
  _answered 6 && tls_choice="$(_index_of "$TLS_SOURCE" none letsencrypt dns01 existing)"
  _ask_choice --default "$tls_choice" \
    "TLS certificate source:" \
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
  #
  # This first one has no "continue anyway", unlike the two below it: Terraform
  # rejects the pair at plan, so there is no apply to continue to. TLS_SOURCE is
  # cleared before re-asking so that Enter cannot re-pick the value just refused —
  # with no default, section 6 requires an explicit answer.
  if [[ "$TLS_SOURCE" == "dns01" && "$INSTALL_CERT_MANAGER" == "false" ]]; then
    echo ""
    _yellow "⚠  DNS-01 requires the cert-manager Terraform installs."
    printf "   The DNS-01 solver authenticates to the Azure DNS API as a Managed Identity,\n"
    printf "   bound to the cert-manager pod by an annotation Terraform adds to the service\n"
    printf "   account of the release it creates. The cert-manager already in your cluster\n"
    printf "   has no such annotation, so every ACME challenge fails on an Azure auth error.\n"
    printf "   Options for a cluster that already runs cert-manager: none, letsencrypt, existing\n"
    printf "   (letsencrypt uses HTTP-01, which needs no Azure credential and works through\n"
    printf "   any cert-manager.)\n"
    echo ""
    TLS_SOURCE=""
    _run_section_6
    return
  fi

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

    local dns_choice=""
    _answered 6 && { [[ -n "$LANGSMITH_DOMAIN" ]] && dns_choice=2 || dns_choice=1; }
    _ask_choice --default "$dns_choice" \
      "DNS approach:" \
      "Azure public IP DNS label — simplest, free subdomain" \
      "Custom domain — your own domain (required for DNS-01)"

    if [[ "$_CHOICE" == "1" ]]; then
      LANGSMITH_DOMAIN=""
      _ask_dns_label
    else
      DNS_LABEL=""
      _hint "Example: langsmith.mycompany.com or azurelangsmith.mycompany.com"
      _ask "Custom domain" "$LANGSMITH_DOMAIN"
      LANGSMITH_DOMAIN="$_REPLY"
    fi

    _hint "Let's Encrypt requires an email for your ACME account (cert expiry notifications)."
    _ask "Email for Let's Encrypt / ACME registration" "$LE_EMAIL"
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
AMR_SKU="Balanced_B1"
REDIS_HA="false"

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
  _hint "ClickHouse  — always in-cluster for self-hosted (single StatefulSet, no backups)."
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
      # Profile defaults apply only on a first pass, same rule as the pg_yn and
      # redis_yn defaults above. Re-entering the section keeps what the last run
      # wrote, so a resume does not walk an operator's Balanced_B5 back to B3.
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

  # Without this prompt every quickstart deployment silently took the Balanced_B0
  # module default, which some regions cannot allocate.
  if [[ "$REDIS_SOURCE" == "external" ]]; then
    echo ""
    _hint "Azure Managed Redis SKU. Balanced_B0 is the smallest; bump to Balanced_B1/B3"
    _hint "if the region reports AllocationFailed."
    _ask "Azure Managed Redis SKU" "$AMR_SKU"
    AMR_SKU="$_REPLY"
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
}

# -- 8. Key Vault ------------------------------------------------------------
KV_PURGE_PROTECTION="false"
# true is what this module has always done and what every deployment wants where
# the deployer is allowed to create the grant at all, so it is only written to
# tfvars when the operator turns it off.
KV_MANAGE_TF_ADMIN="true"

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

  # Asked on both profiles, because the subscription policy that makes the answer
  # "no" has nothing to do with dev versus prod. Terraform writes ~10 secrets
  # through the data plane, and Owner and Contributor grant no data-plane access
  # on an RBAC-enabled vault, so something has to create this grant.
  echo ""
  _hint "Terraform normally grants itself 'Key Vault Secrets Officer' so it can write"
  _hint "the LangSmith secrets into the vault."
  _hint ""
  _hint "Answer no only if your subscription refuses role assignments for users — some"
  _hint "delegate Microsoft.Authorization/roleAssignments/write through a condition that"
  _hint "permits only service principals, and an interactive 'az login' is a user. A"
  _hint "tenant admin then has to grant it before you apply, or the secret writes 403."
  local kv_admin_yn="y"
  _answered 8 && kv_admin_yn="$(_yn_default "$KV_MANAGE_TF_ADMIN")"
  if _ask_yn "Let Terraform create its own Key Vault Secrets Officer grant?" "$kv_admin_yn"; then
    KV_MANAGE_TF_ADMIN="true"
  else
    KV_MANAGE_TF_ADMIN="false"
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
# Runs here, after every section default has been initialised above, so loaded
# answers are not overwritten by the initialisers.

TOTAL_SECTIONS=10
SECTION=1

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
    "Start fresh — ignore it and answer every question again (overwrites on save)" \
    "Quit        — leave it untouched"
  case "$_CHOICE" in
    1) _load_tfvars
       ANSWERED="1 2 3 4 5 6 7 8 9 10"
       printf "  Loaded existing values. Press Enter at a prompt to keep the current answer.\n" ;;
    2) : ;;
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
  printf "  %-24s %s\n" "3. AKS cluster:"     "$( [[ "$CREATE_CLUSTER" == "true" ]] && echo "new (Terraform-created)" || echo "existing (attach)" )"
  if [[ "$CREATE_CLUSTER" == "false" ]]; then
    printf "  %-24s %s\n" "   Cluster name:"      "$EXISTING_CLUSTER_NAME"
    printf "  %-24s %s\n" "   Its resource group:" "$EXISTING_CLUSTER_RG"
    printf "  %-24s %s\n" "   Terraform-managed pools:" "$EXISTING_CLUSTER_POOLS_MANAGED"
  fi
  printf "  %-24s %s\n" "   VNet:"            "$( [[ "$CREATE_VNET" == "true" ]] && echo "new (auto-created)" || echo "existing" )"
  if [[ "$CREATE_VNET" == "false" ]]; then
    printf "  %-24s %s\n" "   VNet ID:"           "$VNET_ID"
    printf "  %-24s %s\n" "   AKS subnet:"        "$(_subnet_review "$AKS_SUBNET_ID" "$AKS_SUBNET_CIDR_LINE")"
    printf "  %-24s %s\n" "   PostgreSQL subnet:" "$(_subnet_review "$POSTGRES_SUBNET_ID" "$POSTGRES_SUBNET_CIDR_LINE")"
    printf "  %-24s %s\n" "   Redis subnet:"      "$(_subnet_review "$REDIS_SUBNET_ID" "$REDIS_SUBNET_CIDR_LINE")"
    [[ -n "$AKS_SERVICE_CIDR" ]]  && printf "  %-24s %s\n" "   Service CIDR:"   "$AKS_SERVICE_CIDR"
    [[ -n "$AGIC_SUBNET_ID" ]]    && printf "  %-24s %s\n" "   AGIC subnet:"    "reuse   $AGIC_SUBNET_ID"
    [[ -n "$BASTION_SUBNET_ID" ]] && printf "  %-24s %s\n" "   Bastion subnet:" "reuse   $BASTION_SUBNET_ID"
  fi
  printf "  %-24s %s\n" "4. Node size:"       "$NODE_VM_SIZE  min=$NODE_MIN  max=$NODE_MAX  max_pods=$NODE_MAX_PODS"
  # Shown only when off, which is the answer worth re-reading before an apply:
  # something other than Terraform has to be providing the component.
  [[ "$INSTALL_KEDA" == "false" ]] && printf "  %-24s %s\n" "   KEDA:" "already in the cluster, not installed"
  printf "  %-24s %s\n" "5. Ingress:"         "$INGRESS_CONTROLLER"
  [[ -n "$ISTIO_ADDON_REVISION" ]] && printf "  %-24s %s\n" "   Istio revision:"  "$ISTIO_ADDON_REVISION"
  [[ -n "$AGW_SKU_TIER" ]]         && printf "  %-24s %s\n" "   AGW SKU:"         "$AGW_SKU_TIER"
  printf "  %-24s %s\n" "6. TLS:"             "$TLS_SOURCE"
  [[ "$INSTALL_CERT_MANAGER" == "false" ]] && printf "  %-24s %s\n" "   cert-manager:" "already in the cluster, not installed"
  [[ -n "$DNS_LABEL" ]]         && printf "  %-24s %s\n" "   DNS label:"   "${DNS_LABEL}.${LOCATION}.cloudapp.azure.com"
  [[ -n "$LANGSMITH_DOMAIN" ]] && printf "  %-24s %s\n" "   Domain:"       "$LANGSMITH_DOMAIN"
  [[ -n "$LE_EMAIL" ]]         && printf "  %-24s %s\n" "   ACME email:"   "$LE_EMAIL"
  printf "  %-24s %s\n" "7. PostgreSQL:"      "$PG_SOURCE"
  printf "  %-24s %s\n" "   Redis:"           "$REDIS_SOURCE"
  printf "  %-24s %s\n" "   ClickHouse:"      "$CH_SOURCE"
  printf "  %-24s %s\n" "8. KV purge prot.:"  "$KV_PURGE_PROTECTION"
  printf "  %-24s %s\n" "   TF grants itself:" "$KV_MANAGE_TF_ADMIN"
  printf "  %-24s %s\n" "9. Sizing:"          "$SIZING_PROFILE"
  if [[ "$PROFILE" == "prod" ]]; then
    printf "  %-24s %s\n" "10. WAF:"            "$CREATE_WAF"
    printf "  %-24s %s\n" "    Log Analytics:"  "$CREATE_DIAGNOSTICS"
    printf "  %-24s %s\n" "    Bastion:"        "$CREATE_BASTION"
  fi
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

cat > "$OUTPUT" << TFVARS
# Generated by quickstart.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Profile: ${PROFILE}

#------------------------------------------------------------------------------
# Subscription & Identity
#------------------------------------------------------------------------------
subscription_id = "${SUBSCRIPTION_ID}"
name_prefix     = "${NAME_PREFIX}"
location        = "${LOCATION}"
# environment tag defaults to name_prefix. Uncomment to tag it differently:
# environment   = "${NAME_PREFIX}"

# Per-subscription hash on the globally-unique names (Postgres, Redis, Storage,
# Key Vault) so they cannot collide with another LangSmith deployment.
unique_resource_names = ${UNIQUE_NAMES}
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
TFVARS
  # A subnet ID reuses an existing subnet; its absence plus a CIDR tells
  # Terraform to create that subnet inside the VNet above.
  [[ -n "$AKS_SUBNET_ID" ]]      && echo "aks_subnet_id      = \"${AKS_SUBNET_ID}\"" >> "$OUTPUT"
  # Written only when true, the non-default, and only alongside the subnet it acts
  # on. Terraform then adds the Microsoft.Storage and Microsoft.KeyVault service
  # endpoints, which plan otherwise requires to be there already. Needs
  # Microsoft.Network/virtualNetworks/subnets/write on a subnet another team owns.
  [[ "$MANAGE_BYO_ENDPOINTS" == "true" && -n "$AKS_SUBNET_ID" ]] && \
    printf '%-30s = true\n' "manage_byo_subnet_service_endpoints" >> "$OUTPUT"
  [[ -n "$POSTGRES_SUBNET_ID" ]] && echo "postgres_subnet_id = \"${POSTGRES_SUBNET_ID}\"" >> "$OUTPUT"
  [[ -n "$REDIS_SUBNET_ID" ]]    && echo "redis_subnet_id    = \"${REDIS_SUBNET_ID}\"" >> "$OUTPUT"
  [[ -n "$AKS_SUBNET_CIDR_LINE" ]]      && echo "$AKS_SUBNET_CIDR_LINE" >> "$OUTPUT"
  [[ -n "$POSTGRES_SUBNET_CIDR_LINE" ]] && echo "$POSTGRES_SUBNET_CIDR_LINE" >> "$OUTPUT"
  [[ -n "$REDIS_SUBNET_CIDR_LINE" ]]    && echo "$REDIS_SUBNET_CIDR_LINE" >> "$OUTPUT"
  # Required when Terraform creates the cluster: the variable default is only safe
  # against the VNet Terraform builds, so plan rejects an empty value there.
  # Empty means attaching, where the range is already fixed on the cluster.
  [[ -n "$AKS_SERVICE_CIDR" ]] && printf '%-30s = "%s"\n' "aks_service_cidr" "$AKS_SERVICE_CIDR" >> "$OUTPUT"
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
TFVARS

if [[ "$CREATE_CLUSTER" == "false" ]]; then
  cat >> "$OUTPUT" << TFVARS
# Attached to a cluster this deployment does not own. Terraform reads it and
# creates the Managed Identities and federated credentials against it.
create_cluster                       = false
existing_cluster_name                = "${EXISTING_CLUSTER_NAME}"
existing_cluster_resource_group_name = "${EXISTING_CLUSTER_RG}"
existing_cluster_node_pools_managed  = ${EXISTING_CLUSTER_POOLS_MANAGED}
# The node pool settings below do not configure the attached cluster. They are
# still read, to size the AKS subnet check against the pools it actually runs.
TFVARS
fi

cat >> "$OUTPUT" << TFVARS
default_node_pool_vm_size   = "${NODE_VM_SIZE}"
default_node_pool_min_count = ${NODE_MIN}
default_node_pool_max_count = ${NODE_MAX}
default_node_pool_max_pods  = ${NODE_MAX_PODS}
TFVARS

if [[ "$INSTALL_KEDA" == "false" ]]; then
  cat >> "$OUTPUT" << 'TFVARS'
# Your cluster already runs KEDA, so Terraform does not install it. The LangSmith
# queue workers scale through that KEDA, and stop scaling if it is removed.
install_keda                = false
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

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
# Written only when false, matching the add-ons above: true is the Terraform
# default, so an omitted key means Terraform installs the component.
if [[ "$INSTALL_CERT_MANAGER" == "false" ]]; then
  cat >> "$OUTPUT" << 'TFVARS'
# Your cluster already runs cert-manager, so Terraform does not install it. On
# the letsencrypt path the ClusterIssuer is applied by helm/scripts/deploy.sh
# and reconciled by that cert-manager, so nothing renews LangSmith's certificate
# if it is ever removed.
install_cert_manager   = false
TFVARS
fi

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
TFVARS
fi

if [[ "$REDIS_SOURCE" == "external" ]]; then
  cat >> "$OUTPUT" << TFVARS

# Azure Managed Redis (Microsoft.Cache/redisEnterprise, Redis 7.x, private endpoint)
# B1 = 1 GB, B3 = 3 GB — bump if the region reports AllocationFailed.
amr_sku                 = "${AMR_SKU}"
redis_high_availability = ${REDIS_HA}
TFVARS
fi

cat >> "$OUTPUT" << TFVARS

#------------------------------------------------------------------------------
# Key Vault
#------------------------------------------------------------------------------
keyvault_purge_protection = ${KV_PURGE_PROTECTION}
TFVARS

# Written only when false, so a null keeps following create_keyvault: a vault
# Terraform creates gets the grant, a customer-owned one does not. An explicit
# true would force the deployer's grant onto a vault another team owns.
[[ "$KV_MANAGE_TF_ADMIN" == "false" ]] && cat >> "$OUTPUT" << 'TFVARS'
# Terraform does not create its own "Key Vault Secrets Officer" grant. A tenant
# admin must grant the deployer that role on the vault or its resource group
# before apply, or the secret writes below fail with 403. The pod managed
# identity's grant is unaffected and is still created: that principal is a
# service principal, and nobody can pre-grant it because the identity does not
# exist until this apply creates it.
keyvault_manage_terraform_admin_assignment = false
TFVARS

cat >> "$OUTPUT" << TFVARS

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

# terraform.tfvars is now the source of truth — drop the resume checkpoint so a
# later run offers to edit the real file instead of replaying stale answers.
rm -f "$STATE_FILE"

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
