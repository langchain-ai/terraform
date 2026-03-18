#!/usr/bin/env bash
# Deploys or upgrades LangSmith via Helm on AWS.
#
# Values files loaded (in order, last wins):
#   1. langsmith-values.yaml              — base AWS config (always)
#   2. langsmith-values-overrides.yaml          — env-specific: hostname, IRSA, S3 (required)
#   3. langsmith-values-ha.yaml             — HA replica counts, resource limits (if present)
#      OR langsmith-values-dev.yaml         — reduced resources for dev/test/POC (if present)
#   4. langsmith-values-agent-deploys.yaml  — Deployments feature (if present)
#   5. langsmith-values-agent-builder.yaml  — Agent Builder feature (if present)
#   6. langsmith-values-insights.yaml       — ClickHouse/Insights (if present)
#
# Generate the env file with: ./scripts/init-overrides.sh
# Enable sizing/addons by copying: cp values/langsmith-values-<name>.yaml.example values/langsmith-values-<name>.yaml
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
VALUES_DIR="$HELM_DIR/values"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"

# ── Resolve environment and SSM prefix from terraform.tfvars ──────────────────
_environment=$(grep -E '^\s*environment\s*=' "$HELM_DIR/../infra/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _environment="${LANGSMITH_ENV:-production}"
_name_prefix=$(grep -E '^\s*name_prefix\s*=' "$HELM_DIR/../infra/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _name_prefix=""
_region=$(grep -E '^\s*region\s*=' "$HELM_DIR/../infra/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _region="${AWS_REGION:-us-east-2}"
_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

ENV_FILE="$VALUES_DIR/langsmith-values-overrides.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "Run: ./scripts/init-overrides.sh" >&2
  exit 1
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────────
_cluster_name=$(terraform -chdir="$HELM_DIR/../infra" output -raw cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read cluster_name. Is 'terraform apply' complete?" >&2
  exit 1
}
echo "Updating kubeconfig for cluster: $_cluster_name..."
aws eks update-kubeconfig --name "$_cluster_name" --region "$_region"
echo "  Active context: $(kubectl config current-context)"
echo ""

# ── Preflight checks ──────────────────────────────────────────────────────────
"$SCRIPT_DIR/preflight-check.sh"
echo ""

# ── Apply ESO ClusterSecretStore + ExternalSecret ─────────────────────────────
# These CRD resources can't be managed by Terraform (CRDs must exist at plan time).
# Applied here after ESO is installed by terraform apply.
echo "Configuring External Secrets Operator..."

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: langsmith-ssm
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${_region}
EOF

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
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
$(if aws ssm get-parameter --name "${_ssm_prefix}/agent-builder-encryption-key" \
    --query 'Parameter.Name' --output text 2>/dev/null | grep -q .; then cat <<ABEOF
    - secretKey: agent_builder_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/agent-builder-encryption-key
ABEOF
fi)
$(if aws ssm get-parameter --name "${_ssm_prefix}/insights-encryption-key" \
    --query 'Parameter.Name' --output text 2>/dev/null | grep -q .; then cat <<IEOF
    - secretKey: insights_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/insights-encryption-key
IEOF
fi)
$(if aws ssm get-parameter --name "${_ssm_prefix}/deployments-encryption-key" \
    --query 'Parameter.Name' --output text 2>/dev/null | grep -q .; then cat <<DEOF
    - secretKey: deployments_encryption_key
      remoteRef:
        key: ${_ssm_prefix}/deployments-encryption-key
DEOF
fi)
EOF

echo "Waiting for ESO to sync langsmith-config secret..."
if ! kubectl wait externalsecret langsmith-config -n "$NAMESPACE" \
    --for=condition=Ready=True --timeout=60s 2>/dev/null; then
  echo "" >&2
  echo "ERROR: ESO failed to sync langsmith-config from SSM within 60s." >&2
  echo "       Diagnose with:" >&2
  echo "         kubectl describe externalsecret langsmith-config -n $NAMESPACE" >&2
  echo "       Common causes:" >&2
  echo "         - SSM parameters not created: source aws/infra/setup-env.sh" >&2
  echo "         - ESO IRSA role missing SSM permissions" >&2
  echo "         - Wrong SSM prefix — check _name_prefix and _environment in setup-env.sh" >&2
  exit 1
fi
echo "  langsmith-config secret ready."
echo ""

# ── Validate addon dependencies ───────────────────────────────────────────────
if [[ -f "$VALUES_DIR/langsmith-values-agent-builder.yaml" ]] && \
   [[ ! -f "$VALUES_DIR/langsmith-values-agent-deploys.yaml" ]]; then
  echo "ERROR: langsmith-values-agent-builder.yaml requires langsmith-values-agent-deploys.yaml." >&2
  echo "Agent Builder depends on config.deployment.enabled, which is set in the agent-deploys file." >&2
  echo "Run: cp $VALUES_DIR/langsmith-values-agent-deploys.yaml.example $VALUES_DIR/langsmith-values-agent-deploys.yaml" >&2
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────────
VALUES_ARGS=(-f "$VALUES_DIR/langsmith-values.yaml" -f "$ENV_FILE")

for addon in ha dev agent-deploys agent-builder insights; do
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ -f "$f" ]]; then
    VALUES_ARGS+=(-f "$f")
    echo "Loading addon: langsmith-values-${addon}.yaml"
  fi
done

echo "Deploying LangSmith (environment: $_environment)..."
echo "  (waiting for pods — 5-10 min on a cold cluster while nodes provision)"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain

# Guard: a pending-upgrade release (left by a Ctrl+C'd helm upgrade --wait) blocks
# helm upgrade --install. Roll back to clear the lock before proceeding.
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  echo "         Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --server-side true --force-conflicts
  echo ""
fi

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  "${VALUES_ARGS[@]}" \
  --server-side true \
  --force-conflicts \
  --wait \
  --timeout 20m

echo ""
echo "LangSmith deployed."
echo ""

# Ensure langsmith-ksa service account exists and carries the IRSA annotation.
# This SA is used by operator-spawned agent deployment pods. It is created by
# the operator on first use and is NOT part of the Helm release, so it does not
# survive namespace teardowns or fresh cluster rebuilds. Without it, new agent
# pod revisions cannot be scheduled and the agent-bootstrap job hangs indefinitely.
_irsa_arn=$(kubectl get serviceaccount langsmith-platform-backend -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
if [[ -n "$_irsa_arn" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    eks.amazonaws.com/role-arn="$_irsa_arn" --overwrite
fi

# Restart frontend to ensure it picks up the latest configmap.
kubectl rollout restart deployment/"$RELEASE_NAME"-frontend -n "$NAMESPACE"
kubectl rollout status deployment/"$RELEASE_NAME"-frontend -n "$NAMESPACE" --timeout=2m

# Print ALB hostname. On first deploy, set config.hostname in the env values file
# to this value and re-run deploy.sh.
ALB_HOST=$(kubectl get ingress -n "$NAMESPACE" langsmith-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

if [[ -n "$ALB_HOST" ]]; then
  echo "ALB hostname: $ALB_HOST"
  echo ""
  # Auto-update hostname in env values file if blank or stale (e.g. pre-provisioned ALB
  # DNS differs from the ingress-controller-managed ALB the chart actually receives).
  _current_hostname=$(grep -E '^\s*hostname:' "$ENV_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _current_hostname=""
  if [[ "$_current_hostname" != "$ALB_HOST" ]]; then
    # Derive protocol from the existing deployment.url value so we don't need tfvars here.
    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    sed -i '' "s|hostname: \"[^\"]*\"|hostname: \"${ALB_HOST}\"|" "$ENV_FILE"
    sed -i '' "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${ALB_HOST}\"|" "$ENV_FILE"
    echo "Updated config.hostname in $(basename "$ENV_FILE"): ${_current_hostname:-<blank>} → $ALB_HOST"
    echo "Re-running deploy for hostname to take effect..."
    echo ""
    helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
      --namespace "$NAMESPACE" \
      ${CHART_VERSION:+--version "$CHART_VERSION"} \
      "${VALUES_ARGS[@]}" \
      --server-side true \
      --force-conflicts \
      --wait \
      --timeout 20m
    echo ""
    echo "LangSmith redeployed with hostname: $ALB_HOST"
  fi
else
  echo "(Ingress not yet ready — re-run after a few minutes to get the ALB hostname)"
fi
