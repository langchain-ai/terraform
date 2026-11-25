#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# test-addon-storage.sh — Checks _addon_storage_cutover_check against a fake helm.
# No cluster or Helm release.
#
# Usage: bash helm/scripts/test-addon-storage.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_addon-storage.sh
source "$SCRIPT_DIR/_addon-storage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# The fake helm lists the release unless RELEASE is empty, fails to list when
# RELEASE is BROKEN, and returns LIVE as the release's values.
mkdir "$TMP/bin"
cat > "$TMP/bin/helm" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  list) [[ "$RELEASE" != BROKEN ]] || exit 1; [[ -z "$RELEASE" ]] || echo langsmith ;;
  get) printf '%s' "$LIVE" ;;
  *) echo "unexpected helm call: $*" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TMP/bin/helm"

# run <name> <want message, empty to pass> <release> <live values> <section>...
run() {
  local name="$1" want="$2"
  export RELEASE="$3" LIVE="$4"
  shift 4
  if (PATH="$TMP/bin:$PATH" _addon_storage_cutover_check langsmith langsmith "$@") 2> "$TMP/err"; then
    [[ -z "$want" ]] && { PASS=$((PASS + 1)); echo "  PASS  $name"; return; }
  elif [[ -n "$want" ]] && grep -qF "$want" "$TMP/err"; then
    PASS=$((PASS + 1)); echo "  PASS  $name"; return
  fi
  FAIL=$((FAIL + 1)); echo "  FAIL  $name"; sed 's/^/        /' "$TMP/err"
}

CHAT_IN='{"polly":{"enabled":true,"postgres":{"external":{"enabled":false}}}}'
CHAT_EXT='{"polly":{"enabled":true,"postgres":{"external":{"enabled":true}}}}'
CHAT_OFF='{"polly":{"enabled":false,"postgres":{"external":{"enabled":false}}}}'
ENGINE_IN='{"insights":{"enabled":false},"engine":{"enabled":true},"engineInsightsAgent":{"postgres":{"external":{"enabled":false}}}}'
INSIGHTS_EXT='{"insights":{"enabled":true},"engineInsightsAgent":{"postgres":{"external":{"enabled":true}}}}'

run "nothing to check passes without a helm call" "" BROKEN "" 
run "a new install passes" "" "" "" polly engineInsightsAgent
run "Chat on in-cluster storage refuses" "keeps Chat data in the cluster" langsmith "$CHAT_IN" polly
run "Chat already external passes" "" langsmith "$CHAT_EXT" polly
run "Chat off in the release passes" "" langsmith "$CHAT_OFF" polly
run "Engine alone on in-cluster storage refuses" "keeps Insights and Engine data" langsmith "$ENGINE_IN" engineInsightsAgent
run "Insights already external passes" "" langsmith "$INSIGHTS_EXT" engineInsightsAgent
run "a failed release list refuses" "could not list the Helm releases" BROKEN "" polly
run "unreadable release values refuse" "could not read the Chat storage" langsmith "not json" polly

# deploy.sh calls _addon_storage_values on every deploy, with every add-on off on a
# default install; bash 3.2 (macOS) aborts on an empty array under set -u.
if (set -u; VALUES_ARGS=(); _addon_storage_values false false false && (( ${#VALUES_ARGS[@]} == 0 ))); then
  PASS=$((PASS + 1)); echo "  PASS  every add-on off adds no values"
else
  FAIL=$((FAIL + 1)); echo "  FAIL  every add-on off adds no values"
fi

echo ""
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
