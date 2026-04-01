#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# apply-eso.sh — Apply ESO ClusterSecretStore + ExternalSecret for LangSmith.
#
# Creates (or updates) the ESO resources that sync SSM Parameter Store secrets
# into the langsmith-config Kubernetes Secret. Can be run standalone to re-sync
# ESO without a full Helm redeploy.
#
# Usage (from aws/):
#   ./helm/scripts/apply-eso.sh
#
# Reads: terraform.tfvars (name_prefix, environment, region)
# Requires: kubectl access to the target cluster, ESO CRDs installed
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

# Check if an SSM parameter exists. Returns 0 if found, 1 if not found.
# Surfaces non-ParameterNotFound errors (e.g. expired credentials) to stderr.
_ssm_key_exists() {
  local _err
  _err=$(aws ssm get-parameter --name "$1" --region "$_region" --query 'Parameter.Name' --output text 2>&1) && return 0
  if echo "$_err" | grep -q "ParameterNotFound"; then
    return 1
  fi
  echo "ERROR: SSM check for $1 failed unexpectedly: $_err" >&2
  echo "       Fix the underlying issue (expired credentials, network, IAM) before continuing." >&2
  exit 1
}

NAMESPACE="${NAMESPACE:-langsmith}"

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-}"
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: Could not read name_prefix from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi
if [[ -z "$_environment" ]]; then
  echo "ERROR: Could not read environment from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi
if [[ -z "$_region" ]]; then
  echo "ERROR: Could not read region from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

# ── Apply ClusterSecretStore ─────────────────────────────────────────────────
echo "Configuring External Secrets Operator..."

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: langsmith-ssm
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${_region}
EOF

# ── Apply ExternalSecret ─────────────────────────────────────────────────────
# Dynamically includes optional encryption keys only if the SSM parameter exists.
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: langsmith-config
  namespace: $NAMESPACE
spec:
  refreshInterval: "1h"
  secretStoreRef:
    name: langsmith-ssm
    kind: ClusterSecretStore
  target:
    name: langsmith-config
    creationPolicy: Owner
  data:
    - secretKey: langsmith_license_key
      remoteRef:
        key: ${_ssm_prefix}/langsmith-license-key
    - secretKey: api_key_salt
      remoteRef:
        key: ${_ssm_prefix}/langsmith-api-key-salt
    - secretKey: jwt_secret
      remoteRef:
        key: ${_ssm_prefix}/langsmith-jwt-secret
    - secretKey: initial_org_admin_password
      remoteRef:
        key: ${_ssm_prefix}/langsmith-admin-password
$(if _ssm_key_exists "${_ssm_prefix}/agent-builder-encryption-key"; then cat <<ABEOF
    - secretKey: agent_builder_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/agent-builder-encryption-key
ABEOF
fi)
$(if _ssm_key_exists "${_ssm_prefix}/insights-encryption-key"; then cat <<IEOF
    - secretKey: insights_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/insights-encryption-key
IEOF
fi)
$(if _ssm_key_exists "${_ssm_prefix}/deployments-encryption-key"; then cat <<DEOF
    - secretKey: deployments_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/deployments-encryption-key
DEOF
fi)
$(if _ssm_key_exists "${_ssm_prefix}/polly-encryption-key"; then cat <<PEOF
    - secretKey: polly_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/polly-encryption-key
PEOF
fi)
$(if _ssm_key_exists "${_ssm_prefix}/oauth-client-secret"; then cat <<OEOF
    - secretKey: oauth_client_secret
      remoteRef:
        key: ${_ssm_prefix}/oauth-client-secret
    - secretKey: oauth_client_id
      remoteRef:
        key: ${_ssm_prefix}/oauth-client-id
    - secretKey: oauth_issuer_url
      remoteRef:
        key: ${_ssm_prefix}/oauth-issuer-url
OEOF
fi)
EOF

# ── Wait for sync ────────────────────────────────────────────────────────────
echo "Waiting for ESO to sync langsmith-config secret..."
if ! kubectl wait externalsecret langsmith-config -n "$NAMESPACE" \
    --for=condition=Ready=True --timeout=60s 2>/dev/null; then
  echo "" >&2
  echo "ERROR: ESO failed to sync langsmith-config from SSM within 60s." >&2
  echo "       Diagnose with:" >&2
  echo "         kubectl describe externalsecret langsmith-config -n $NAMESPACE" >&2
  echo "       Common causes:" >&2
  echo "         - SSM parameters not created: source aws/infra/scripts/setup-env.sh" >&2
  echo "         - ESO IRSA role missing SSM permissions" >&2
  echo "         - Wrong SSM prefix — check _name_prefix and _environment in setup-env.sh" >&2
  exit 1
fi
echo "  langsmith-config secret ready."
