#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Fetches credentials for a GKE cluster and updates local kubeconfig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
TFVARS="$INFRA_DIR/terraform.tfvars"

CLUSTER_NAME="${1:-}"
REGION="${2:-}"
PROJECT="${3:-}"

if [[ -z "$CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
fi
if [[ -z "$REGION" ]]; then
  REGION="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$TFVARS" 2>/dev/null || true)"
fi
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(awk -F= '/^[[:space:]]*project_id[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$TFVARS" 2>/dev/null || true)"
fi
REGION="${REGION:-us-west2}"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: cluster name not provided and could not be read from terraform outputs." >&2
  echo "Usage: $0 <cluster-name> [region] [project]" >&2
  exit 1
fi

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: project_id not provided and could not be read from terraform.tfvars." >&2
  echo "Usage: $0 <cluster-name> [region] [project]" >&2
  exit 1
fi

echo "Fetching kubeconfig for GKE cluster: $CLUSTER_NAME in $REGION (project: $PROJECT)"
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region "$REGION" \
  --project "$PROJECT"
echo "Done. Current context: $(kubectl config current-context)"
