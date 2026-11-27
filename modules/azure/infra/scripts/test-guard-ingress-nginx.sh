#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-guard-ingress-nginx.sh — Checks guard-ingress-nginx.sh against a fake
# terraform, and that init-values.sh and deploy.sh run it before they write
# values or reach the cluster. No Azure, Terraform state, or cluster.
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
# NOSTATE / BROKEN. It answers only for the root the test set up, so a caller
# that points the guard at another root fails instead of passing unguarded.
mkdir -p "$TMP/bin" "$TMP/infra"
cat > "$TMP/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "-chdir=$FAKE/infra" ]] || { echo "unexpected root: ${1:-}" >&2; exit 1; }
case "$*" in
  *"state list"*)
    s=$(cat "$FAKE/state")
    [[ "$s" == NOSTATE ]] && { echo "No state file was found!" >&2; exit 1; }
    [[ "$s" == BROKEN ]] && { echo "Error: backend unreachable" >&2; exit 1; }
    printf '%s\n' "$s" ;;
  *) echo "terraform $*" >> "$FAKE/calls"; exit 1 ;;
esac
FAKE
# Any call to these, or any other terraform command, is logged and fails.
for _tool in kubectl helm az; do
  cat > "$TMP/bin/$_tool" <<FAKE_TOOL
#!/usr/bin/env bash
echo "$_tool \$*" >> "\$FAKE/calls"
exit 1
FAKE_TOOL
done
chmod +x "$TMP/bin/"*

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

# helm_step <name> <script under helm/scripts>: a state with ingress-nginx must
# stop the script with the guard's message, before any other call and before
# it writes a values file.
helm_step() {
  local name="$1" script="$2" got=0
  printf '%b' "module.vnet.azurerm_virtual_network.vnet\n$N" > "$TMP/state"
  : > "$TMP/infra/terraform.tfvars"
  rm -rf "$TMP/values" "$TMP/calls"; mkdir -p "$TMP/values"
  PATH="$TMP/bin:$PATH" FAKE="$TMP" LANGSMITH_INFRA_DIR="$TMP/infra" LANGSMITH_VALUES_DIR="$TMP/values" \
    bash "$SCRIPT_DIR/../../helm/scripts/$script" < /dev/null > "$TMP/out" 2>&1 || got=$?
  if [[ "$got" == 1 ]] && grep -qF "still runs ingress-nginx" "$TMP/out" \
      && [[ ! -s "$TMP/calls" ]] && [[ -z "$(ls -A "$TMP/values")" ]]; then
    PASS=$((PASS + 1)); echo "  ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $name (exit $got, want 1)"; sed 's/^/       /' "$TMP/out"
    [[ -s "$TMP/calls" ]] && sed 's/^/       called: /' "$TMP/calls"
  fi
}

helm_step "init-values.sh stops before it writes values or reaches the cluster" init-values.sh
helm_step "deploy.sh stops before it reaches the cluster" deploy.sh

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
