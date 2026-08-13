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
#   _name_suffix              — Resource-name suffix derived from name_prefix
#   _derive_kv_name           — Key Vault name, mirroring local.keyvault_name
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
