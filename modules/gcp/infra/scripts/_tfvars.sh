#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _tfvars.sh — terraform.tfvars readers shared by the GCP infra and helm scripts.
#
# Usage: set INFRA_DIR, then source this file. Each function reads
# "$INFRA_DIR/terraform.tfvars" when called, so INFRA_DIR may change after
# sourcing.
#
# setup-env.sh sources this into the operator's shell, so it defines functions
# only: no `set -euo pipefail`, no output, no other variables.
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   _secret_labels <pairs>    — gcloud --labels value for a script-created secret

# Values are cut at the closing quote (quoted strings, which may contain a
# literal #) or at an inline # (bare booleans and numbers). The previous
# grep/sed pair kept trailing comments, so `enable_smithdb = true  # step 9`
# compared as "true#step9" and read as false.
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
# rejects it anyway and gcloud would fail the whole create.
_secret_labels() {
  local _tfvars="$INFRA_DIR/terraform.tfvars" _owner _cost_center
  # terraform.tfvars, then TF_VAR_*, then the variables.tf default, as Terraform
  # resolves them. A key set to "" still wins, and omits the label.
  if grep -Eq '^[[:space:]]*owner[[:space:]]*=' "$_tfvars" 2>/dev/null; then
    _owner=$(_parse_tfvar "owner")
  else
    _owner="${TF_VAR_owner-platform-team}"
  fi
  if grep -Eq '^[[:space:]]*cost_center[[:space:]]*=' "$_tfvars" 2>/dev/null; then
    _cost_center=$(_parse_tfvar "cost_center")
  else
    _cost_center="${TF_VAR_cost_center-}"
  fi
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
    ' "$_tfvars" 2>/dev/null
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
