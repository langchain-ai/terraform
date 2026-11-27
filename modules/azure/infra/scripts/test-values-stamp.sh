#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-values-stamp.sh — Unit tests for the inputs init-values.sh records in the
# header of langsmith-values-overrides.yaml, and for the check deploy.sh runs on
# them (_values_drift in helm/scripts/_values.sh): a terraform.tfvars value, an
# example file, a module script, or langsmith-values-local.yaml that changed
# after the file was written stops the deploy. Also every key init-values.sh
# reads from terraform.tfvars is recorded, and the stop on a 0.17 file written
# under the previous mirror-layout default (_values_layout_from_old_default).
# No Azure, no terraform, no helm.
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
# shellcheck source=../../helm/scripts/_values.sh
source "$SCRIPT_DIR/../../helm/scripts/_values.sh"

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

MODULE="$TMP/module"
EXAMPLE="$MODULE/helm/values/examples/langsmith-values-polly.yaml"
SCRIPT="$MODULE/infra/scripts/_common.sh"
VALUES_DIR="$TMP/values"
VALUES="$VALUES_DIR/$_VALUES_OVERRIDES"
TFVARS="$TMP/terraform.tfvars"
mkdir -p "${EXAMPLE%/*}" "${SCRIPT%/*}" "$VALUES_DIR"
printf 'polly:\n  enabled: true\n' > "$EXAMPLE"
printf '# a module script\n' > "$SCRIPT"

# Writes the overrides file with the sources and inputs of now, the way
# init-values.sh plans them. The body does not matter to the check.
_write() {
  _values_plan_reset
  _values_plan_file example "$EXAMPLE"
  _values_plan_local "$VALUES_DIR"
  # shellcheck disable=SC2086 # one key per word
  _values_plan_tfvars $_VALUES_INPUT_KEYS
  _values_plan_script "$MODULE" infra/scripts/_common.sh
  {
    echo "Merged in this order, so a later source wins:"
    printf '%s' "$_VALUES_PLAN_SOURCES"
    echo "Inputs. make deploy stops when one of them differs:"
    printf '%s' "$_VALUES_PLAN_INPUTS"
  } > "$TMP/notes"
  printf 'polly:\n  enabled: true\n' > "$TMP/body"
  _values_seal "$VALUES" "$_VALUES_OVERRIDES, written by make init-values" "$TMP/notes" "$TMP/body"
}
_drift() { _values_drift "$VALUES" "$MODULE" "$VALUES_DIR"; }

echo "recorded inputs:"

printf 'ingress_controller = "envoy-gateway"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"
_write
_check "the file is sealed" "intact" "$(_values_seal_state "$VALUES")"
# shellcheck disable=SC2086 # one key per word
_check "each input key is recorded once" \
  "$(printf '%s\n' $_VALUES_INPUT_KEYS | sort)" \
  "$(_values_notes "$VALUES" tfvar | awk '{ print $2 }' | sort)"
_check "a set key records its value" "  tfvar ingress_controller = envoy-gateway" \
  "$(_values_notes "$VALUES" tfvar | grep ' ingress_controller ')"
_check "an unset key records no value" "  tfvar langsmith_image_registry =" \
  "$(_values_notes "$VALUES" tfvar | grep ' langsmith_image_registry ')"
_check "the same inputs: no drift" "" "$(_drift)"

printf 'ingress_controller = "agic"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"
_check "a changed value: one line" \
  'terraform.tfvars has ingress_controller = "agic", and the file was written for "envoy-gateway"' \
  "$(_drift)"

printf 'ingress_controller = "envoy-gateway"\nlangsmith_domain   = "ls.example.com"\nlangsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "a key set after the file was written: one line" \
  'terraform.tfvars has langsmith_image_registry = "nexus.example.com", and the file was written for ""' \
  "$(_drift)"

printf 'ingress_controller = "agic"\nlangsmith_domain   = "ls.example.com"\nlangsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "a changed value and a new key together: both lines" \
  'terraform.tfvars has ingress_controller = "agic", and the file was written for "envoy-gateway"
