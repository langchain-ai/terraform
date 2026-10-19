#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-langsmith-images-block.sh — Unit tests for the images: block init-values.sh
# writes into values-overrides.yaml from langsmith_image_registry,
# langsmith_image_registry_keeps_source_host and langsmith_image_pull_secret_name
# (_langsmith_images_block in _common.sh). No Azure, no terraform, no tfvars.
#
# Usage:
#   ./infra/scripts/test-langsmith-images-block.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

_check "nothing set: one comment line" \
  '# images: the chart defaults (docker.io). Set langsmith_image_registry for a mirror.' \
  "$(_langsmith_images_block "" "true" "")"

_check "registry that keeps the source host: images.registry alone" \
  'images:
  registry: "nexus.example.com"' \
  "$(_langsmith_images_block "nexus.example.com" "true" "")"

_check "pull Secret alone: images.imagePullSecrets" \
  'images:
  imagePullSecrets:
    - name: "nexus-pull"' \
  "$(_langsmith_images_block "" "true" "nexus-pull")"

_check "registry and pull Secret" \
  'images:
  registry: "nexus.example.com"
  imagePullSecrets:
    - name: "nexus-pull"' \
  "$(_langsmith_images_block "nexus.example.com" "true" "nexus-pull")"

_out=$(_langsmith_images_block "nexus.example.com:8443/mirror" "false" "nexus-pull")
_check "registry that drops the host: images.registry empty" \
  '  registry: ""' \
  "$(printf '%s\n' "$_out" | grep -E '^  registry:')"
_check "registry that drops the host: the backend repository" \
  '    repository: "nexus.example.com:8443/mirror/langchain/langsmith-backend"' \
  "$(printf '%s\n' "$_out" | grep -A1 '^  backendImage:' | tail -1)"
_check "registry that drops the host: an image from another registry loses its host too" \
  '    repository: "nexus.example.com:8443/mirror/sig-storage/csi-node-driver-registrar"' \
  "$(printf '%s\n' "$_out" | grep -A1 '^  juicefsCSINodeDriverRegistrarImage:' | tail -1)"
_check "registry that drops the host: one repository per known image" \
  "$(_langsmith_image_keys | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$_out" | grep -c '^    repository:')"
_check "registry that drops the host: the pull Secret comes last" \
  '    - name: "nexus-pull"' \
  "$(printf '%s\n' "$_out" | tail -1)"

_check "a trailing slash on the registry is dropped (images.registry)" \
  'images:
  registry: "nexus.example.com"' \
  "$(_langsmith_images_block "nexus.example.com/" "true" "")"
_check "a trailing slash on the registry is dropped (per-image repository)" \
  '    repository: "nexus.example.com:8443/mirror/langchain/langsmith-backend"' \
  "$(_langsmith_images_block "nexus.example.com:8443/mirror/" "false" "" | grep -A1 '^  backendImage:' | tail -1)"

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
