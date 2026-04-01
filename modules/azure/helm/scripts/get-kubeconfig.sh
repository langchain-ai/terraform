#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# get-kubeconfig.sh — Fetch AKS credentials into ~/.kube/config
#
# Usage (from azure/):
#   ./helm/scripts/get-kubeconfig.sh
#
# Also available as: make kubeconfig
#
# Reads cluster name and resource group from terraform outputs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"

source "$INFRA_DIR/scripts/_common.sh"

echo ""
echo "Fetching AKS credentials..."
echo ""

CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read aks_cluster_name. Is 'terraform apply' complete?" >&2; exit 1
}
RESOURCE_GROUP=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name 2>/dev/null) || {
  echo "ERROR: Could not read resource_group_name." >&2; exit 1
}

info "Cluster       : $CLUSTER_NAME"
info "Resource group: $RESOURCE_GROUP"
echo ""

az aks get-credentials \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --overwrite-existing

echo ""
pass "kubeconfig updated"
echo ""
info "Active context: $(kubectl config current-context)"
echo ""
kubectl get nodes
echo ""
echo "Next:"
echo "  make k8s-secrets   # pull Key Vault → langsmith-config-secret"
echo "  make init-values   # generate Helm values from terraform outputs"
echo ""
