#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# generate-secrets.sh — create the Kubernetes Secrets the LangSmith chart reads
# via existingSecretName, on an OpenShift cluster.
#
# Usage:
#   export LANGSMITH_LICENSE_KEY=...
#   export INITIAL_ORG_ADMIN_PASSWORD=...
#   ./generate-secrets.sh
#
# What this creates:
#   langsmith-secrets  — application-level secret: license key, api_key_salt,
#                        jwt_secret, admin password, OAuth, blob storage keys and
#                        the per-product encryption keys. Read by every LangSmith
#                        pod via config.existingSecretName (set in values.yaml).
#   langsmith-postgres — connection_url, only when POSTGRES_CONNECTION_URL is set
#   langsmith-redis    — connection_url, only when REDIS_CONNECTION_URL is set
#
# The two datastore secrets have a second possible writer: the Terraform secrets
# module (infra/modules/secrets) creates them when postgres_connection_url /
# redis_connection_url are set. Supply each URL in one place, not both.
#
# Key names are fixed by chart 0.16 — the chart looks up literal keys, and a
# misspelled key surfaces as an empty environment variable in the pod, not an
# error. Values are piped in as base64 rather than passed as --from-literal so
# they never appear in the process list. Nothing here echoes a secret value.
#
# Safe to re-run: applies in place, and regenerating api_key_salt or jwt_secret is
# avoided by exporting them (see below) — a new api_key_salt invalidates every
# issued API key.
set -euo pipefail

NAMESPACE="${NAMESPACE:-langsmith}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-langsmith}"

for tool in oc base64 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found on PATH." >&2; exit 1; }
done

if [[ -z "${LANGSMITH_LICENSE_KEY:-}" ]]; then
  echo "ERROR: LANGSMITH_LICENSE_KEY is not set." >&2
  echo "       export LANGSMITH_LICENSE_KEY=... and re-run." >&2
  exit 1
fi

# _validate_admin_password <password> — the chart's complexity rule, ported from
# aws/infra/scripts/setup-env.sh and azure/infra/scripts/_common.sh. The rule lives
# in the chart's validate.yaml, which skips it entirely once
# config.existingSecretName is set, so nothing else enforces it on this path: an
# invalid password is accepted by Helm and rejected by the application at org
# bootstrap.
#
# Prints the reason and returns non-zero. It never prints the password.
_validate_admin_password() {
  local _pw="$1" _len
  # Count bytes, because the chart's rule is Go's len(), which counts bytes.
  _len=$(printf '%s' "$_pw" | wc -c | tr -d '[:space:]')
  if (( _len < 12 )); then
    echo "must be at least 12 bytes long (a non-ASCII character counts as more than one)"
    return 1
  fi
  # The bracket expression lists the symbols the chart accepts: ] first and - last
  # so both are literal.
  if ! printf '%s' "$_pw" | grep -q '[]!#$%()+,./:?@[^_{~}-]'; then
    echo 'must contain at least one symbol from !#$%()+,-./:?@[]^_{~}'
    return 1
  fi
  if ! printf '%s' "$_pw" | grep -q '[a-z]'; then
    echo "must contain at least one lowercase letter"
    return 1
  fi
  if ! printf '%s' "$_pw" | grep -q '[A-Z]'; then
    echo "must contain at least one uppercase letter"
    return 1
  fi
  return 0
}

if [[ -n "${INITIAL_ORG_ADMIN_PASSWORD:-}" ]]; then
  if ! _reason=$(_validate_admin_password "$INITIAL_ORG_ADMIN_PASSWORD"); then
    echo "ERROR: INITIAL_ORG_ADMIN_PASSWORD $_reason" >&2
    exit 1
  fi
fi

# Generated once per run when not supplied. Export both to keep them stable across
# re-runs: api_key_salt is what existing API keys are hashed against, and jwt_secret
# invalidates live sessions when it changes.
API_KEY_SALT="${API_KEY_SALT:-$(openssl rand -hex 32)}"
JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32)}"

DATA_LINES=""
EXPECTED_KEYS=""

# _put <secret-key> <value> — appends a base64 data line, skipping empty values.
# An absent key and an empty key are not the same to the chart: for the keys the
# chart marks non-optional (insights/polly/agent_builder encryption keys) an absent
# key fails the pod at startup, which is the loud failure we want, while an empty
# key starts the pod with an empty secret.
_put() {
  local key="$1" value="${2:-}" encoded
  [[ -n "$value" ]] || return 0
  encoded=$(printf '%s' "$value" | base64 | tr -d '\n')
  DATA_LINES="${DATA_LINES}  ${key}: ${encoded}
"
  EXPECTED_KEYS="${EXPECTED_KEYS}${key}
"
}

