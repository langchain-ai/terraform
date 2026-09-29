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
  # _tfvars.sh alone: this runs in the caller's shell, which should not
  # collect the rest of _common.sh.
  source "$SCRIPT_DIR/_tfvars.sh" "$SCRIPT_DIR/.."
  NAME_PREFIX=$(_parse_tfvar name_prefix)
  ENVIRONMENT=$(_parse_tfvar environment)
  REGION=$(_parse_tfvar region)
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
