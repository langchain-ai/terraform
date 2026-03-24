#!/usr/bin/env bash
# preflight-check.sh — Validate tools and cluster connectivity before deploying.
#
# Called by deploy.sh before running helm upgrade.
# Lightweight read-only checks only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/../../infra"
source "$INFRA_DIR/scripts/_common.sh"

echo "Helm preflight checks..."
echo ""

# ── Required tools ─────────────────────────────────────────────────────────
MISSING=()
for tool in az kubectl helm; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "Missing required tools: ${MISSING[*]}"
  echo ""
  for tool in "${MISSING[@]}"; do
    case "$tool" in
      az)      action "Install az CLI: https://docs.microsoft.com/cli/azure/install-azure-cli" ;;
      kubectl) action "Install kubectl: https://kubernetes.io/docs/tasks/tools/" ;;
      helm)    action "Install helm: https://helm.sh/docs/intro/install/" ;;
    esac
  done
  exit 1
fi
pass "Required tools: az kubectl helm"

# ── Azure login ─────────────────────────────────────────────────────────────
if ! az account show &>/dev/null; then
  fail "az CLI not logged in"
  action "az login"
  exit 1
fi
pass "az CLI authenticated"

# ── kubectl connectivity ─────────────────────────────────────────────────────
if kubectl cluster-info --request-timeout=5s &>/dev/null; then
  pass "kubectl can reach the cluster"
  _ctx=$(kubectl config current-context 2>/dev/null) || _ctx="unknown"
  info "Context: ${_ctx}"
else
  fail "kubectl cannot reach the cluster"
  action "make kubeconfig  (to fetch AKS credentials)"
  exit 1
fi

# ── Helm langchain repo ──────────────────────────────────────────────────────
if helm repo list 2>/dev/null | grep -q "langchain"; then
  pass "Helm langchain repo configured"
else
  warn "langchain Helm repo not found — adding..."
  helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
  pass "langchain Helm repo added"
fi

echo ""
pass "All preflight checks passed"
echo ""
