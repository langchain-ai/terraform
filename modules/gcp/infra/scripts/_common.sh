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

# ── terraform.tfvars parser ──────────────────────────────────────────────────
# Values are cut at the closing quote (quoted strings, which may contain a
# literal #) or at an inline # (bare booleans and numbers). The previous
# grep/sed pair kept trailing comments, so `enable_smithdb = true  # step 9`
# compared as "true#step9" and read as false. Keep this function identical to
# the copies in helm/scripts/*.sh and infra/scripts/preflight.sh.
_parse_tfvar() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      if (substr($0, 1, 1) == "\"") { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/#.*$/, ""); gsub(/[[:space:]]+$/, "") }
      print; exit
    }
  ' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  [[ "$(_parse_tfvar "$1")" == "true" ]]
}

# gcloud --labels value for a secret the scripts create outside Terraform: the
# base pairs in $1, then owner, cost-center, and the labels map from
# terraform.tfvars, a later key replacing an earlier one as in locals.tf. A pair
# that breaks the label rules is skipped with a warning, since terraform plan
# rejects it anyway and gcloud would fail the whole create. Keep identical to
# the copy in setup-env.sh, apart from the tfvars path.
_secret_labels() {
  local _owner _cost_center
  _owner=$(_parse_tfvar "owner")
  _owner="${_owner:-${TF_VAR_owner:-platform-team}}"
  _cost_center=$(_parse_tfvar "cost_center")
  _cost_center="${_cost_center:-${TF_VAR_cost_center:-}}"
  {
    printf '%s\n' "$1" | tr ',' '\n'
    [[ -n "$_owner" ]] && printf 'owner=%s\n' "$_owner"
    [[ -n "$_cost_center" ]] && printf 'cost-center=%s\n' "$_cost_center"
    awk '
      !open && /^[[:space:]]*labels[[:space:]]*=[[:space:]]*\{/ { open = 1; sub(/^[^{]*\{/, "") }
      open {
        line = $0; sub(/#.*$/, "", line)
        end = index(line, "}"); if (end) line = substr(line, 1, end - 1)
        while (match(line, /"?[^"=[:space:]]+"?[[:space:]]*=[[:space:]]*"[^"]*"/)) {
          pair = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
          gsub(/"/, "", pair); sub(/[[:space:]]*=[[:space:]]*/, "=", pair)
          print pair
        }
        if (end) exit
      }
    ' "$INFRA_DIR/terraform.tfvars" 2>/dev/null
  } | awk -F= '
    NF == 0 { next }
    NF != 2 || $1 !~ /^[a-z]([a-z0-9_-]*[a-z0-9])?$/ || length($1) > 63 || $2 !~ /^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$/ || length($2) > 63 {
      print "WARNING: label " $0 " skipped on the secret: GCP cannot store it" > "/dev/stderr"; next
    }
    !($1 in value) { order[++n] = $1 }
    { value[$1] = $2 }
    END { for (i = 1; i <= n; i++) printf "%s%s=%s", (i > 1 ? "," : ""), order[i], value[order[i]] }
  '
}

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
