#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# create-k8s-secrets.sh — Create langsmith-config-secret from Azure Key Vault
#
# Usage:
#   cd terraform/modules/azure/infra
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
#                             With enable_sandboxes = true it also carries
#                             sandbox_callback_signing_jwk, and with
#                             sandbox_deployment_mode = separate_cluster
#                             sandbox_service_auth_secret.
#   langsmith-sandbox-runtime — separate_cluster only, in the sandbox cluster's
#                             namespace: exactly sandbox_service_auth_secret and
#                             sandbox_callback_signing_jwk, never a copy of
#                             langsmith-config-secret. Read by the
#                             langsmith-sandbox chart (config.existingSecretName).
#   smithdb-taskdb          — postgres_password for the SmithDB backfill's taskdb,
#                             when Key Vault holds smithdb-taskdb-password. Read
#                             through smithdb.migration.taskdb.postgres.auth.
#
# The other two required secrets are created by Terraform (Pass 1):
#   langsmith-postgres-secret — connection_url
#   langsmith-redis-secret    — connection_url, redis_cluster_node_uris,
#                               redis_cluster_password
#
# Safe to re-run — uses --dry-run=client | kubectl apply so it updates in place.

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/_common.sh"

# ── Resolve Key Vault name from terraform output ───────────────────────────────
if ! KV_NAME=$(_tf_out keyvault_name); then
  KV_NAME=$(_require_kv_name) || exit 1
  echo "  (terraform output unavailable — using derived KV name: $KV_NAME)"
fi

# ── Resolve namespace ──────────────────────────────────────────────────────────
NAMESPACE=$(_tf_out langsmith_namespace) || NAMESPACE="langsmith"

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

_kv_exists() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query name -o tsv >/dev/null 2>&1
}

API_KEY_SALT=$(_kv "langsmith-api-key-salt")
JWT_SECRET=$(_kv "langsmith-jwt-secret")
LICENSE_KEY=$(_kv "langsmith-license-key")
ADMIN_PASSWORD=$(_kv "langsmith-admin-password")
DEPLOY_KEY=$(_kv "langsmith-deployments-encryption-key")
AGENT_KEY=$(_kv "langsmith-agent-builder-encryption-key")
INSIGHTS_KEY=$(_kv "langsmith-insights-encryption-key")
POLLY_KEY=$(_kv "langsmith-polly-encryption-key")

# SSO/OIDC — optional, only present when enable_sso_oidc = true (see
# manage-keyvault.sh). Fetched here unconditionally so this script stays the
# single source of truth for langsmith-config-secret; the --from-literal args
# below are built conditionally so a deployment that never sets these up is
# unaffected.
_OAUTH_ARGS=()
if _kv_exists "langsmith-oauth-client-id"; then
  OAUTH_CLIENT_ID=$(_kv "langsmith-oauth-client-id")
  OAUTH_CLIENT_SECRET=$(_kv "langsmith-oauth-client-secret")
  OAUTH_ISSUER_URL=$(_kv "langsmith-oauth-issuer-url")
  _OAUTH_ARGS=(
    "--from-literal=oauth_client_id=$OAUTH_CLIENT_ID"
    "--from-literal=oauth_client_secret=$OAUTH_CLIENT_SECRET"
    "--from-literal=oauth_issuer_url=$OAUTH_ISSUER_URL"
  )
fi

# The sandbox secrets go to kubectl as files in a private directory rather than
# as --from-literal arguments, which any user on the host can read from ps. The
# directory also holds the sandbox cluster's kubeconfig in separate_cluster mode.
_SECRETS_TMP=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/langsmith-secrets.XXXXXX")
trap 'rm -rf "$_SECRETS_TMP"' EXIT

# Sandboxes: platform-backend and sandbox-host read sandbox_callback_signing_jwk
# from this secret, and neither starts without it. Copied whenever the vault
# holds it, so turning enable_sandboxes off and on again keeps the same key.
_SANDBOX_ARGS=()
if _kv_exists "langsmith-sandbox-callback-signing-jwk"; then
  printf '%s' "$(_kv "langsmith-sandbox-callback-signing-jwk")" > "$_SECRETS_TMP/sandbox_callback_signing_jwk"
  _SANDBOX_ARGS=("--from-file=sandbox_callback_signing_jwk=$_SECRETS_TMP/sandbox_callback_signing_jwk")
elif _tfvar_is_true "enable_sandboxes"; then
  echo "  ERROR: enable_sandboxes = true but Key Vault '$KV_NAME' has no langsmith-sandbox-callback-signing-jwk." >&2
  echo "         Run: make seed-secrets, then re-run this script." >&2
  exit 1
fi

# separate_cluster: the dedicated sandbox service-auth secret, under the key the
# langsmith chart reads through sandboxes.serviceAuth.secretKey. The sandbox
# cluster runs untrusted code, so it gets this secret and never api_key_salt;
# the chart refuses separateCluster on the salt, and so does this script.
# Copied whenever the vault holds it, like the JWK.
if _kv_exists "langsmith-sandbox-service-auth-secret"; then
  printf '%s' "$(_kv "langsmith-sandbox-service-auth-secret")" > "$_SECRETS_TMP/sandbox_service_auth_secret"
  if [[ "$(cat "$_SECRETS_TMP/sandbox_service_auth_secret")" == "$API_KEY_SALT" ]]; then
    echo "  ERROR: langsmith-sandbox-service-auth-secret in Key Vault '$KV_NAME' equals langsmith-api-key-salt." >&2
    echo "         The sandbox cluster must never hold the salt. Set a new random value, then re-run this script:" >&2
    echo "           ./scripts/manage-keyvault.sh delete langsmith-sandbox-service-auth-secret && make seed-secrets" >&2
    exit 1
  fi
  _SANDBOX_ARGS+=("--from-file=sandbox_service_auth_secret=$_SECRETS_TMP/sandbox_service_auth_secret")
