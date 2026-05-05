#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Deploys or upgrades LangSmith via Helm on AWS.
#
# Values files loaded (in order, last wins):
#   1. langsmith-values.yaml              — base AWS config (always)
#   2. langsmith-values-overrides.yaml    — env-specific: hostname, IRSA, S3 (required)
#   3. langsmith-values-agent-deploys.yaml  — Deployments feature (if enabled)
#   4. langsmith-values-agent-builder.yaml  — Agent Builder feature (if enabled)
#   5. langsmith-values-insights.yaml       — ClickHouse/Insights (if enabled)
#   6. langsmith-values-polly.yaml          — Polly AI eval/monitoring (if enabled)
#   7. langsmith-values-sizing-{profile}.yaml — sizing (loaded last so it wins over addons)
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
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""

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

# ── Apply ESO ClusterSecretStore + ExternalSecret (or direct secret for workers) ──
# SKIP_ESO=true bypasses SSM/ESO and creates langsmith-config directly from env vars.
# Used by test workers that have TF_VAR_* / LANGSMITH_* secrets in the environment
# but have no SSM parameters (SSM is never provisioned for short-lived test clusters).
if [[ "${SKIP_ESO:-false}" == "true" ]]; then
  echo "Configuring secrets (SKIP_ESO=true — creating langsmith-config directly from env)..."

  _require_env() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: SKIP_ESO=true but required env var $var is not set." >&2
      echo "       Source setup-env.sh or export the secret vars before running deploy.sh." >&2
      exit 1
    fi
  }
  _require_env "TF_VAR_langsmith_api_key_salt"
  _require_env "TF_VAR_langsmith_jwt_secret"
  _require_env "LANGSMITH_LICENSE_KEY"
  _require_env "LANGSMITH_ADMIN_PASSWORD"
  _require_env "LANGSMITH_ADMIN_EMAIL"

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic langsmith-config \
    --namespace "$NAMESPACE" \
    --from-literal=langsmith_license_key="${LANGSMITH_LICENSE_KEY}" \
    --from-literal=api_key_salt="${TF_VAR_langsmith_api_key_salt}" \
    --from-literal=jwt_secret="${TF_VAR_langsmith_jwt_secret}" \
    --from-literal=initial_org_admin_password="${LANGSMITH_ADMIN_PASSWORD}" \
    --from-literal=initial_org_admin_email="${LANGSMITH_ADMIN_EMAIL}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  langsmith-config secret ready (direct)."
else
  # These CRD resources can't be managed by Terraform (CRDs must exist at plan time).
  # Applied here after ESO is installed by terraform apply.
  # Run standalone to re-sync ESO without a full redeploy: ./helm/scripts/apply-eso.sh
  NAMESPACE="$NAMESPACE" INFRA_DIR="$INFRA_DIR" "$SCRIPT_DIR/apply-eso.sh"
fi
echo ""

# ── Read feature flags from terraform.tfvars ─────────────────────────────────
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_enable_envoy_gateway=false
_enable_istio_gateway=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true
_tfvar_is_true "enable_insights"      && _enable_insights=true
_tfvar_is_true "enable_polly"         && _enable_polly=true
_tfvar_is_true "enable_envoy_gateway" && _enable_envoy_gateway=true
_tfvar_is_true "enable_istio_gateway" && _enable_istio_gateway=true

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_polly" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────────
VALUES_ARGS=(-f "$VALUES_DIR/langsmith-values.yaml" -f "$ENV_FILE")

# Sizing profile: read from terraform.tfvars (production, dev, minimum, or default).
_sizing_profile=$(_parse_tfvar "sizing_profile") || _sizing_profile="default"

# Print values chain so the user knows exactly what's going into the release.
echo ""
echo "Values chain:"
echo "  ✔ langsmith-values.yaml (base)"
echo "  ✔ langsmith-values-overrides.yaml (auto-generated)"

