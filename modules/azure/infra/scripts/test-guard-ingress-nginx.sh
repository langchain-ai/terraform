#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-guard-ingress-nginx.sh — Checks guard-ingress-nginx.sh against a fake
# terraform. No Azure, Terraform state, or cluster.
#
# Usage:
#   ./infra/scripts/test-guard-ingress-nginx.sh
#
# Also available as: make test-guard-ingress-nginx
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/guard-ingress-nginx.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-guard-ingress-nginx.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# The fake answers state list from a file: the state list, or the word
# NOSTATE / BROKEN.
mkdir -p "$TMP/bin" "$TMP/infra"
cat > "$TMP/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *"state list"*)
    s=$(cat "$FAKE/state")
    [[ "$s" == NOSTATE ]] && { echo "No state file was found!" >&2; exit 1; }
    [[ "$s" == BROKEN ]] && { echo "Error: backend unreachable" >&2; exit 1; }
    printf '%s\n' "$s" ;;
esac
FAKE
chmod +x "$TMP/bin/terraform"

# run <name> <want exit> <want message> <state>
# A stop must name its reason, so a stop for the wrong reason fails.
run() {
  local name="$1" want="$2" message="$3" state="$4" got=0
  printf '%b' "$state" > "$TMP/state"
  PATH="$TMP/bin:$PATH" FAKE="$TMP" INFRA_DIR="$TMP/infra" \
    bash "$GUARD" > "$TMP/out" 2>&1 || got=$?
  if [[ "$got" == "$want" ]] && { [[ -z "$message" ]] || grep -qF -- "$message" "$TMP/out"; }; then
    PASS=$((PASS + 1)); echo "  ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name (exit $got, want $want)"; sed 's/^/       /' "$TMP/out"
  fi
}

N='module.aks.helm_release.nginx_ingress[0]'

run "a new deployment with no state continues" 0 "" "NOSTATE"
run "an unreadable state continues, and terraform reports it" 0 "" "BROKEN"
run "an empty state continues" 0 "" ""
run "a state without ingress-nginx continues" 0 "" 'module.vnet.azurerm_virtual_network.vnet\nmodule.aks.helm_release.envoy_gateway[0]'
run "a state with ingress-nginx stops" 1 "still runs ingress-nginx" "module.vnet.azurerm_virtual_network.vnet\n$N"
run "ingress-nginx under a wrapper module stops" 1 "still runs ingress-nginx" "module.langsmith.$N"

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
