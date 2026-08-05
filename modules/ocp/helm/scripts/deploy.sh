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
# Pin the chart *line*: deploy the latest 0.15.x, never auto-jump to 0.16.
# Override with the CHART_VERSION env var for an exact patch if needed.
CHART_VERSION="${CHART_VERSION:-~0.15.1}"

# The values on this branch use the chart 0.16 schema. Chart 0.15 ignores the
# unknown keys rather than rejecting them, so a 0.15 deploy renders cleanly while
# silently dropping the external Insights Postgres/Redis wiring and falling back
# to in-cluster StatefulSets. Refuse instead. The pin above stays on 0.15 until
# chart 0.16.0 is GA, because Helm tilde ranges skip prereleases.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
if [[ -n "$_chart_line" && "$(printf '%s\n0.16\n' "$_chart_line" | sort -V | head -1)" != "0.16" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' is on the $_chart_line line, but these values require chart 0.16 or newer." >&2
  echo "       Until 0.16.0 is GA, pass the release candidate explicitly:" >&2
  echo "         CHART_VERSION=0.16.0-rc.29 $0" >&2
  exit 1
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
