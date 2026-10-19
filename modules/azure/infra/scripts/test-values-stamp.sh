#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-values-stamp.sh — Unit tests for the stamp check deploy.sh runs on
# values-overrides.yaml (_values_stamp_drift in _common.sh): a file generated
# from other terraform.tfvars values stops the deploy, and so does one generated
# before a key existed that terraform.tfvars now sets. No Azure, no terraform.
#
# Usage:
#   ./infra/scripts/test-values-stamp.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-values-stamp.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# _common.sh reads terraform.tfvars from INFRA_DIR, fixed when it is sourced.
export INFRA_DIR="$TMP"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

PASS=0; FAIL=0
_check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok   $name"; PASS=$((PASS + 1))
  else
    echo "  FAIL $name"; FAIL=$((FAIL + 1))
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/       /'
  fi
}
# Run the check and print "rc=<n>" after its output, so one compare covers both.
_drift() {
  local out rc=0
  out=$(_values_stamp_drift "$1") || rc=$?
  printf '%s%src=%s' "$out" "${out:+$'\n'}" "$rc"
}

TFVARS="$TMP/terraform.tfvars"
VALUES="$TMP/values-overrides.yaml"
printf 'ingress_controller = "nginx"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"

# A stamp written from these tfvars, every key present (empty when unset).
_values_input_stamp > "$VALUES"
_check "stamped from the same tfvars: clean" \
  'rc=0' \
  "$(_drift "$VALUES")"

printf 'ingress_controller = "agic"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"
_check "a stamped value changed: one line, rc 1" \
  "ingress_controller: generated with 'nginx', terraform.tfvars now says 'agic'
rc=1" \
  "$(_drift "$VALUES")"

# A file written before langsmith_image_registry was stamped.
printf 'ingress_controller = "nginx"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"
grep -v '^#   langsmith_image_registry =' "$VALUES" > "$VALUES.old"
_check "an older stamp lacks a key that tfvars leaves unset: clean" \
  'rc=0' \
  "$(_drift "$VALUES.old")"

printf 'ingress_controller = "nginx"\nlangsmith_domain   = "ls.example.com"\nlangsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "an older stamp lacks a key that tfvars now sets: not stamped, rc 1" \
  "langsmith_image_registry: not stamped (the file predates this key), terraform.tfvars now says 'nexus.example.com'
rc=1" \
  "$(_drift "$VALUES.old")"

printf 'ingress_controller = "agic"\nlangsmith_domain   = "ls.example.com"\nlangsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "a changed value and a missing key together: both lines" \
  "ingress_controller: generated with 'nginx', terraform.tfvars now says 'agic'
langsmith_image_registry: not stamped (the file predates this key), terraform.tfvars now says 'nexus.example.com'
rc=1" \
  "$(_drift "$VALUES.old")"

printf '# values-overrides.yaml from an init-values.sh that wrote no stamp\nimages: {}\n' > "$VALUES.none"
_check "no stamp at all: rc 2 (deploy.sh warns and continues)" \
  "ingress_controller: not stamped (the file predates this key), terraform.tfvars now says 'agic'
langsmith_domain: not stamped (the file predates this key), terraform.tfvars now says 'ls.example.com'
langsmith_image_registry: not stamped (the file predates this key), terraform.tfvars now says 'nexus.example.com'
rc=2" \
  "$(_drift "$VALUES.none")"

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
