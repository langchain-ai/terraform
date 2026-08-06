#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for Azure LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   _values_input_stamp       — tfvars values baked into values-overrides.yaml
#   _read_values_stamp <f> <k> — Read one stamped value back out
#   _name_suffix              — Resource-name suffix derived from name_prefix
#   _derive_kv_name           — Key Vault name, mirroring local.keyvault_name
#   _validate_admin_password <pw>   — Enforce the LangSmith admin password rules
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# Assumes this script lives in infra/scripts/. Consumers that live elsewhere
# should override INFRA_DIR after sourcing.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$_COMMON_DIR/..}"

# ── terraform.tfvars parser ──────────────────────────────────────────────────
_parse_tfvar() {
  local key="$1"
  local tfvars_file="${INFRA_DIR:-$(pwd)}/terraform.tfvars"
  local raw val
  raw=$(grep -E "^\s*${key}\s*=" "$tfvars_file" 2>/dev/null | head -1) || return 1
  [[ -n "$raw" ]] || return 1
  # Quoted string: key = "value"
  val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
  if [[ -z "$val" ]]; then
    # Unquoted value: key = true / key = 42 / key = {}
    val=$(echo "$raw" | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]"')
  fi
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1") || return 1
  [[ "$val" == "true" ]]
}

# ── values-overrides.yaml staleness stamp ────────────────────────────────────
# terraform.tfvars keys whose value init-values.sh bakes into
# values-overrides.yaml. That file is generated once and `make deploy` never
# regenerates it, so editing terraform.tfvars afterwards leaves Terraform and
# Helm deploying different configurations. init-values.sh writes these values
# into the generated file's header; deploy.sh reads them back and compares.
#
# Keys deploy.sh re-reads from terraform.tfvars on every run — sizing_profile and
# the enable_* flags, which select whole values files — are deliberately absent.
# Those cannot go stale, so listing them would fail a deploy that is fine.
_VALUES_INPUT_KEYS="ingress_controller tls_certificate_source postgres_source redis_source clickhouse_source langsmith_domain dns_label location"

# Emit the stamp block, one comment line per key. Stamps the raw tfvars value and
# leaves it empty when the key is absent — never the default a caller substitutes,
# so both sides of the comparison are reading the same thing.
_values_input_stamp() {
  local key val
  for key in $_VALUES_INPUT_KEYS; do
    val=$(_parse_tfvar "$key") || val=""
    printf '#   %s = %s\n' "$key" "$val"
  done
}

# Read one stamped value back out of a generated values file. Prints the value and
# returns 0 when the stamp line is present, including when the value is empty.
# Returns 1 when the file carries no stamp for that key, which is how a file
# written by an older init-values.sh is told apart from a genuine empty value.
_read_values_stamp() {
  local file="$1" key="$2" line
  line=$(grep -E "^#   ${key} =" "$file" 2>/dev/null | head -1) || return 1
  [[ -n "$line" ]] || return 1
  printf '%s' "$line" | sed "s/^#   ${key} =[[:space:]]*//"
}

# Resource-name suffix, mirroring local.name_suffix in main.tf.
# name_prefix carries no hyphen ("prod") but every derived name needs one
# ("langsmith-kv-prod"), so the separator is added here. Falls back to the
# retired `identifier` key, hyphen and all, so these scripts can still resolve
# names for a deployment whose tfvars predates the rename.
# Returns 1 when neither key is set — callers treat that as "no suffix".
_name_suffix() {
  local val
  val=$(_parse_tfvar "name_prefix") || val=$(_parse_tfvar "identifier") || return 1
  printf -- '-%s' "${val#-}"
}

# Key Vault name, mirroring local.keyvault_name in main.tf including the
# unique_resource_names hash. Four scripts need this name and each derived it
# independently before, so they all went looking for the wrong vault the moment
# the naming scheme changed. Keep this in step with main.tf.
_derive_kv_name() {
  local explicit suffix sub hash
  explicit=$(_parse_tfvar keyvault_name || true)
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return 0
  fi
  suffix=$(_name_suffix || true)
  if _tfvar_is_true unique_resource_names; then
    sub=$(_parse_tfvar subscription_id || true)
    if command -v shasum &>/dev/null; then
      hash=$(printf '%s' "${sub}${suffix}" | shasum -a 256 | cut -c1-6)
    else
      hash=$(printf '%s' "${sub}${suffix}" | sha256sum | cut -c1-6)
    fi
    echo "ls-kv${suffix}-${hash}"
  else
    echo "langsmith-kv${suffix}"
  fi
}

# ── Admin password rules ─────────────────────────────────────────────────────
# The LangSmith Helm chart's auth-bootstrap job rejects an initial org admin
# password without a symbol, and it fails ~10 minutes into the release rather
# than at the point the value was entered. Same rule set as the AWS module's
# setup-env.sh, so a password valid on one cloud is valid on the other.
#
# Prints the reason and returns 1 on failure; returns 0 silently on success.
_validate_admin_password() {
  local pw="$1" err=""

  if [[ ${#pw} -lt 12 ]]; then
    err="must be at least 12 characters long"
  elif ! printf '%s' "$pw" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
    err="must contain at least one symbol: !#\$%()+,-./:?@[\\]^_{~}"
  elif ! printf '%s' "$pw" | grep -q '[a-z]'; then
    err="must contain at least one lowercase letter"
  elif ! printf '%s' "$pw" | grep -q '[A-Z]'; then
    err="must contain at least one uppercase letter"
  fi

  if [[ -n "$err" ]]; then
    echo "Admin password is invalid — ${err}."
    return 1
  fi
}

# ── Color helpers ────────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_cyan()  { printf '\033[0;36m%s\033[0m' "$*"; }
_dim()   { printf '\033[0;90m%s\033[0m' "$*"; }

# ── Status line helpers ──────────────────────────────────────────────────────
_RESET='\033[0m'
pass()  { printf "  \033[32m✔${_RESET}  %s\n" "$1"; }
warn()  { printf "  \033[1;33m⚠${_RESET}  %s\n" "$1"; }
fail()  { printf "  \033[31m✘${_RESET}  %s\n" "$1"; }
skip()  { printf "  \033[0;90m○${_RESET}  %s\n" "$1"; }
info()  { printf "  \033[0;36mℹ${_RESET}  %s\n" "$1"; }
header(){ printf "\n\033[1m── %s ──${_RESET}\n" "$1"; }
action(){ printf "  \033[1;33m→${_RESET}  %s\n" "$1"; }
