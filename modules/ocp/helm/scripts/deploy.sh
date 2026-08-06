#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Deploys or upgrades LangSmith via Helm on OpenShift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
# Pin the chart *line*: deploy the latest 0.16.x, never auto-jump to 0.17.
# Override with the CHART_VERSION env var for an exact patch if needed.
# An exported CHART_VERSION outlives the command that set it, so a value left over
# from an earlier session silently wins over the pin. Say so rather than deploying
# a different chart than the branch intends.
if [[ -n "${CHART_VERSION:-}" ]]; then
  echo "NOTE: CHART_VERSION='${CHART_VERSION}' comes from your environment and overrides the ~0.16.0 pin."
  echo "      Run 'unset CHART_VERSION' to deploy the pinned chart line."
fi
CHART_VERSION="${CHART_VERSION:-~0.16.0}"

# These values use the chart 0.16 schema: engineInsightsAgent, the top-level
# insights/polly blocks, and no backend.agentBootstrap. Chart 0.15 ignores those
# keys instead of rejecting them, so it renders cleanly while silently dropping
# the external Insights Postgres/Redis wiring and falling back to in-cluster
# StatefulSets. Chart 0.17 has not been validated against them. Refuse both
# rather than deploy a half-configured release.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "0.16" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart 0.16 line." >&2
  echo "       These values require chart 0.16 (engineInsightsAgent, top-level insights/polly)." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a 0.16 patch explicitly:" >&2
  echo "         CHART_VERSION=0.16.0 $0" >&2
  exit 1
fi
# engineInsightsAgent only exists from 0.16.0-rc.24 onwards. Earlier prereleases
# are on the 0.16 line but still drop the block silently.
if [[ "$CHART_VERSION" == *-* ]]; then
  _rc="${CHART_VERSION##*-rc.}"
  if [[ "$CHART_VERSION" != *-rc.* || ! "$_rc" =~ ^[0-9]+$ || "$_rc" -lt 24 ]]; then
    echo "ERROR: CHART_VERSION '$CHART_VERSION' predates the engineInsightsAgent block (chart 0.16.0-rc.24)." >&2
    echo "       Chart 0.16.0 is GA — use a released 0.16.x." >&2
    exit 1
  fi
fi

# Preflight: reject values files still carrying the chart 0.15 schema. init-values.sh
# only creates an addon file when it is missing, so a values directory generated on the
# 0.15 line keeps its stale copies and they get loaded here. The chart does reject them,
# but its error names the key, not the generated file that carries it.
_legacy_files=""
for _vf in "$HELM_DIR/values"/*.yaml; do
  [[ -f "$_vf" ]] || continue
  if awk '
      /^[A-Za-z_]/ { top = $1; sub(":", "", top) }
      top == "config"  && /^  (insights|polly):/ { found = 1 }
      top == "backend" && /^  agentBootstrap:/   { found = 1 }
      END { exit !found }
    ' "$_vf"; then
    _legacy_files+="         $(basename "$_vf")
"
  fi
done
if [[ -n "$_legacy_files" ]]; then
  echo "ERROR: these values files use the chart 0.15 schema, which chart 0.16 rejects:" >&2
  printf '%s' "$_legacy_files" >&2
  echo "       config.insights, config.polly and backend.agentBootstrap were removed." >&2
  echo "       init-values.sh only creates an addon file when it is missing, so delete the" >&2
  echo "       files listed above and re-run 'make init-values' to regenerate them." >&2
  exit 1
fi

OVERRIDES_FILE="$HELM_DIR/values/values-overrides.yaml"

if [[ ! -f "$OVERRIDES_FILE" ]]; then
  echo "ERROR: $OVERRIDES_FILE not found." >&2
  echo "Copy values-overrides.yaml.example to values-overrides.yaml and fill in your values." >&2
  exit 1
fi

# Resolve the pin to a concrete version and print it. Without this the only place
# the installed version shows up is `helm list`, after the release is already out.
_resolved_chart=$(helm show chart langchain/langsmith --version "$CHART_VERSION" ${_devel_flag:-} 2>/dev/null \
  | awk '/^version:/{print $2}') || _resolved_chart=""
echo "Chart: langchain/langsmith  requested=${CHART_VERSION}  resolved=${_resolved_chart:-UNRESOLVED}"
if [[ -z "$_resolved_chart" ]]; then
  echo "ERROR: no chart matches '$CHART_VERSION' in the langchain repo." >&2
  exit 1
fi

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  -f "$HELM_DIR/values/values.yaml" \
  -f "$OVERRIDES_FILE" \
  --wait

echo "LangSmith deployed."
echo "Access it via the Route: $(oc get route langsmith -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo '<check oc get route -n '"$NAMESPACE"'>')"
