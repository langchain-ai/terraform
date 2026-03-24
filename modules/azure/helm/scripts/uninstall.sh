#!/usr/bin/env bash
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
# NOTE: Uninstall Helm BEFORE running terraform destroy.
#   The Azure Load Balancer created by NGINX blocks VNet deletion.
#   Running terraform destroy while NGINX is still deployed causes a stall.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Uninstall"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Resolve cluster from terraform outputs ─────────────────────────────────
CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name 2>/dev/null) || CLUSTER_NAME=""
RESOURCE_GROUP=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name 2>/dev/null) || RESOURCE_GROUP=""

if [[ -n "$CLUSTER_NAME" && -n "$RESOURCE_GROUP" ]]; then
  info "Cluster: $CLUSTER_NAME"
  info "Resource group: $RESOURCE_GROUP"
  echo ""
  az aks get-credentials --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" --overwrite-existing 2>/dev/null || true
fi

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
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m 2>/dev/null || \
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true
  pass "Helm release '${RELEASE_NAME}' uninstalled"
else
  skip "Helm release '${RELEASE_NAME}' not found in namespace '${NAMESPACE}'"
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
echo "  helm uninstall ingress-nginx -n ingress-nginx --wait  # remove Azure LB"
echo "  make destroy"
warn "Then: make clean    (removes local secrets and generated files)"
echo ""
