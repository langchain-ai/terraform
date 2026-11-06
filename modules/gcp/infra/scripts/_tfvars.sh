#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _tfvars.sh — terraform.tfvars readers shared by the GCP infra and helm scripts.
#
# Usage: set INFRA_DIR, then source this file. Each function reads
# its var files under "$INFRA_DIR" when called, so INFRA_DIR may change after
# sourcing.
#
# setup-env.sh sources this into the operator's shell, so it defines functions
# only: no `set -euo pipefail`, no output, no other variables.
#
# Provides:
#   _parse_tfvar <key> [file] — Read a value from terraform.tfvars, or file
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   _tfvar_source <key>       — The last var file that sets key
#   _tfvar_value <key> <dflt> — Value from var files, then TF_VAR_<key>, then dflt
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
  ' "${2:-$INFRA_DIR/terraform.tfvars}" 2>/dev/null || true
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  [[ "$(_parse_tfvar "$1")" == "true" ]]
}

# The last of terraform.tfvars and *.auto.tfvars, in Terraform's load order,
# that sets $1. Empty when none does. The .json forms are not read.
_tfvar_source() {
  local _f _src=""
  for _f in "$INFRA_DIR/terraform.tfvars" "$INFRA_DIR"/*.auto.tfvars; do
    if grep -Eq "^[[:space:]]*$1[[:space:]]*=" "$_f" 2>/dev/null; then _src="$_f"; fi
  done
  printf '%s' "$_src"
}

# Variable $1 as Terraform resolves it from what a script can see: the var file
# from _tfvar_source, then TF_VAR_$1, then the default $2. A key set to "" in a
# var file still wins.
_tfvar_value() {
  local _src _env="TF_VAR_$1"
  _src=$(_tfvar_source "$1")
  if [[ -n "$_src" ]]; then _parse_tfvar "$1" "$_src"; else printf '%s' "${!_env-$2}"; fi
}

# gcloud --labels value for a secret the scripts create outside Terraform: the
# standard labels from locals.tf, the base pairs in $1, then owner, cost-center,
# and the labels map, a later key replacing an earlier one as in locals.tf. An
# empty value omits its label. A pair that breaks the label rules is skipped
# with a warning, since terraform plan rejects it anyway and gcloud would fail
# the whole create.
_secret_labels() {
  local _src
  {
    printf 'app=langsmith\nenvironment=%s\nproject=%s\nname-prefix=%s\n' \
      "$(_tfvar_value environment prod)" "$(_tfvar_value project_id "")" "$(_tfvar_value name_prefix ls)"
    printf '%s\n' "$1" | tr ',' '\n'
    printf 'owner=%s\ncost-center=%s\n' "$(_tfvar_value owner platform-team)" "$(_tfvar_value cost_center "")"
    _src=$(_tfvar_source labels)
    if [[ -n "$_src" ]]; then cat "$_src"; else printf 'labels = %s\n' "${TF_VAR_labels-}"; fi | awk '
      !open && /^[[:space:]]*labels[[:space:]]*=[[:space:]]*\{/ { open = 1; sub(/^[^{]*\{/, "") }
      open {
        line = $0; sub(/#.*$/, "", line)
        end = index(line, "}"); if (end) line = substr(line, 1, end - 1)
        while (match(line, /"?[^"=,[:space:]]+"?[[:space:]]*=[[:space:]]*("[^"]*"|[^",[:space:]]+)/)) {
          pair = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
          gsub(/"/, "", pair); sub(/[[:space:]]*=[[:space:]]*/, "=", pair)
          print pair
        }
        if (end) exit
      }
    '
  } | awk -F= '
    NF == 0 || (NF == 2 && $2 == "") { next }
    NF != 2 || $1 !~ /^[a-z]([a-z0-9_-]*[a-z0-9])?$/ || length($1) > 63 || $2 !~ /^[a-z0-9]([a-z0-9_-]*[a-z0-9])?$/ || length($2) > 63 {
      print "WARNING: label " $0 " skipped on the secret: GCP cannot store it" > "/dev/stderr"; next
    }
    !($1 in value) { order[++n] = $1 }
    { value[$1] = $2 }
    END { for (i = 1; i <= n; i++) printf "%s%s=%s", (i > 1 ? "," : ""), order[i], value[order[i]] }
  '
}
