#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for GCP LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# Assumes this script lives in infra/scripts/. Consumers that live elsewhere
# should override INFRA_DIR after sourcing.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$_COMMON_DIR/..}"

# ── terraform.tfvars parser ──────────────────────────────────────────────────
_parse_tfvar() {
  grep -E "^\s*${1}\s*=" "$INFRA_DIR/terraform.tfvars" 2>/dev/null \
    | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]'
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  local val
  val=$(grep -E "^\s*${1}\s*=" "$INFRA_DIR/terraform.tfvars" 2>/dev/null \
    | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]') || return 1
  [[ "$val" == "true" ]]
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
