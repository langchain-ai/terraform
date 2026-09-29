#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _tfvars.sh — The one set of terraform.tfvars helpers for Azure scripts.
#
# Usage: source "<infra>/scripts/_tfvars.sh" "<dir holding terraform.tfvars>"
#
# _common.sh sources this. So does preflight.sh, which defines its own
# info/error and must not pick up the rest of _common.sh. The directory argument
# is required. A bare `source` would hand this file the caller's positional
# parameters, and a script's own $1 is not a directory.
#
# Every helper here refuses a name that infra/*.tf does not declare as a
# variable. Terraform warns on an undeclared tfvars key and exits 0, ignores an
# undeclared TF_VAR_* without a word, and a reader that misses hands its caller
# the default, so a half-finished rename would otherwise revert the setting in
# silence.
#
# Provides:
#   _tfvar_declared <name>        — 0 if infra/*.tf declares variable "<name>"
#   _parse_tfvar <key>            — Read a value from terraform.tfvars
#   _parse_tfvar_quoted <key> [f] — Read a quoted value, spaces intact, from [f]
#   _tfvar_is_true <key>          — Return 0 if tfvar == true
#   _export_tf_var <name> <value> — export TF_VAR_<name>=<value>
#   _tfvars_check_file <file>     — Fail on any top-level key <file> sets that is not a variable

_TFVARS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_TFVARS_DIR="${1:?_tfvars.sh needs the directory holding terraform.tfvars}"

_tfvar_declared() {
  grep -qE "^variable[[:space:]]+\"$1\"" "$_TFVARS_ROOT"/*.tf 2>/dev/null && return 0
  echo "ERROR: ${0##*/} uses tfvars name '$1', but no variable \"$1\" is declared in $_TFVARS_ROOT." >&2
  echo "       Terraform would ignore it. Rename it in the script to match infra/variables.tf." >&2
  return 2
}

# ── terraform.tfvars parser ──────────────────────────────────────────────────
_parse_tfvar() {
  _tfvar_declared "$1" || return
  local key="$1"
  local tfvars_file="${_TFVARS_DIR}/terraform.tfvars"
  local raw val
  raw=$(grep -E "^\s*${key}\s*=" "$tfvars_file" 2>/dev/null | head -1) || return 1
  [[ -n "$raw" ]] || return 1
  # Quoted string: key = "value"
  val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
  if [[ -z "$val" ]]; then
    # Unquoted value: key = true / key = 42 / key = {}. The trailing comment goes
    # first, or "create_keyvault = false # attach" returns a value matching
    # neither true nor false and every caller silently takes the other branch.
    val=$(echo "$raw" | sed 's/.*=[[:space:]]*//' | sed 's/#.*//' | tr -d '[:space:]"')
  fi
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Read one quoted scalar out of a tfvars file, preserving spaces inside the
# value. _parse_tfvar runs its result through `tr -d '[:space:]'`, which is right
# for a region or a resource name and silently mangles a password that contains a
# space. The file defaults to terraform.tfvars and is resolved against the
# directory this file was sourced with unless absolute, so callers can read
# secrets.auto.tfvars the same way.
_parse_tfvar_quoted() {
  _tfvar_declared "$1" || return
  local key="$1"
  local file="${2:-terraform.tfvars}"
  [[ "$file" == /* ]] || file="${_TFVARS_DIR}/$file"
  local val
  val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*\$/\1/p" \
    "$file" 2>/dev/null | head -1)
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1") || return 1
  [[ "$val" == "true" ]]
}

_export_tf_var() {
  _tfvar_declared "$1" || return
  export "TF_VAR_$1=$2"
}

# The top-level keys of a tfvars file, checked against the declared variables.
# Keys inside a block value (the fields of an additional_node_pools entry) are
# not variables, so only depth 0 counts. Strings go first, so a brace or a #
# inside one cannot move the depth or fake a comment, and the body of a heredoc
# value is skipped. Depth that has not returned to 0 at the end means the scan lost
# track, and a partial key set would pass, so that fails too.
_tfvars_check_file() {
  awk -v target="$1" '
    FILENAME != target {
      if ($0 ~ /^variable[ \t]+"/) {
        v = $0; sub(/^variable[ \t]+"/, "", v); sub(/".*/, "", v); declared[v] = 1
      }
      next
    }
    hd != "" {
      t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == hd) hd = ""
      next
    }
    {
      s = $0
      gsub(/\\"/, "", s); gsub(/"[^"]*"/, "\"\"", s)
      sub(/#.*/, "", s); sub(/\/\/.*/, "", s)
      if (depth == 0 && s ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=([^=]|$)/) {
        k = s; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
        if (!(k in declared)) bad = bad "\n         line " FNR ": " k
      }
      if (s ~ /=[ \t]*<<-?[A-Za-z_]/) {
        hd = s; sub(/^.*<<-?/, "", hd); sub(/[ \t].*/, "", hd)
        next
      }
      depth += gsub(/[{[]/, "", s) - gsub(/[}\]]/, "", s)
    }
    END {
      if (depth != 0 || hd != "") {
        print "ERROR: could not read the top-level keys of " target " (unbalanced brackets or an unclosed heredoc)." > "/dev/stderr"
        exit 2
      }
      if (bad != "") {
        print "ERROR: " target " sets names that are not declared variables:" bad > "/dev/stderr"
        print "       Terraform only warns on these and ignores their values." > "/dev/stderr"
        exit 1
      }
    }
  ' "$_TFVARS_ROOT"/*.tf "$1"
}
