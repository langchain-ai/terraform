#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _tfvars.sh — The one set of terraform.tfvars helpers for AWS scripts.
#
# Usage: source "<infra>/scripts/_tfvars.sh" "<dir holding terraform.tfvars>"
#
# _common.sh sources this. So do the scripts that must not pick up the rest of
# _common.sh: setup-env.sh and set-kubeconfig.sh run in the caller's
# interactive shell, and preflight.sh defines its own info/error. The directory
# argument is required. A bare `source` would hand this file the caller's
# positional parameters, and a script's own $1 is not a directory.
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
# Handles both quoted strings (key = "value") and unquoted values (key = true / key = 42).
# Returns non-zero if the key is not found.
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
    # Unquoted value: key = true / key = 42 / key = {} / key = ["m5.2xlarge"]
    # Strip any trailing `# comment` BEFORE collapsing whitespace, otherwise
    # `enable_fleet = true # note` parses to `true#note` and breaks _tfvar_is_true
    # (migration issue #1).
    val=$(echo "$raw" | sed 's/.*=[[:space:]]*//; s/#.*//' | tr -d '[:space:]"[]')
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

_export_tf_var() {
  _tfvar_declared "$1" || return
  export "TF_VAR_$1=$2"
}

# The top-level keys of a tfvars file, checked against the declared variables.
# Keys inside a block value (the fields of an eks_node_groups entry) are not
# variables, so only depth 0 counts. Strings go first, so a brace or a # inside
# one cannot move the depth or fake a comment, and the body of a heredoc value
# is skipped. Depth that has not returned to 0 at the end means the scan lost
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
