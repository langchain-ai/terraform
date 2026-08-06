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

OVERRIDES_FILE="$HELM_DIR/values/values-overrides.yaml"

if [[ ! -f "$OVERRIDES_FILE" ]]; then
  echo "ERROR: $OVERRIDES_FILE not found." >&2
  echo "Copy values-overrides.yaml.example to values-overrides.yaml and fill in your values." >&2
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