terraform.tfvars has langsmith_image_registry = "nexus.example.com", and the file was written for ""' \
  "$(_drift)"

# A module upgrade that adds an input key also changes a recorded script, so a
# file written before the key existed is out of date too.
printf 'ingress_controller = "envoy-gateway"\nlangsmith_domain   = "ls.example.com"\n' > "$TFVARS"
_write
printf '# a module script, upgraded\n' > "$SCRIPT"
_check "a changed module script: one line" \
  "infra/scripts/_common.sh changed (a module upgrade)" "$(_drift)"
_write
printf 'polly:\n  enabled: false\n' > "$EXAMPLE"
_check "a changed example: one line" \
  "helm/values/examples/langsmith-values-polly.yaml changed" "$(_drift)"
printf 'polly:\n  enabled: true\n' > "$EXAMPLE"
_check "the example changed back: no drift" "" "$(_drift)"

printf 'config:\n  basePath: ls\n' > "$VALUES_DIR/$_VALUES_LOCAL"
_check "a local file added: one line" "$_VALUES_LOCAL was added" "$(_drift)"
_write
_check "written with the local file: no drift" "" "$(_drift)"
printf 'config:\n  basePath: other\n' > "$VALUES_DIR/$_VALUES_LOCAL"
_check "the local file changed: one line" "$_VALUES_LOCAL changed" "$(_drift)"
rm -f "$VALUES_DIR/$_VALUES_LOCAL"
_check "the local file removed: one line" "$_VALUES_LOCAL was removed" "$(_drift)"

# Every key init-values.sh reads from terraform.tfvars, before it writes the
# file, is an input. clickhouse_host goes only into the ClickHouse Secret,
# which init-values.sh creates after the file.
_read_keys=$(grep -oE '_parse_tfvar[a-z_]* +"?[a-z_]+' "$SCRIPT_DIR/../../helm/scripts/init-values.sh" \
  | awk '{ print $2 }' | tr -d '"' | grep -vx 'clickhouse_host' | sort -u)
# shellcheck disable=SC2086 # one key per word
_check "init-values.sh reads no key that the header leaves out" "" \
  "$(comm -23 <(printf '%s\n' "$_read_keys") <(printf '%s\n' $_VALUES_INPUT_KEYS | sort -u))"

echo "0.17 file from the previous mirror-layout default:"

# A file written when langsmith_image_registry_keeps_source_host defaulted to
# true: images.registry set, the key unset in terraform.tfvars.
_old() { local rc=0; _values_layout_from_old_default "$1" || rc=$?; printf 'rc=%s' "$rc"; }
OLD="$TMP/values-overrides.yaml"
printf 'images:\n  registry: "nexus.example.com"\n  imagePullSecrets:\n    - name: "nexus-pull"\nredis:\n  registry: "decoy"\n' > "$OLD.oldlayout"
printf 'images:\n  registry: ""\n  backendImage:\n    repository: "nexus.example.com/langchain/langsmith-backend"\n' > "$OLD.newlayout"
printf 'langsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "host-kept layout, registry set, key unset: stop (rc 0)" 'rc=0' "$(_old "$OLD.oldlayout")"
printf 'langsmith_image_registry = "nexus.example.com"\nlangsmith_image_registry_keeps_source_host = true\n' > "$TFVARS"
_check "host-kept layout, key set: no stop" 'rc=1' "$(_old "$OLD.oldlayout")"
printf 'langsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
_check "host-dropped layout (registry empty), key unset: no stop" 'rc=1' "$(_old "$OLD.newlayout")"
printf 'ingress_controller = "envoy-gateway"\n' > "$TFVARS"
_check "no registry in tfvars: no stop, whatever the file" 'rc=1' "$(_old "$OLD.oldlayout")"
printf 'langsmith_image_registry = "nexus.example.com"\n' > "$TFVARS"
printf 'redis:\n  registry: "decoy"\nimages:\n  imagePullSecrets:\n    - name: "nexus-pull"\n' > "$OLD.decoy"
_check "a registry key outside the images block does not count" 'rc=1' "$(_old "$OLD.decoy")"

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
