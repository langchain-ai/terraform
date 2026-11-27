#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-sizing.sh — Checks the _sizing.sh checks that deploy.sh and status.sh run.
# No cluster and no Helm.
#
# Usage: bash helm/scripts/test-sizing.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_sizing.sh
source "$SCRIPT_DIR/_sizing.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# check <name> <want> <got>
check() {
  if [[ "$3" == "$2" ]]; then
    PASS=$((PASS + 1)); echo "  PASS  $1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL  $1"
    echo "        want: ${2:-(nothing)}" | sed '2,$s/^/              /'
    echo "        got:  ${3:-(nothing)}" | sed '2,$s/^/              /'
  fi
}

# A directory name with a space, as a checkout path can have.
VALUES="$TMP/helm values"
mkdir -p "$VALUES"
check "no sizing file prints nothing" "" "$(_old_sizing_files "$VALUES")"
touch "$VALUES/langsmith-values.yaml" "$VALUES/langsmith-values-fleet.yaml"
check "other values files print nothing" "" "$(_old_sizing_files "$VALUES")"
touch "$VALUES/langsmith-values-sizing-production-large.yaml"
check "a 0.17 sizing file is named" "langsmith-values-sizing-production-large.yaml" "$(_old_sizing_files "$VALUES")"
check "a missing directory prints nothing" "" "$(_old_sizing_files "$TMP/none")"

check "the example base values set the whole sizing" "" \
  "$(_base_sizing_gaps "$SCRIPT_DIR/../values/examples/langsmith-values.yaml")"

# A copy made on 0.17: blob storage and queue ranges, none of the sizing.
cat > "$TMP/base-017.yaml" <<'EOF'
config:
  blobStorage:
    enabled: true
queue:
  autoscaling:
    keda:
      enabled: true
EOF
check "a 0.17 copy lacks backend, frontend and the run expiry" \
  $'backend\nfrontend\nconfig.settings.redisRunsExpirySeconds' "$(_base_sizing_gaps "$TMP/base-017.yaml")"

cat > "$TMP/base-commented.yaml" <<'EOF'
config:
  settings:
    # redisRunsExpirySeconds: "3600"
# backend:
#   autoscaling: {}
frontend:
  deployment:
    replicas: 2
EOF
check "commented-out keys do not count" \
  $'backend\nconfig.settings.redisRunsExpirySeconds' "$(_base_sizing_gaps "$TMP/base-commented.yaml")"

cat > "$TMP/base-nested.yaml" <<'EOF'
smithdb:
  backend:
    enabled: true
  redisRunsExpirySeconds: "3600"
frontend:
  deployment:
    replicas: 2
EOF
check "keys under another block do not count" \
  $'backend\nconfig.settings.redisRunsExpirySeconds' "$(_base_sizing_gaps "$TMP/base-nested.yaml")"

cat > "$TMP/base-indent4.yaml" <<'EOF'
config:
    settings:
        redisRunsExpirySeconds: "3600"
frontend: {}
backend: {}
EOF
check "the run expiry counts at any indent under config" "" "$(_base_sizing_gaps "$TMP/base-indent4.yaml")"

check "a missing file prints nothing" "" "$(_base_sizing_gaps "$TMP/none.yaml")"

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
