#!/usr/bin/env bash
# Fetches credentials for a GKE cluster and updates the local kubeconfig.
set -euo pipefail

CLUSTER_NAME="${1:-}"
REGION="${2:-us-central1}"
PROJECT="${3:-}"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "Usage: $0 <cluster-name> [region] [project]" >&2
  exit 1
fi

PROJECT_FLAG=""
if [[ -n "$PROJECT" ]]; then
  PROJECT_FLAG="--project $PROJECT"
fi

echo "Fetching kubeconfig for GKE cluster: $CLUSTER_NAME in $REGION"
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  $PROJECT_FLAG
echo "Done. Current context: $(kubectl config current-context)"