elif _separate_cluster_sandboxes; then
  echo "  ERROR: sandbox_deployment_mode = separate_cluster but Key Vault '$KV_NAME' has no langsmith-sandbox-service-auth-secret." >&2
  echo "         Run: make seed-secrets, then re-run this script." >&2
  exit 1
fi

# The license key is the one value here that nothing has checked since the
# setup-env prompt (#250). Written as it stands, an empty or malformed value
# surfaces inside platform-backend at startup as a base64 error that names
# neither licensing nor this script. Stop here instead, naming the secret.
if ! _license_err=$(_validate_license_key "$LICENSE_KEY"); then
  echo "  ERROR: langsmith-license-key in Key Vault '$KV_NAME' failed validation: ${_license_err}" >&2
  echo "         Fix the vault first, then re-run this script:" >&2
  echo "           ./scripts/manage-keyvault.sh set langsmith-license-key '<key>'" >&2
  exit 1
fi

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
  "${_OAUTH_ARGS[@]:+"${_OAUTH_ARGS[@]}"}" \
  "${_SANDBOX_ARGS[@]:+"${_SANDBOX_ARGS[@]}"}" \
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
if _tfvar_is_true "enable_sandboxes"; then
  REQUIRED_KEYS+=("sandbox_callback_signing_jwk")
fi
if _separate_cluster_sandboxes; then
  REQUIRED_KEYS+=("sandbox_service_auth_secret")
fi

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

# ── SmithDB taskdb secret ──────────────────────────────────────────────────────
# Piped through --from-file=/dev/stdin so the password never appears in argv.
# A vault seeded before this secret existed skips it; deploy.sh stops the
# backfill until make seed-secrets adds it.
echo ""
if _kv_exists "smithdb-taskdb-password"; then
  TASKDB_PASSWORD=$(_kv "smithdb-taskdb-password")
  echo "  Applying smithdb-taskdb to namespace/$NAMESPACE..."
  printf '%s' "$TASKDB_PASSWORD" | kubectl create secret generic smithdb-taskdb \
    --namespace "$NAMESPACE" \
    --from-file=postgres_password=/dev/stdin \
    --dry-run=client -o yaml | kubectl apply -f -
  unset TASKDB_PASSWORD
else
  echo "  smithdb-taskdb-password not in Key Vault; skipping smithdb-taskdb (run make seed-secrets)"
fi
# ── Sandbox runtime secret (separate_cluster) ──────────────────────────────────
# The langsmith-sandbox release in the sandbox cluster reads these two values
# from a Secret of its own: the same service-auth secret and JWK as above, so
# both clusters agree. Written through a kubeconfig of its own, so the current
# context stays on the LangSmith cluster. Terraform created the namespace.
if _separate_cluster_sandboxes; then
  echo ""
  if ! SANDBOX_NAMESPACE=$(_tf_out sandbox_namespace) \
    || ! SANDBOX_CLUSTER=$(_tf_out sandbox_cluster_name); then
    echo "  ERROR: the sandbox cluster outputs are missing. Run make apply with sandbox_deployment_mode = separate_cluster first." >&2
    exit 1
  fi
  SANDBOX_RUNTIME_SECRET=$(_tf_out sandbox_runtime_secret_name) || SANDBOX_RUNTIME_SECRET="langsmith-sandbox-runtime"
  if ! _sandbox_kubeconfig "$_SECRETS_TMP/sandbox-kubeconfig"; then
    echo "  ERROR: could not fetch credentials for the sandbox cluster '$SANDBOX_CLUSTER'." >&2
    exit 1
  fi
  echo "  Applying $SANDBOX_RUNTIME_SECRET to $SANDBOX_CLUSTER, namespace/$SANDBOX_NAMESPACE..."
  KUBECONFIG="$_SECRETS_TMP/sandbox-kubeconfig" kubectl create secret generic "$SANDBOX_RUNTIME_SECRET" \
    --namespace "$SANDBOX_NAMESPACE" \
    --from-file=sandbox_service_auth_secret="$_SECRETS_TMP/sandbox_service_auth_secret" \
    --from-file=sandbox_callback_signing_jwk="$_SECRETS_TMP/sandbox_callback_signing_jwk" \
    --dry-run=client -o yaml | KUBECONFIG="$_SECRETS_TMP/sandbox-kubeconfig" kubectl apply -f -
  echo -e "  ${GREEN}[✓]${NC} $SANDBOX_RUNTIME_SECRET (sandbox_service_auth_secret, sandbox_callback_signing_jwk)"
  echo "  A changed value reaches sandbox-host on its next restart."
fi

# Note: langsmith-clickhouse secret is NOT needed for in-cluster ClickHouse
# (clickhouse_source = "in-cluster"). The chart manages the connection internally.
# For external ClickHouse, init-values.sh prompts for the connection and creates
# that secret, and writes clickhouse.external into values-overrides.yaml.

echo ""
echo "Next: fill values-overrides.yaml and run helm upgrade --install"
