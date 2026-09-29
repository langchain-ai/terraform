#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Fetches credentials for a GKE cluster and updates local kubeconfig.
# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell and leave it armed to exit on the next non-zero command, and any `exit`
# here would close that shell outright. So when sourced, hand off to a child
# process and return its status - `source` then behaves exactly like running it.
# Keep this above `set`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
source "$INFRA_DIR/scripts/_tfvars.sh" "$INFRA_DIR"

CLUSTER_NAME="${1:-}"
REGION="${2:-}"
PROJECT="${3:-}"

if [[ -z "$CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
fi
if [[ -z "$REGION" ]]; then
  REGION="$(_parse_tfvar region)"
fi
if [[ -z "$PROJECT" ]]; then
  PROJECT="$(_parse_tfvar project_id)"
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
