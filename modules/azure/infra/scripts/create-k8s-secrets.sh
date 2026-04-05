#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# create-k8s-secrets.sh — Create langsmith-config-secret from Azure Key Vault
#
# Usage:
#   cd terraform/azure/infra
#   ./scripts/create-k8s-secrets.sh
#
# Prerequisites:
#   - terraform apply complete (Key Vault and secrets exist)
#   - az aks get-credentials run (kubectl context set)
#   - langsmith namespace exists (created by k8s-bootstrap module)
#
# What this creates:
#   langsmith-config-secret — license key, API salt, JWT secret, admin password,
#                             and four Fernet encryption keys. Read by all LangSmith
#                             pods via config.existingSecretName in Helm values.
#
# The other two required secrets are created by Terraform (Pass 1):
#   langsmith-postgres-secret — connection_url
#   langsmith-redis-secret    — connection_url
#
# Safe to re-run — uses --dry-run=client | kubectl apply so it updates in place.

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Resolve Key Vault name from terraform output ───────────────────────────────
if ! KV_NAME=$(cd "$INFRA_DIR" && terraform output -raw keyvault_name 2>/dev/null); then
  # fallback: read identifier from terraform.tfvars
  _identifier=$(grep -E '^\s*identifier\s*=' "$INFRA_DIR/terraform.tfvars" \
    | sed 's/.*=[[:space:]]*"\([^"]*\)".*/\1/' | tr -d '[:space:]') || _identifier=""
  KV_NAME="langsmith-kv${_identifier}"
  echo "  (terraform output unavailable — using derived KV name: $KV_NAME)"
fi

# ── Resolve namespace ──────────────────────────────────────────────────────────
NAMESPACE=$(cd "$INFRA_DIR" && terraform output -raw langsmith_namespace 2>/dev/null) || NAMESPACE="langsmith"

echo ""
echo "LangSmith — create K8s config secret"
echo "  key_vault : $KV_NAME"
echo "  namespace : $NAMESPACE"
echo ""

# ── Pull secrets from Key Vault ────────────────────────────────────────────────
echo "  Reading secrets from Key Vault..."

_kv() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv
}

API_KEY_SALT=$(_kv "langsmith-api-key-salt")
JWT_SECRET=$(_kv "langsmith-jwt-secret")
LICENSE_KEY=$(_kv "langsmith-license-key")
ADMIN_PASSWORD=$(_kv "langsmith-admin-password")
DEPLOY_KEY=$(_kv "langsmith-deployments-encryption-key")
AGENT_KEY=$(_kv "langsmith-agent-builder-encryption-key")
INSIGHTS_KEY=$(_kv "langsmith-insights-encryption-key")
POLLY_KEY=$(_kv "langsmith-polly-encryption-key")

echo "  All secrets retrieved."
echo ""

# ── Create/update the secret ───────────────────────────────────────────────────
echo "  Applying langsmith-config-secret to namespace/$NAMESPACE..."

kubectl create secret generic langsmith-config-secret \
  --namespace "$NAMESPACE" \
  --from-literal=api_key_salt="$API_KEY_SALT" \
  --from-literal=jwt_secret="$JWT_SECRET" \
  --from-literal=langsmith_license_key="$LICENSE_KEY" \
  --from-literal=initial_org_admin_password="$ADMIN_PASSWORD" \
  --from-literal=deployments_encryption_key="$DEPLOY_KEY" \
  --from-literal=agent_builder_encryption_key="$AGENT_KEY" \
  --from-literal=insights_encryption_key="$INSIGHTS_KEY" \
  --from-literal=polly_encryption_key="$POLLY_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""

# ── Verify keys in the secret ──────────────────────────────────────────────────
REQUIRED_KEYS=(
  "api_key_salt"
  "jwt_secret"
  "langsmith_license_key"
  "initial_org_admin_password"
  "deployments_encryption_key"
  "agent_builder_encryption_key"
  "insights_encryption_key"
  "polly_encryption_key"
)

echo "  Verifying keys in langsmith-config-secret..."
echo ""

ACTUAL_KEYS=$(kubectl get secret langsmith-config-secret -n "$NAMESPACE" \
  -o json | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join(sorted(d['data'].keys())))")

ERRORS=0
for KEY in "${REQUIRED_KEYS[@]}"; do
  if echo "$ACTUAL_KEYS" | grep -q "^${KEY}$"; then
    echo -e "  ${GREEN}[✓]${NC} $KEY"
  else
    echo -e "  ${RED}[✗]${NC} $KEY — MISSING"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo -e "  ${GREEN}All ${#REQUIRED_KEYS[@]} keys present. Ready for helm install.${NC}"
else
  echo -e "  ${RED}${ERRORS} key(s) missing. Re-run this script or check Key Vault secrets.${NC}"
  exit 1
fi
# Note: langsmith-clickhouse secret is NOT needed for in-cluster ClickHouse
# (clickhouse_source = "in-cluster"). The chart manages the connection internally.
# For external ClickHouse, create the secret manually and set
# clickhouse.external.existingSecretName in langsmith-values-insights.yaml.

echo ""
echo "Next: fill values-overrides.yaml and run helm upgrade --install"
