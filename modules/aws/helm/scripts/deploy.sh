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
#   4. langsmith-values-agent-builder.yaml  — Agent Builder legacy (if enable_agent_builder)
#   5. langsmith-values-insights.yaml       — ClickHouse/Insights legacy (if enable_insights)
#   6. langsmith-values-polly.yaml          — Polly legacy (if enable_polly)
#   7. langsmith-values-fleet.yaml          — Fleet standalone v0.15+ (if enable_fleet)
#   8. langsmith-values-standalone-polly.yaml    — Polly standalone v0.15+ (if enable_standalone_polly)
#   9. langsmith-values-standalone-insights.yaml — Insights standalone v0.15+ (if enable_standalone_insights)
#  10. langsmith-values-sizing-{profile}.yaml — sizing (loaded last so it wins over addons)
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
# Pin the chart *line*: deploy the latest 0.16.x, never auto-jump to 0.17.
# Override with the CHART_VERSION env var for an exact patch if needed.
# An exported CHART_VERSION outlives the command that set it, so a value left over
# from an earlier session silently wins over the pin. Say so rather than deploying
# a different chart than the branch intends.
if [[ -n "${CHART_VERSION:-}" ]]; then
  echo "NOTE: CHART_VERSION='${CHART_VERSION}' comes from your environment and overrides the ~0.16.0 pin."
  echo "      Run 'unset CHART_VERSION' to deploy the pinned chart line."
fi
CHART_VERSION="${CHART_VERSION:-~0.16.0}"

_chart_version_supports_sandboxes() {
  local version
  version="$(printf '%s' "$1" | tr -d '[:space:]')"
  version="${version#\~>}"
  version="${version#\~}"
  version="${version#v}"

  case "$version" in
    0.1[6-9].*|0.[2-9][0-9].*|[1-9].*|[1-9][0-9]*.*) return 0 ;;
    *) return 1 ;;
  esac
}

_validate_sandbox_values_file() {
  local values_file="$1"

  if ! grep -Eq '^sandboxes:[[:space:]]*$' "$values_file" \
    || ! grep -Eq '^[[:space:]]{2}enabled:[[:space:]]*true[[:space:]]*$' "$values_file" \
    || ! grep -Eq '^[[:space:]]{6}existingSecretName:[[:space:]]*"?[^"]+"?[[:space:]]*$' "$values_file"; then
    echo "ERROR: enable_sandboxes = true, but $(basename "$values_file") does not contain generated sandbox values." >&2
    echo "       Run: make init-values  (or: ./helm/scripts/init-values.sh) after applying infra." >&2
    exit 1
  fi
}

# These values use the chart 0.16 schema: engineInsightsAgent, the top-level
# insights/polly blocks, and no backend.agentBootstrap. Chart 0.15 ignores those
# keys instead of rejecting them, so it renders cleanly while silently dropping
# the external Insights Postgres/Redis wiring and falling back to in-cluster
# StatefulSets. Chart 0.17 has not been validated against them. Refuse both
# rather than deploy a half-configured release.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "0.16" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart 0.16 line." >&2
  echo "       These values require chart 0.16 (engineInsightsAgent, top-level insights/polly)." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a 0.16 patch explicitly:" >&2
  echo "         CHART_VERSION=0.16.0 make deploy" >&2
  exit 1
fi
# engineInsightsAgent only exists from 0.16.0-rc.24 onwards. Earlier prereleases
# are on the 0.16 line but still drop the block silently.
if [[ "$CHART_VERSION" == *-* ]]; then
  _rc="${CHART_VERSION##*-rc.}"
  if [[ "$CHART_VERSION" != *-rc.* || ! "$_rc" =~ ^[0-9]+$ || "$_rc" -lt 24 ]]; then
    echo "ERROR: CHART_VERSION '$CHART_VERSION' predates the engineInsightsAgent block (chart 0.16.0-rc.24)." >&2
    echo "       Chart 0.16.0 is GA — use a released 0.16.x." >&2
    exit 1
  fi
