#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for GCP LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   _set_tfvar <key> <value>  — Set one key in terraform.tfvars, editing only its line
#   _confirm <prompt>         — Yes/no prompt that defaults to no
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# Assumes this script lives in infra/scripts/. Consumers that live elsewhere
# should override INFRA_DIR after sourcing.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$_COMMON_DIR/..}"

# ── terraform.tfvars readers ─────────────────────────────────────────────────
source "$_COMMON_DIR/_tfvars.sh"

# Replace the first uncommented `key = ...` line in terraform.tfvars, or append
# one, so every other setting stays exactly as written. `cat >`, not mv, keeps
# the file permissions.
_set_tfvar() {
  local _key="$1" _value="$2" _file="$INFRA_DIR/terraform.tfvars" _tmp
  _tmp="$(mktemp)"
  if awk -v key="$_key" -v value="$_value" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print key " = " value; done = 1; next }
    { print }
    END { exit done ? 0 : 3 }
  ' "$_file" > "$_tmp"; then
    cat "$_tmp" > "$_file"
  else
    [[ -s "$_file" && -n "$(tail -c 1 "$_file")" ]] && printf '\n' >> "$_file"
    printf '%s = %s\n' "$_key" "$_value" >> "$_file"
  fi
  rm -f "$_tmp"
}

_confirm() {
  local _answer
  read -r -p "  $1 [y/N] " _answer
  [[ "$_answer" =~ ^[Yy] ]]
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