# Addon files: gated by enable_* flags in terraform.tfvars.
# The file must exist AND the corresponding flag must be true.
# addon:flag_name pairs — flag_name matches the terraform.tfvars variable
_addon_gate=(
  "agent-deploys:deployments:$_enable_deployments"
  "agent-builder:agent_builder:$_enable_agent_builder"
  "insights:insights:$_enable_insights"
  "polly:polly:$_enable_polly"
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

# Sizing: loaded last so it wins over addon defaults (e.g. polly maxScale).
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_file" ]]; then
    VALUES_ARGS+=(-f "$_sizing_file")
    echo "  ✔ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile})"
    if [[ "$_sizing_profile" == "minimum" ]]; then
      echo ""
      echo "  ⚠️  WARNING: sizing_profile = ${_sizing_profile} — NOT for production use."
      echo "     Resources are reduced for dev/test/POC only. Expect degraded"
      echo "     performance under real workloads. Use sizing_profile = production for production."
      echo ""
    fi
  else
    echo "  ✗ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile} but file not found — run: make init-values)"
  fi
else
  echo "  ○ sizing: chart defaults (sizing_profile = default)"
fi

# ── Pre-deploy hostname check ────────────────────────────────────────────────
# On upgrades verify config.hostname matches the ALB DNS name.
# In all modes (ALB, Envoy Gateway, Istio) the ALB is the external entry point.
# A stale hostname causes the operator to set unreachable agent endpoints, which
# keeps the bootstrap hook stuck at DEPLOYING and times out the release.
_live_lb=""
_live_lb=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null) || true
if [[ -n "$_live_lb" && -z "$_langsmith_domain" ]]; then
  _configured_hostname=$(grep -E '^\s*hostname:' "$ENV_FILE" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _configured_hostname=""
  if [[ -n "$_configured_hostname" && "$_configured_hostname" != "$_live_lb" ]]; then
    echo "WARNING: config.hostname is stale."
    echo "  Configured: $_configured_hostname"
    echo "  Actual:     $_live_lb"
    echo "  Updating $(basename "$ENV_FILE") before deploy..."

    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${_live_lb}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    sed -i.bak "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${_live_lb}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    echo "  Done."
    echo ""
  fi
fi

echo ""
echo "Deploying LangSmith (environment: $_environment, sizing: $_sizing_profile)..."
echo "  (waiting for pods — 5-10 min on a cold cluster while nodes provision)"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain

# Guard: recover from broken release states before proceeding.
#   - pending-upgrade: left by a Ctrl+C'd helm upgrade --wait. Roll back to clear.
#   - failed: left by a timed-out post-install hook or resource readiness check.
#             helm upgrade works fine on a failed release — just log and continue.
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  echo "         Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "failed" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'failed' state."
  echo "         This is usually caused by a post-install hook timeout — not a broken deployment."
  echo "         Proceeding with upgrade (helm upgrade works on failed releases)."
  echo ""
fi

# Ensure langsmith-ksa service account exists before Helm runs the bootstrap hook.
# The hook deploys operator-managed agent pods that reference this SA. It must exist
# before the post-install/post-upgrade hook fires — not after Helm returns.
# Source the IRSA ARN from the overrides file (written by init-values.sh) so this
# works on fresh clusters where langsmith-platform-backend doesn't exist yet.
_irsa_arn_pre=$(grep -m1 'eks.amazonaws.com/role-arn' "${ENV_FILE}" 2>/dev/null \
  | sed 's/.*role-arn:[[:space:]]*"\?\([^"]*\)"\?.*/\1/' | tr -d '[:space:]') || _irsa_arn_pre=""
if [[ -n "$_irsa_arn_pre" ]]; then
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    eks.amazonaws.com/role-arn="$_irsa_arn_pre" --overwrite
fi

# Pre-delete any completed/failed bootstrap job from a previous deploy.
# The bootstrap job is a post-upgrade hook — if a previous run left it in a
# completed or failed state Helm treats it as blocking and times out the release.
# Deleting it here lets Helm create a fresh job on every upgrade without error.
kubectl delete job "${RELEASE_NAME}-agent-bootstrap" -n "$NAMESPACE" \
  --ignore-not-found=true 2>/dev/null || true

# Deploy with --server-side=false to avoid SSA field ownership conflicts with the
# ALB ingress controller. Helm 3.14+ defaults to server-side apply, which fights
# with the controller over .spec.rules ownership. Client-side apply sidesteps this.
#
# We intentionally do NOT use --wait here. The chart's post-install bootstrap job
# deploys operator-managed agents (clio, polly, agent-builder) which can take 10+
# minutes on a cold cluster with autoscaling. Using --wait causes the release to go
# 'failed' if the job exceeds the timeout — even though all workloads are healthy.
# Instead, we do our own readiness check below.
helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  "${VALUES_ARGS[@]}" \
  --server-side=false \
  --timeout 20m

echo ""
echo "LangSmith deployed. Waiting for core pods..."
echo ""

# ── Wait for core components to be ready ────────────────────────────────────
# Instead of --wait (which blocks on hooks), check that the core deployments
# are available. This decouples app readiness from the bootstrap job.
_core_deployments=(
  "${RELEASE_NAME}-frontend"
  "${RELEASE_NAME}-backend"
  "${RELEASE_NAME}-platform-backend"
  "${RELEASE_NAME}-ingest-queue"
  "${RELEASE_NAME}-queue"
)
# Add deployments-feature components if enabled
if [[ "$_enable_deployments" == "true" ]]; then
  _core_deployments+=(
    "${RELEASE_NAME}-host-backend"
    "${RELEASE_NAME}-listener"
    "${RELEASE_NAME}-operator"
  )
fi

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    echo "  ⏳ $dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_all_ready" == "true" ]]; then
  echo "All core deployments ready."
