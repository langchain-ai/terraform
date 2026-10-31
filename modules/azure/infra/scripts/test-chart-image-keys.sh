#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-chart-image-keys.sh — Unit tests for _chart_image_keys_from_stdin in _common.sh,
# the parser deploy.sh pipes `helm show values` into under set -o pipefail. The point
# of the test is the pipe: a parser that stops reading early makes the producer die of
# SIGPIPE and the pipeline fail, so the keys come back empty for a chart that was read
# fine. The producer here is cat on a values file padded well past any pipe buffer.
# No helm, no network.
#
# Usage:
#   ./infra/scripts/test-chart-image-keys.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_common.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
{
  printf 'global:\n  x: 1\nimages:\n  registry: ""\n  backendImage:\n    repository: docker.io/langchain/langsmith-backend\n  frontendImage:\n    repository: docker.io/langchain/langsmith-frontend\n  imagePullSecrets: []\n  operatorImage:\n    repository: docker.io/langchain/langgraph-operator\nconfig:\n  afterImage: no\n'
  yes '# padding so the producer still has far more than a pipe buffer to write after images:' | head -40000
} > "$TMP/values.yaml"

expected=$'backendImage\nfrontendImage\noperatorImage'
got=$(cat "$TMP/values.yaml" | _chart_image_keys_from_stdin) && [[ "$got" == "$expected" ]] && ok "the three *Image keys under images: and nothing after the block" || bad "keys (got: $(printf '%s' "$got" | tr '\n' ' '))"

fails=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  keys=$(cat "$TMP/values.yaml" | _chart_image_keys_from_stdin) || { fails=$((fails+1)); continue; }
  [[ -n "$keys" ]] || fails=$((fails+1))
done
[[ "$fails" -eq 0 ]] && ok "ten runs under pipefail with a 3 MB producer, none failed" || bad "$fails of 10 runs failed under pipefail"

# The shape the fix replaced, kept here as the counter-example so the property stays visible.
if cat "$TMP/values.yaml" | awk '/^images:/{p=1; next} p && /^[^ ]/{exit} p && /^  [A-Za-z0-9]+Image:/{print $1}' >/dev/null; then early_rc=0; else early_rc=$?; fi
[[ "$early_rc" -ne 0 ]] && ok "the early-exit awk fails the same pipeline (rc $early_rc), which is why it is gone" || ok "the early-exit awk happened to survive here (pipe buffer larger than the file); the property is still the one tested above"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
