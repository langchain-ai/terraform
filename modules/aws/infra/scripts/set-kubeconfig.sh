#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Sets KUBECONFIG in the current shell for the EKS cluster.
# Writes to ~/.kube/langsmith-<cluster> — never touches ~/.kube/config.
#
# Must be sourced (not executed) to take effect in the calling shell:
#   source ./set-kubeconfig.sh
#   source ./set-kubeconfig.sh [cluster-name] [region]
#
# After sourcing, kubectl and k9s will use the cluster automatically.
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TFVARS="$SCRIPT_DIR/../terraform.tfvars"

if [[ -z "${1:-}" ]]; then
  if [[ ! -f "$TFVARS" ]]; then
    echo "Error: terraform.tfvars not found at $TFVARS" >&2
    return 1
  fi
  NAME_PREFIX=$(grep -E '^\s*name_prefix\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}')
  ENVIRONMENT=$(grep -E '^\s*environment\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}')
  REGION=$(grep -E '^\s*region\s*=' "$TFVARS" | head -1 | awk -F'"' '{print $2}')
  CLUSTER_NAME="${NAME_PREFIX}-${ENVIRONMENT}-eks"
else
  CLUSTER_NAME="${1}"
  REGION="${2:-us-east-1}"
fi

KUBECONFIG_FILE="$HOME/.kube/langsmith-${CLUSTER_NAME}"

echo "Cluster: $CLUSTER_NAME  Region: $REGION"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
echo "KUBECONFIG=$KUBECONFIG"
