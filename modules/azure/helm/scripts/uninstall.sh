#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# uninstall.sh — Uninstall LangSmith Helm release from AKS.
#
# Usage (from azure/):
#   ./helm/scripts/uninstall.sh
#
# Also available as: make uninstall
#
# Removes: Helm release, operator-managed LGP resources.
# Leaves: AKS cluster, Key Vault, Blob Storage, Postgres, Redis (infrastructure intact).
#
# NOTE: Uninstall BEFORE running terraform destroy.
#   The Azure Load Balancer in front of the ingress controller blocks VNet deletion.
#   Running terraform destroy while it is still deployed causes a stall.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
source "$INFRA_DIR/scripts/_common.sh"

# RELEASE_NAME and NAMESPACE from the environment if set, else
# langsmith_release_name and langsmith_namespace from terraform.tfvars, else
# langsmith: the same order deploy.sh uses.
RELEASE_NAME="${RELEASE_NAME:-$(_parse_tfvar langsmith_release_name || echo langsmith)}"
NAMESPACE="${NAMESPACE:-$(_parse_tfvar langsmith_namespace || echo langsmith)}"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Uninstall"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Resolve cluster from terraform outputs ─────────────────────────────────
# Stop without both outputs, or if the credential fetch fails: kubectl would
# otherwise act on whatever its current context is, which may be another cluster.
CLUSTER_NAME=$(_tf_out aks_cluster_name) || {
  fail "Could not read aks_cluster_name. Is 'terraform apply' complete?"
  exit 1
}
RESOURCE_GROUP=$(_tf_out aks_resource_group_name) || {
  fail "Could not read aks_resource_group_name. Run 'make apply' to record it."
  exit 1
}

info "Cluster: $CLUSTER_NAME"
info "Resource group: $RESOURCE_GROUP"
echo ""
az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing >/dev/null || {
  fail "Could not fetch credentials for cluster '${CLUSTER_NAME}'."
  action "make kubeconfig  (to retry once the error above is fixed)"
  exit 1
}
_aks_kubelogin_convert "$CLUSTER_NAME" "$RESOURCE_GROUP" || true

# ── Validate cluster connectivity ───────────────────────────────────────────
if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
  fail "kubectl cannot reach the cluster"
  action "make kubeconfig  (to fetch AKS credentials)"
  exit 1
fi

# ── Remove operator-managed LGP resources ──────────────────────────────────
_lgp_count=$(kubectl get lgp -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ') || _lgp_count=0
if [[ "$_lgp_count" -gt 0 ]]; then
  info "Removing ${_lgp_count} LGP resource(s) in namespace/${NAMESPACE}..."
  kubectl delete lgp --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
fi

# ── Uninstall Helm release ──────────────────────────────────────────────────
if helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --short 2>/dev/null | grep -q "^${RELEASE_NAME}$"; then
  info "Uninstalling Helm release: ${RELEASE_NAME}..."
  # deploy.sh creates the LLM Gateway's Ingress outside the release.
  kubectl delete ingress -n "$NAMESPACE" -l app.kubernetes.io/managed-by=langsmith-azure-deploy --ignore-not-found 2>/dev/null || true
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m 2>/dev/null || \
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
  pass "Helm release '${RELEASE_NAME}' uninstalled"
else
  skip "Helm release '${RELEASE_NAME}' not found in namespace '${NAMESPACE}'"
fi

# ── Remove the Envoy Gateway resources deploy.sh created ────────────────────
# They sit outside the Helm release. Deleting the Gateway removes the proxy
# Service and with it the Azure Load Balancer IP.
_ingress_controller=$(_parse_tfvar ingress_controller) || _ingress_controller="envoy-gateway"
if [[ "$_ingress_controller" == "envoy-gateway" ]]; then
  kubectl delete gateway langsmith-gateway -n "$NAMESPACE" --ignore-not-found --wait --timeout=120s >/dev/null 2>&1 || true
  kubectl delete gatewayclass langsmith-eg --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete envoyproxy langsmith-proxy -n envoy-gateway-system --ignore-not-found >/dev/null 2>&1 || true
  pass "Envoy Gateway resources removed (Gateway, GatewayClass, EnvoyProxy)"
fi

# ── Optionally delete namespace ─────────────────────────────────────────────
echo ""
printf "  Delete namespace '${NAMESPACE}'? (removes all K8s resources) [y/N] "
read -r _del_ns
if [[ "$_del_ns" =~ ^[Yy]$ ]]; then
  kubectl delete namespace "$NAMESPACE" --timeout=60s 2>/dev/null || true
  pass "Namespace '${NAMESPACE}' deleted"
else
  info "Namespace '${NAMESPACE}' preserved"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Uninstall complete."
echo "══════════════════════════════════════════════════════"
echo ""
echo "To destroy infrastructure:"
[[ "$_ingress_controller" == "nginx" ]] && \
  echo "  helm uninstall ingress-nginx -n ingress-nginx --wait  # remove Azure LB"
echo "  make destroy"
warn "Then: make clean    (removes local secrets and generated files)"
echo ""
