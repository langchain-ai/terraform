#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for AWS LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _resolve_infra_dir        — Set INFRA_DIR relative to this script
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# Assumes this script lives in infra/scripts/. Consumers that live elsewhere
# (e.g. helm/scripts/) should override INFRA_DIR after sourcing.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$_COMMON_DIR/..}"

# ── terraform.tfvars parser ──────────────────────────────────────────────────
# Handles both quoted strings (key = "value") and unquoted values (key = true / key = 42).
# Returns non-zero if the key is not found.
_parse_tfvar() {
  local key="$1"
  local tfvars_file="${INFRA_DIR}/terraform.tfvars"
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

# Returns 0 if KEY = true or "true" in terraform.tfvars.
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1") || return 1
  [[ "$val" == "true" ]]
}

# ── AWS credential helpers ───────────────────────────────────────────────────
# Problem: AWS_CREDENTIAL_EXPIRATION (set by `eval $(aws configure export-credentials)`)
# poisons all subprocesses — even fresh inline credentials get rejected because the
# SDK sees the expired expiry timestamp and refuses to use them.
#
# Solution: _aws() strips the four stale env vars before every AWS call so the
# SDK falls through to ~/.aws/credentials (kept fresh by `hydrate-creds.sh`).
# All scripts in this repo use _aws instead of aws directly.
#
# The central credential file:
#   ~/.aws/credentials [default]  ← written by hydrate-creds.sh
#
# To refresh from any terminal:
#   infra/scripts/hydrate-creds.sh   (reads from awslogin / aws configure export-credentials)
#   # or with explicit values:
#   infra/scripts/hydrate-creds.sh KEY SECRET TOKEN

_AWS_STALE_VARS=(AWS_CREDENTIAL_EXPIRATION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)

_aws() {
  env "${_AWS_STALE_VARS[@]/#/-u }" aws "$@"
}

_kubectl() {
  env "${_AWS_STALE_VARS[@]/#/-u }" kubectl "$@"
}

_helm() {
  env "${_AWS_STALE_VARS[@]/#/-u }" helm "$@"
}

_terraform() {
  env "${_AWS_STALE_VARS[@]/#/-u }" terraform "$@"
}

# ── Color helpers ────────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_cyan()  { printf '\033[0;36m%s\033[0m' "$*"; }
_dim()   { printf '\033[0;90m%s\033[0m' "$*"; }

# ── Status line helpers (used by status.sh, available to all) ────────────────
_RESET='\033[0m'
pass()  { printf "  \033[32m✔${_RESET}  %s\n" "$1"; }
warn()  { printf "  \033[1;33m⚠${_RESET}  %s\n" "$1"; }
fail()  { printf "  \033[31m✘${_RESET}  %s\n" "$1"; }
skip()  { printf "  \033[0;90m○${_RESET}  %s\n" "$1"; }
info()  { printf "  \033[0;36mℹ${_RESET}  %s\n" "$1"; }
header(){ printf "\n\033[1m── %s ──${_RESET}\n" "$1"; }
action(){ printf "  \033[1;33m→${_RESET}  %s\n" "$1"; }