else
  echo ""
  echo "WARNING: Some deployments are still rolling out. This is normal on a cold cluster"
  echo "         while nodes are provisioning. Check with: kubectl get pods -n $NAMESPACE"
fi
echo ""

# Restart frontend to ensure it picks up the latest configmap.
kubectl rollout restart deployment/"$RELEASE_NAME"-frontend -n "$NAMESPACE"
kubectl rollout status deployment/"$RELEASE_NAME"-frontend -n "$NAMESPACE" --timeout=2m

# ── Detect active hostname (ALB — always the external entry point) ─────────────
# In all modes (ALB, Envoy Gateway, Istio) the ALB is the external entry point.
# Read the ALB DNS name from Terraform output, which is always available once
# terraform apply completes (ALB is provisioned before Helm deploy).
# Patch config.hostname + deployment.url in the overrides file if stale, then
# re-run helm upgrade so HTTPRoute hostname filters and deployment URLs are correct.
_active_host=""
_active_host=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null) || true
[[ -n "$_active_host" ]] && echo "ALB hostname: $_active_host"

if [[ -n "$_active_host" ]]; then
  echo ""
  _current_hostname=$(grep -E '^\s*hostname:' "$ENV_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_hostname=""
  if [[ "$_current_hostname" != "$_active_host" && -z "$_langsmith_domain" ]]; then
    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${_active_host}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    sed -i.bak "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${_active_host}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    echo "Updated config.hostname in $(basename "$ENV_FILE"): ${_current_hostname:-<blank>} → $_active_host"
    echo "Re-running deploy for hostname to take effect..."
    echo ""
    helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
      --namespace "$NAMESPACE" \
      ${CHART_VERSION:+--version "$CHART_VERSION"} \
      "${VALUES_ARGS[@]}" \
      --server-side=false \
      --timeout 20m
    echo ""
    echo "LangSmith redeployed with hostname: $_active_host"
  fi
else
  echo "(Load balancer not yet ready — re-run deploy after a few minutes to get the hostname)"
fi

echo ""
echo "Access LangSmith:"
echo "  Port-forward:  kubectl port-forward svc/${RELEASE_NAME}-frontend -n ${NAMESPACE} 8080:80"
echo "  Then open:     http://localhost:8080"
if [[ -n "${_active_host:-}" ]]; then
  echo "  URL:           http://${_active_host}"
fi
