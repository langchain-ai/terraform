#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Uninstalls LangSmith from the correct GKE cluster.
#
# Resolves cluster name and region from terraform.tfvars + terraform output,
# updates kubeconfig to target the right cluster, then removes the Helm release
# and operator-managed resources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"

# ── tfvars parser ─────────────────────────────────────────────────────────────
_parse_tfvar() {
  local key="$1"
  awk -F= "/^[[:space:]]*${key}[[:space:]]*=/{gsub(/[ \"']/, \"\", \$2); print \$2; exit}" \
    "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}

# ── Resolve config from terraform.tfvars ──────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

_project_id=$(_parse_tfvar "project_id")
_name_prefix=$(_parse_tfvar "name_prefix")
_environment=$(_parse_tfvar "environment")
_region=$(_parse_tfvar "region")
_region="${_region:-us-west2}"

if [[ -z "$_project_id" || -z "$_environment" ]]; then
  echo "ERROR: Could not resolve project_id and/or environment from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has these values set." >&2
  exit 1
fi

echo "Resolved from terraform.tfvars:"
echo "  name_prefix  = ${_name_prefix:-(empty)}"
echo "  environment  = $_environment"
echo "  project_id   = $_project_id"
echo "  region       = $_region"
echo ""

# ── Get cluster name from Terraform output ────────────────────────────────────
echo "Reading cluster name from Terraform output..."
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read cluster_name. Is 'terraform apply' complete?" >&2
  exit 1
}
echo "  cluster_name = $_cluster_name"
echo ""

# ── Point kubeconfig at the right cluster ─────────────────────────────────────
echo "Updating kubeconfig for cluster: $_cluster_name..."
"$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" "$_region" "$_project_id"
echo "  Active context: $(kubectl config current-context)"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
echo "This will remove:"
echo "  - Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'"
echo "  - Operator-managed LangSmith resources in namespace '$NAMESPACE'"
echo ""
printf "Proceed? [y/N] "
read -r _confirm
if [[ "$_confirm" != "y" && "$_confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

# ── Uninstall Helm release ────────────────────────────────────────────────────
if helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null | grep -q '"name"'; then
  echo "Uninstalling Helm release '$RELEASE_NAME'..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
else
  echo "Helm release '$RELEASE_NAME' not found in namespace '$NAMESPACE' — skipping."
fi
echo ""

# ── Clean up operator-managed resources ──────────────────────────────────────
# platform-backend creates agent-builder and LangGraph resources at runtime with
# no Helm owner reference. Target only LangSmith resources by label so workloads
# from other teams sharing this namespace are not affected.
echo "Removing operator-managed LangSmith resources from namespace '$NAMESPACE'..."
kubectl delete deployments,services,pods,jobs,statefulsets,replicasets \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -n "$NAMESPACE" --ignore-not-found
# Operator-spawned agent deployment pods use a different label pattern
kubectl delete deployments,pods \
  -l "langsmith.dev/managed-by=operator" \
  -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
echo ""

echo "Uninstall complete."
echo ""
echo "Note: GKE cluster, Cloud SQL, Memorystore, and GCS bucket are managed by Terraform."
echo "To remove infrastructure: terraform -chdir=$INFRA_DIR destroy"