_put langsmith_license_key       "$LANGSMITH_LICENSE_KEY"
_put api_key_salt                "$API_KEY_SALT"
_put jwt_secret                  "$JWT_SECRET"
_put initial_org_admin_password  "${INITIAL_ORG_ADMIN_PASSWORD:-}"

# OAuth / SSO. config.oauth.oauthClientId, oauthClientSecret and oauthIssuerUrl in
# values files do nothing once existingSecretName is set — these keys are the only
# way in. oauth_client_secret is read only when config.authType is "mixed".
_put oauth_client_id             "${OAUTH_CLIENT_ID:-}"
_put oauth_client_secret         "${OAUTH_CLIENT_SECRET:-}"
_put oauth_issuer_url            "${OAUTH_ISSUER_URL:-}"

# Blob storage static credentials. Leave unset when the pods reach object storage
# through an ambient identity instead.
_put blob_storage_access_key         "${BLOB_STORAGE_ACCESS_KEY:-}"
_put blob_storage_access_key_secret  "${BLOB_STORAGE_ACCESS_KEY_SECRET:-}"

# Per-product encryption keys (Fernet). Required by the pods of whichever product
# is enabled, so set the matching variable when you turn one on in
# values-overrides.yaml. Losing one makes that product's stored data unreadable.
_put agent_builder_encryption_key  "${AGENT_BUILDER_ENCRYPTION_KEY:-}"
_put insights_encryption_key       "${INSIGHTS_ENCRYPTION_KEY:-}"
_put polly_encryption_key          "${POLLY_ENCRYPTION_KEY:-}"
_put engine_encryption_key         "${ENGINE_ENCRYPTION_KEY:-}"
_put langsmith_signing_jwks        "${LANGSMITH_SIGNING_JWKS:-}"
_put sandbox_callback_signing_jwk  "${SANDBOX_CALLBACK_SIGNING_JWK:-}"

echo ""
echo "LangSmith on OpenShift — create chart secrets"
echo "  namespace : $NAMESPACE"
echo ""

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# Grant the SCC created by infra/modules/scc to the namespace's service account.
# Non-fatal: the SCC may not exist yet, or the cluster may run LangSmith under the
# built-in nonroot SCC instead.
oc adm policy add-scc-to-user langsmith-scc -z "$SERVICE_ACCOUNT" -n "$NAMESPACE" 2>/dev/null \
  || echo "  NOTE: could not grant langsmith-scc to serviceaccount/$SERVICE_ACCOUNT (see TROUBLESHOOTING.md)."

oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: langsmith-secrets
type: Opaque
data:
${DATA_LINES}
EOF

# Datastore connection URLs. Each carries its password, so the chart needs only the
# one key. Rename the key and you also have to set
# postgres.external.connectionUrlSecretKey / redis.external.connectionUrlSecretKey.
_put_datastore_secret() {
  local secret_name="$1" url="$2" encoded
  encoded=$(printf '%s' "$url" | base64 | tr -d '\n')
  oc apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
type: Opaque
data:
  connection_url: ${encoded}
EOF
}

if [[ -n "${POSTGRES_CONNECTION_URL:-}" ]]; then
  _put_datastore_secret langsmith-postgres "$POSTGRES_CONNECTION_URL"
else
  echo "  SKIP: langsmith-postgres — POSTGRES_CONNECTION_URL not set (Terraform may own it)."
fi

if [[ -n "${REDIS_CONNECTION_URL:-}" ]]; then
  _put_datastore_secret langsmith-redis "$REDIS_CONNECTION_URL"
else
  echo "  SKIP: langsmith-redis — REDIS_CONNECTION_URL not set (Terraform may own it)."
fi

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "  Keys in secret/langsmith-secrets:"
ACTUAL_KEYS=$(oc get secret langsmith-secrets -n "$NAMESPACE" \
  -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}')

MISSING=0
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if printf '%s\n' "$ACTUAL_KEYS" | grep -qx "$key"; then
    echo "    [ok]      $key"
  else
    echo "    [MISSING] $key"
    MISSING=$((MISSING + 1))
  fi
done <<< "$EXPECTED_KEYS"

echo ""
if [[ "$MISSING" -ne 0 ]]; then
  echo "ERROR: $MISSING key(s) did not land in the secret." >&2
  exit 1
fi

echo "  Secrets ready. values.yaml already points the chart at them:"
echo "    config.existingSecretName: langsmith-secrets"
echo "    postgres.external.existingSecretName / redis.external.existingSecretName"
echo ""
echo "Next: fill in values-overrides.yaml (hostname, datastore hosts, blob storage), then run deploy.sh."
