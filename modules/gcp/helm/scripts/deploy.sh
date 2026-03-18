#!/usr/bin/env bash
# Deploys or upgrades LangSmith via Helm on GCP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"
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

echo "LangSmith deployed. Access it at the hostname configured in values-overrides.yaml."
