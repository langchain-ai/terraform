#!/usr/bin/env bash
# Deploys or upgrades LangSmith via Helm on AWS.
#
# Values files loaded (in order, last wins):
#   1. langsmith-values.yaml              — base AWS config (always)
#   2. langsmith-values-overrides.yaml    — env-specific: hostname, IRSA, S3 (required)
#   3. langsmith-values-sizing-ha.yaml    — HA sizing (if present)
#      OR langsmith-values-sizing-light.yaml — light sizing for POC/test (if present)
#   4. langsmith-values-agent-deploys.yaml  — Deployments feature (if present)
#   5. langsmith-values-agent-builder.yaml  — Agent Builder feature (if present)
#   6. langsmith-values-insights.yaml       — ClickHouse/Insights (if present)
#
# Generate all values files: make init-values (or ./scripts/init-values.sh)
# Templates live in values/examples/ — init-values.sh copies them based on your choices.
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"
source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"

# ── Resolve environment from terraform.tfvars ─────────────────────────────────
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-}"
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"

if [[ -z "$_environment" || -z "$_region" ]]; then
  echo "ERROR: Could not resolve environment and/or region from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has 'environment' and 'region' set." >&2
  exit 1
fi

ENV_FILE="$VALUES_DIR/langsmith-values-overrides.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "Run: make init-values  (or: ./helm/scripts/init-values.sh)" >&2
  exit 1
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────────
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || {
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
# Run standalone to re-sync ESO without a full redeploy: ./helm/scripts/apply-eso.sh
NAMESPACE="$NAMESPACE" INFRA_DIR="$INFRA_DIR" "$SCRIPT_DIR/apply-eso.sh"
echo ""

# ── Read product feature flags from terraform.tfvars ─────────────────────────
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true
_tfvar_is_true "enable_insights"      && _enable_insights=true

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────────
VALUES_ARGS=(-f "$VALUES_DIR/langsmith-values.yaml" -f "$ENV_FILE")

# Sizing: ha and light are mutually exclusive — if both exist, error.
_ha_file="$VALUES_DIR/langsmith-values-sizing-ha.yaml"
_light_file="$VALUES_DIR/langsmith-values-sizing-light.yaml"
if [[ -f "$_ha_file" && -f "$_light_file" ]]; then
  echo "ERROR: Both langsmith-values-sizing-ha.yaml and langsmith-values-sizing-light.yaml exist." >&2
  echo "       These are mutually exclusive — remove one before deploying." >&2
  exit 1
fi

# Print values chain so the user knows exactly what's going into the release.
echo ""
echo "Values chain:"
echo "  ✔ langsmith-values.yaml (base)"
echo "  ✔ langsmith-values-overrides.yaml (auto-generated)"

# Sizing files: included if present on disk (not gated by tfvars flags).
for sizing in sizing-ha sizing-light; do
  f="$VALUES_DIR/langsmith-values-${sizing}.yaml"
  if [[ -f "$f" ]]; then
    VALUES_ARGS+=(-f "$f")
    echo "  ✔ langsmith-values-${sizing}.yaml"
  else
    echo "  ✗ langsmith-values-${sizing}.yaml (not found — skipped)"
  fi
done

# Addon files: gated by enable_* flags in terraform.tfvars.
# The file must exist AND the corresponding flag must be true.
# addon:flag_name pairs — flag_name matches the terraform.tfvars variable
_addon_gate=(
  "agent-deploys:deployments:$_enable_deployments"
  "agent-builder:agent_builder:$_enable_agent_builder"
  "insights:insights:$_enable_insights"
)
for entry in "${_addon_gate[@]}"; do
  addon="${entry%%:*}"
  rest="${entry#*:}"
  flag_name="${rest%%:*}"
  enabled="${rest##*:}"
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ "$enabled" == "true" ]]; then
    if [[ -f "$f" ]]; then
      VALUES_ARGS+=(-f "$f")
      echo "  ✔ langsmith-values-${addon}.yaml"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (enabled but file not found — run: make init-values)"
    fi
  else
    if [[ -f "$f" ]]; then
      echo "  ○ langsmith-values-${addon}.yaml (file exists but enable_${flag_name} = false in tfvars — skipped)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (not enabled — skipped)"
    fi
  fi
done

echo ""
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
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
fi

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  "${VALUES_ARGS[@]}" \
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
    | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_hostname=""
  if [[ "$_current_hostname" != "$ALB_HOST" ]]; then
    # Derive protocol from the existing deployment.url value so we don't need tfvars here.
    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${ALB_HOST}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    sed -i.bak "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${ALB_HOST}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    echo "Updated config.hostname in $(basename "$ENV_FILE"): ${_current_hostname:-<blank>} → $ALB_HOST"
    echo "Re-running deploy for hostname to take effect..."
    echo ""
    helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
      --namespace "$NAMESPACE" \
      ${CHART_VERSION:+--version "$CHART_VERSION"} \
      "${VALUES_ARGS[@]}" \
      --wait \
      --timeout 20m
    echo ""
    echo "LangSmith redeployed with hostname: $ALB_HOST"
  fi
else
  echo "(Ingress not yet ready — re-run after a few minutes to get the ALB hostname)"
fi

echo ""
echo "Access LangSmith:"
echo "  Port-forward:  kubectl port-forward svc/${RELEASE_NAME}-frontend -n ${NAMESPACE} 8080:80"
echo "  Then open:     http://localhost:8080"
if [[ -n "${ALB_HOST:-}" ]]; then
  echo "  ALB:           http://${ALB_HOST}"
fi
