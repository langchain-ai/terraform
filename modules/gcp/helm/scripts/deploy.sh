#!/usr/bin/env bash
# Deploys or upgrades LangSmith via Helm on GCP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"
BASE_VALUES_FILE="$VALUES_DIR/values.yaml"
OVERRIDES_FILE="$VALUES_DIR/values-overrides.yaml"

if [[ ! -f "$BASE_VALUES_FILE" ]]; then
  echo "ERROR: $BASE_VALUES_FILE not found." >&2
  exit 1
fi

if [[ ! -f "$OVERRIDES_FILE" ]]; then
  echo "ERROR: $OVERRIDES_FILE not found." >&2
  echo "Copy values-overrides.yaml.example to values-overrides.yaml and fill in your values." >&2
  exit 1
fi

if ! grep -Eq '^\s*hostname:\s*".+"' "$OVERRIDES_FILE"; then
  echo "ERROR: config.hostname must be set in $OVERRIDES_FILE before deploying." >&2
  exit 1
fi

# Validate tools/credentials and cluster connectivity.
"$SCRIPT_DIR/preflight-check.sh"
echo ""

_cluster_name="$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
_project_id="$(awk -F= '/^[[:space:]]*project_id[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true)"
_region="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true)"
_region="${_region:-us-west2}"

if [[ -z "$_cluster_name" ]]; then
  echo "ERROR: Could not resolve cluster_name from Terraform outputs. Run terraform apply first." >&2
  exit 1
fi

echo "Refreshing kubeconfig for cluster: $_cluster_name"
"$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" "$_region" "$_project_id"
echo "  Active context: $(kubectl config current-context)"
echo ""

echo "Values chain:"
echo "  - $(basename "$BASE_VALUES_FILE")"
echo "  - $(basename "$OVERRIDES_FILE")"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  -f "$BASE_VALUES_FILE" \
  -f "$OVERRIDES_FILE" \
  --wait \
  --timeout 20m

echo ""
echo "LangSmith deployed."
echo "Access URL: https://$(awk -F: '/^[[:space:]]*hostname:/{gsub(/[ "]/, "", $2); print $2; exit}' "$OVERRIDES_FILE")"
echo "Next checks:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  helm status $RELEASE_NAME -n $NAMESPACE"