fi

# Preflight: reject values files still carrying the chart 0.15 schema. init-values.sh
# only creates an addon file when it is missing, so a values directory generated on the
# 0.15 line keeps its stale copies and they get loaded here. The chart does reject them,
# but its error names the key, not the generated file that carries it.
_legacy_files=""
for _vf in "$VALUES_DIR"/*.yaml; do
  [[ -f "$_vf" ]] || continue
  if awk '
      /^[A-Za-z_]/ { top = $1; sub(":", "", top) }
      top == "config"  && /^  (insights|polly):/ { found = 1 }
      top == "backend" && /^  agentBootstrap:/   { found = 1 }
      END { exit !found }
    ' "$_vf"; then
    _legacy_files+="         $(basename "$_vf")
"
  fi
done
if [[ -n "$_legacy_files" ]]; then
  echo "ERROR: these values files use the chart 0.15 schema, which chart 0.16 rejects:" >&2
  printf '%s' "$_legacy_files" >&2
  echo "       config.insights, config.polly and backend.agentBootstrap were removed." >&2
  echo "       init-values.sh only creates an addon file when it is missing, so delete the" >&2
  echo "       files listed above and re-run 'make init-values' to regenerate them." >&2
  exit 1
fi

# ── Resolve environment from terraform.tfvars ─────────────────────────────────
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-}"
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_enable_sandboxes=false
_tfvar_is_true "enable_sandboxes" && _enable_sandboxes=true

if [[ "$_enable_sandboxes" == "true" ]]; then
  if ! _chart_version_supports_sandboxes "$CHART_VERSION"; then
    echo "ERROR: enable_sandboxes = true requires chart 0.16.0 or newer; got CHART_VERSION=$CHART_VERSION." >&2
    exit 1
  fi
fi

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

if [[ "$_enable_sandboxes" == "true" ]]; then
  _validate_sandbox_values_file "$ENV_FILE"
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
  if [[ "$_enable_sandboxes" == "true" ]]; then
    _require_env "TF_VAR_sandbox_callback_signing_jwk"
  fi

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  _sandbox_secret_literals=()
  if [[ "$_enable_sandboxes" == "true" ]]; then
    _sandbox_secret_literals=(
      --from-literal=sandbox_callback_signing_jwk="${TF_VAR_sandbox_callback_signing_jwk}"
    )
  fi

  kubectl create secret generic langsmith-config \
    --namespace "$NAMESPACE" \
    --from-literal=langsmith_license_key="${LANGSMITH_LICENSE_KEY}" \
    --from-literal=api_key_salt="${TF_VAR_langsmith_api_key_salt}" \
    --from-literal=jwt_secret="${TF_VAR_langsmith_jwt_secret}" \
    --from-literal=initial_org_admin_password="${LANGSMITH_ADMIN_PASSWORD}" \
    --from-literal=initial_org_admin_email="${LANGSMITH_ADMIN_EMAIL}" \
    "${_sandbox_secret_literals[@]}" \
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
_enable_fleet=false
_enable_standalone_polly=false
_enable_standalone_insights=false
_enable_sandboxes=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true
_tfvar_is_true "enable_insights"      && _enable_insights=true
_tfvar_is_true "enable_polly"         && _enable_polly=true
_tfvar_is_true "enable_fleet"               && _enable_fleet=true
_tfvar_is_true "enable_standalone_polly"    && _enable_standalone_polly=true
_tfvar_is_true "enable_standalone_insights" && _enable_standalone_insights=true
_tfvar_is_true "enable_sandboxes"     && _enable_sandboxes=true

# Fleet is the standalone successor to Agent Builder. Chart 0.16 removed the bundled
# agent-bootstrap Job, so config.agentBuilder on its own now renders the tool/trigger
# servers and the UI nav item but no agent runtime behind them. The two paths also
# manage the same data with different schemas, so they must not run together.
if [[ "$_enable_fleet" == "true" && "$_enable_agent_builder" == "true" ]]; then
  echo "ERROR: enable_fleet and enable_agent_builder are mutually exclusive — Fleet replaces the legacy Agent Builder path." >&2
  echo "       Set enable_agent_builder = false in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_agent_builder" == "true" && "$_enable_fleet" != "true" ]]; then
  echo "WARNING: enable_agent_builder without enable_fleet deploys the Agent Builder UI and its" >&2
  echo "         tool/trigger servers, but chart 0.16 removed the bundled agent-bootstrap Job that" >&2
  echo "         used to register the agent itself. Set enable_fleet = true for a working runtime." >&2
fi

# Gateway flags come from the Terraform outputs, not the tfvars text: enable_envoy_gateway
# is derived (unset = on unless Istio/NGINX was chosen), and getting this wrong sends the
# hostname resolution below to the Ingress status instead of the Terraform ALB.
_enable_envoy_gateway=$(_read_gateway_flag "enable_envoy_gateway")
_enable_istio_gateway=$(_read_gateway_flag "enable_istio_gateway")
_enable_nginx_ingress=$(_read_gateway_flag "enable_nginx_ingress")

# Classic ALB Ingress mode = none of the gateway/nginx routing modes are enabled.
# In that mode the AWS Load Balancer Controller creates and owns the ALB, so the
# external hostname must be read from the Ingress status — not the Terraform ALB
# (alb_dns_name), which is a separate, unused ALB in this mode.
_alb_ingress_mode=false
if [[ "$_enable_envoy_gateway" != "true" && "$_enable_istio_gateway" != "true" && "$_enable_nginx_ingress" != "true" ]]; then
  _alb_ingress_mode=true
fi

# Resolve the external entry hostname for the hostname-sync logic below.
#   $1 = max attempts (1 = single best-effort read, no waiting between attempts).
# In ALB Ingress mode the controller-owned ALB's DNS is published on the Ingress
# status; it appears a couple minutes after the first helm upgrade, so callers
# that run post-deploy pass a retry count. In NGINX/Envoy/Istio modes the
# Terraform-provisioned ALB is the entry point and is read from its output.
_resolve_entry_hostname() {
  local _retries="${1:-1}" _h="" _i
  if [[ "$_alb_ingress_mode" == "true" ]]; then
    for (( _i = 1; _i <= _retries; _i++ )); do
      _h=$(kubectl get ingress "${RELEASE_NAME}-ingress" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) || _h=""
      [[ -n "$_h" ]] && break
      (( _i < _retries )) && sleep "${INGRESS_HOSTNAME_RETRY_INTERVAL:-15}"
    done
    printf '%s' "$_h"
  else
    terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null || true
  fi
}

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_polly" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
# Standalone Fleet's chat UI resolves OAuth provider/token connections via host-backend,
# which only exists when Deployments is enabled. (Standalone Polly/Insights do not need it.)
if [[ "$_enable_fleet" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_fleet requires enable_deployments = true in terraform.tfvars." >&2
  echo "       The Fleet chat UI needs host-backend (Deployments) for OAuth provider/token endpoints." >&2
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
  "fleet:fleet:$_enable_fleet"
  "standalone-polly:standalone_polly:$_enable_standalone_polly"
  "standalone-insights:standalone_insights:$_enable_standalone_insights"
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
# On upgrades verify config.hostname matches the external entry hostname.
# The entry point is the ALB in all modes, but in classic ALB Ingress mode that
# ALB is controller-owned and its DNS is read from the Ingress status (single
# best-effort attempt here — on a first deploy the Ingress doesn't exist yet and
# there is nothing to sync). A stale hostname causes the operator to set
# unreachable agent endpoints, which keeps agent deployments stuck at DEPLOYING.
_live_lb=""
_live_lb=$(_resolve_entry_hostname 1) || true
if [[ -n "$_live_lb" && -z "$_langsmith_domain" ]]; then
  _configured_hostname=$(grep -E '^\s*hostname:' "$ENV_FILE" 2>/dev/null \
    | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _configured_hostname=""
  # Compare host-only: config.hostname carries a scheme (http(s)://) so the chart
  # emits correct browser URLs, but _live_lb is the bare ALB DNS.
  _configured_host_only="${_configured_hostname#*://}"
  if [[ -n "$_configured_host_only" && "$_configured_host_only" != "$_live_lb" ]]; then
    echo "WARNING: config.hostname is stale."
    echo "  Configured: $_configured_hostname"
    echo "  Actual:     $_live_lb"
    echo "  Updating $(basename "$ENV_FILE") before deploy..."

    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    # Keep the scheme on config.hostname (chart defaults bare host to https).
    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${_protocol}://${_live_lb}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
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
#   - pending-install: left by a disrupted initial install (e.g. transient EKS API
#                      errors during make apply). No revision exists to roll back
#                      to, so uninstall and let the deploy recreate it.
#   - failed: left by a timed-out post-install hook or resource readiness check.
#             helm upgrade works fine on a failed release — just log and continue.
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  echo "         Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "pending-install" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'pending-install' state (disrupted initial install)."
  echo "         No revision exists to roll back to. Uninstalling to clear the lock..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "failed" ]]; then
  echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'failed' state."
  echo "         This is usually caused by a post-install hook timeout — not a broken deployment."
  echo "         Proceeding with upgrade (helm upgrade works on failed releases)."
  echo ""
fi

# Ensure langsmith-ksa service account exists before Helm runs its post-install hooks.
# Operator-managed agent pods reference this SA, so it must exist before the
# post-install/post-upgrade hooks fire — not after Helm returns.
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

# Chart 0.16 removed the bundled agent-bootstrap Job. Helm no longer owns it, so an
# upgrade from 0.15 strands the old Completed job in the namespace. Deleting it here
# clears that orphan on the first 0.16 deploy and is a no-op on a fresh install.
kubectl delete job "${RELEASE_NAME}-agent-bootstrap" -n "$NAMESPACE" \
  --ignore-not-found=true 2>/dev/null || true

# --devel is required for pre-release chart versions (e.g. 0.15.0-rc.14). Helm
# silently skips any version tagged -rc./-alpha./-beta. without it.
_devel_flag=""
if [[ -n "$CHART_VERSION" ]] && echo "$CHART_VERSION" | grep -qE '\-(rc|alpha|beta)\.'; then
  _devel_flag="--devel"
fi

# Helm timeout is configurable (migration issue #2). With all features enabled
# (Insights + Deployments + Fleet) the first upgrade regularly exceeds the old
# hardcoded 20m because of sequential stateful rollouts and migration jobs.
_helm_timeout="${HELM_TIMEOUT:-30m}"

# Deploy with --server-side=false to avoid SSA field ownership conflicts with the
# ALB ingress controller. Helm 3.14+ defaults to server-side apply, which fights
# with the controller over .spec.rules ownership. Client-side apply sidesteps this.
#
# We intentionally do NOT use --wait here. The chart's post-install hooks and the
# operator's agent pods can take 10+ minutes to settle on a cold cluster with
# autoscaling. Using --wait causes the release to go 'failed' if a hook exceeds the
# timeout — even though all workloads are healthy.
# Instead, we do our own readiness check below.
# Resolve the pin to a concrete version and print it. Without this the only place
# the installed version shows up is `helm list`, after the release is already out.
_chart_metadata=$(helm show chart langchain/langsmith --version "$CHART_VERSION" ${_devel_flag:-} 2>/dev/null) || _chart_metadata=""
_resolved_chart=$(awk '/^version:/{print $2}' <<<"$_chart_metadata")
echo "Chart: langchain/langsmith  requested=${CHART_VERSION}  resolved=${_resolved_chart:-UNRESOLVED}"
if [[ -z "$_resolved_chart" ]]; then
  echo "ERROR: no chart matches '$CHART_VERSION' in the langchain repo." >&2
  exit 1
fi
if [[ "$_enable_sandboxes" == "true" ]]; then
  _sandbox_host_image_tag=$(awk '/^appVersion:/{print $2}' <<<"$_chart_metadata")
  if [[ -z "$_sandbox_host_image_tag" ]]; then
    echo "ERROR: chart $_resolved_chart does not declare an appVersion for the Sandbox image." >&2
    exit 1
  fi
  VALUES_ARGS+=(--set-string "images.sandboxHostImage.tag=$_sandbox_host_image_tag")
  echo "Sandboxes: sandbox-host image tag=$_sandbox_host_image_tag"
fi

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  ${_devel_flag} \
  "${VALUES_ARGS[@]}" \
  --server-side=false \
  --timeout "$_helm_timeout"

echo ""
echo "LangSmith deployed. Waiting for core pods..."
echo ""

# ── Wait for core components to be ready ────────────────────────────────────
# Instead of --wait (which blocks on hooks), check that the core deployments
# are available. This decouples app readiness from the chart's hooks.
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
# Standalone agent features (chart v0.15+). Deployment names derive from
# <release>-<namePrefix>-<component>; namePrefix is standalone-{fleet,polly,insights}.
[[ "$_enable_fleet" == "true" ]]               && _core_deployments+=("${RELEASE_NAME}-standalone-fleet-api-server")
[[ "$_enable_standalone_polly" == "true" ]]    && _core_deployments+=("${RELEASE_NAME}-standalone-polly-api-server")
[[ "$_enable_standalone_insights" == "true" ]] && _core_deployments+=("${RELEASE_NAME}-standalone-insights-api-server")

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    echo "  ⏳ $dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_enable_sandboxes" == "true" ]]; then
  if ! kubectl rollout status deployment/sandbox-host -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    echo "  ⏳ sandbox-host not ready within 5m (sandbox-host nodes may still be starting)"
    _all_ready=false
  fi
fi

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
# The ALB is the external entry point in all modes. In classic ALB Ingress mode
# the controller owns the ALB and publishes its DNS on the Ingress status, which
# appears a couple minutes after the first helm upgrade — so we retry. In
# NGINX/Envoy/Istio modes the Terraform-provisioned ALB output is used.
# Patch config.hostname + deployment.url in the overrides file if stale, then
# re-run helm upgrade so HTTPRoute hostname filters and deployment URLs are correct.
_active_host=""
_active_host=$(_resolve_entry_hostname 10) || true
[[ -n "$_active_host" ]] && echo "ALB hostname: $_active_host"

if [[ -n "$_active_host" ]]; then
  echo ""
  _current_hostname=$(grep -E '^\s*hostname:' "$ENV_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_hostname=""
  # Compare host-only: config.hostname carries a scheme; _active_host is bare DNS.
  _current_host_only="${_current_hostname#*://}"
  if [[ "$_current_host_only" != "$_active_host" && -z "$_langsmith_domain" ]]; then
    _current_url=$(grep -E '^\s*url:' "$ENV_FILE" 2>/dev/null \
      | head -1 | sed 's/.*:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    # Keep the scheme on config.hostname (chart defaults bare host to https).
    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${_protocol}://${_active_host}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    sed -i.bak "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${_active_host}\"|" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    echo "Updated config.hostname in $(basename "$ENV_FILE"): ${_current_hostname:-<blank>} → ${_protocol}://${_active_host}"
    echo "Re-running deploy for hostname to take effect..."
    echo ""
    helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
      --namespace "$NAMESPACE" \
      ${CHART_VERSION:+--version "$CHART_VERSION"} \
      ${_devel_flag} \
      "${VALUES_ARGS[@]}" \
      --server-side=false \
      --timeout "$_helm_timeout"
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
