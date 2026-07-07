#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Deploys or upgrades LangSmith via Helm on GCP.
#
# Values files loaded (in order, last wins):
#   1. values.yaml                                      — base GCP config (always)
#   2. values-overrides.yaml                            — env-specific: hostname, WI annotations, GCS (required)
#   3. langsmith-values-sizing-{profile}.yaml           — sizing profile (from sizing_profile in terraform.tfvars)
#   4. langsmith-values-agent-deploys.yaml              — Deployments feature (if enabled)
#   5. langsmith-values-agent-builder.yaml              — Agent Builder legacy (if enabled)
#   6. langsmith-values-insights.yaml                   — ClickHouse/Insights legacy (if enabled)
#   7. langsmith-values-polly.yaml                      — Polly legacy (if enabled)
#   8. langsmith-values-fleet.yaml                      — Fleet standalone v0.15+ (if enable_fleet)
#   9. langsmith-values-standalone-polly.yaml           — Polly standalone v0.15+ (if enable_standalone_polly)
#  10. langsmith-values-standalone-insights.yaml        — Insights standalone v0.15+ (if enable_standalone_insights)
#
# Generate values files: ./helm/scripts/init-values.sh
# Templates live in values/examples/ — init-values.sh copies them based on your choices.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
# Pin the chart *line* by default. Sandboxes require chart 0.16+, but the script
# does not silently move chart lines; set CHART_VERSION explicitly when enabling them.
_chart_version_provided=false
[[ -n "${CHART_VERSION:-}" ]] && _chart_version_provided=true
CHART_VERSION="${CHART_VERSION:-~0.15.1}"

_chart_version_supports_sandboxes() {
  local version
  version="$(printf '%s' "$1" | tr -d '[:space:]')"
  version="${version#~>}"
  version="${version#~}"
  version="${version#v}"

  case "$version" in
    0.1[6-9].*|0.[2-9][0-9].*|[1-9].*|[1-9][0-9]*.*) return 0 ;;
    *) return 1 ;;
  esac
}

_validate_sandbox_values_file() {
  local values_file="$1"

  if ! grep -Eq '^[[:space:]]{2}sandboxes:[[:space:]]*$' "$values_file" \
    || ! grep -Eq '^[[:space:]]{4}enabled:[[:space:]]*true[[:space:]]*$' "$values_file" \
    || ! grep -Eq '^[[:space:]]{8}existingSecretName:[[:space:]]*"?[^"]+"?[[:space:]]*$' "$values_file" \
    || ! grep -Eq '^[[:space:]]{2}sandboxHostImage:[[:space:]]*$' "$values_file"; then
    echo "ERROR: enable_sandboxes = true, but $(basename "$values_file") does not contain generated sandbox values." >&2
    echo "       Run: ./helm/scripts/init-values.sh after applying infra." >&2
    exit 1
  fi
}

# ── tfvars helpers ────────────────────────────────────────────────────────────
_parse_tfvar() {
  local key="$1"
  awk -F= "/^[[:space:]]*${key}[[:space:]]*=/{gsub(/[ \"']/, \"\", \$2); print \$2; exit}" \
    "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}
_tfvar_is_true() { local v; v=$(_parse_tfvar "$1"); [[ "$v" == "true" ]]; }

_enable_sandboxes=false
_tfvar_is_true "enable_sandboxes" && _enable_sandboxes=true
if [[ "$_enable_sandboxes" == "true" ]]; then
  if [[ "$_chart_version_provided" != "true" ]]; then
    echo "ERROR: enable_sandboxes = true requires CHART_VERSION to be set explicitly to chart 0.16.0 or newer." >&2
    echo "       Example: CHART_VERSION='~0.16.0' ./helm/scripts/deploy.sh" >&2
    exit 1
  fi
  if ! _chart_version_supports_sandboxes "$CHART_VERSION"; then
    echo "ERROR: enable_sandboxes = true requires chart 0.16.0 or newer; got CHART_VERSION=$CHART_VERSION." >&2
    exit 1
  fi
fi

BASE_VALUES_FILE="$VALUES_DIR/values.yaml"
OVERRIDES_FILE="$VALUES_DIR/values-overrides.yaml"

if [[ ! -f "$BASE_VALUES_FILE" ]]; then
  echo "ERROR: $BASE_VALUES_FILE not found." >&2
  exit 1
fi

if [[ ! -f "$OVERRIDES_FILE" ]]; then
  echo "ERROR: $OVERRIDES_FILE not found." >&2
  echo "Run: ./helm/scripts/init-values.sh" >&2
  exit 1
fi

if [[ "$_enable_sandboxes" == "true" ]]; then
  _validate_sandbox_values_file "$OVERRIDES_FILE"
fi

if ! grep -Eq '^\s*hostname:\s*".+"' "$OVERRIDES_FILE"; then
  echo "ERROR: config.hostname must be set in $OVERRIDES_FILE before deploying." >&2
  echo "Run: ./helm/scripts/init-values.sh" >&2
  exit 1
fi

# ── Resolve cluster from tfvars + terraform output ────────────────────────────
_cluster_name="$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null || true)"
_project_id="$(awk -F= '/^[[:space:]]*project_id[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true)"
_region="$(awk -F= '/^[[:space:]]*region[[:space:]]*=/{gsub(/[ "]/, "", $2); print $2; exit}' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true)"
_region="${_region:-us-west2}"

if [[ -z "$_cluster_name" ]]; then
  echo "ERROR: Could not resolve cluster_name from Terraform outputs. Run terraform apply first." >&2
  exit 1
fi

echo "Refreshing kubeconfig for cluster: $_cluster_name"
"$SCRIPT_DIR/get-kubeconfig.sh" "$_cluster_name" "$_region" "$_project_id"
echo "  Active context: $(kubectl config current-context)"
echo ""

# Validate tools/credentials and cluster connectivity.
"$SCRIPT_DIR/preflight-check.sh"
echo ""

# ── Pre-deploy Gateway IP staleness check ────────────────────────────────────
# If the Envoy Gateway IP has changed since last deploy (e.g. after Gateway
# resource recreation), warn the operator and update values-overrides.yaml
# to prevent the Deployments operator from hitting stale endpoints.
_live_gateway_ip=$(kubectl get gateway -n "$NAMESPACE" \
  -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)
if [[ -n "$_live_gateway_ip" ]]; then
  _configured_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _configured_hostname=""
  if [[ -n "$_configured_hostname" && "$_configured_hostname" != "$_live_gateway_ip" ]]; then
    _current_url=$(grep -E '^\s*url:' "$OVERRIDES_FILE" 2>/dev/null \
      | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"
    echo "WARNING: config.hostname is stale."
    echo "  Configured: $_configured_hostname"
    echo "  Gateway IP: $_live_gateway_ip"
    echo "  Updating $(basename "$OVERRIDES_FILE") before deploy..."
    sed -i.bak "s|hostname: \"[^\"]*\"|hostname: \"${_live_gateway_ip}\"|" "$OVERRIDES_FILE" && rm -f "$OVERRIDES_FILE.bak"
    sed -i.bak "s|url: \"${_protocol}://[^\"]*\"|url: \"${_protocol}://${_live_gateway_ip}\"|" "$OVERRIDES_FILE" && rm -f "$OVERRIDES_FILE.bak"
    echo "  Done."
    echo ""
  fi
fi

# ── Build values args ─────────────────────────────────────────────────────────
VALUES_ARGS=(-f "$BASE_VALUES_FILE" -f "$OVERRIDES_FILE")

echo "Values chain:"
echo "  ✔ values.yaml (base)"
echo "  ✔ values-overrides.yaml"

# Sizing: driven by sizing_profile in terraform.tfvars.
_sizing_profile=$(_parse_tfvar "sizing_profile")
_sizing_profile="${_sizing_profile:-default}"
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_file" ]]; then
    VALUES_ARGS+=(-f "$_sizing_file")
    echo "  ✔ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile})"
    if [[ "$_sizing_profile" == "minimum" ]]; then
      echo ""
      echo "  ⚠️  WARNING: sizing_profile = minimum — NOT for production use."
      echo "     Resources are at the absolute floor. Expect degraded performance"
      echo "     under real workloads. Use sizing_profile = production for production."
      echo ""
    fi
  else
    echo "  ✗ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile} but file not found — run: make init-values)"
  fi
else
  echo "  ○ sizing: chart defaults (sizing_profile = default)"
fi

# Addon files: gated by enable_* flags in terraform.tfvars.
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_enable_fleet=false
_enable_standalone_polly=false
_enable_standalone_insights=false
_enable_sandboxes=false
_any_flag_set=false
_tfvar_is_true "enable_deployments"        && { _enable_deployments=true;        _any_flag_set=true; }
_tfvar_is_true "enable_agent_builder"      && { _enable_agent_builder=true;      _any_flag_set=true; }
_tfvar_is_true "enable_insights"           && { _enable_insights=true;            _any_flag_set=true; }
_tfvar_is_true "enable_polly"              && { _enable_polly=true;               _any_flag_set=true; }
_tfvar_is_true "enable_fleet"              && { _enable_fleet=true;               _any_flag_set=true; }
_tfvar_is_true "enable_standalone_polly"   && { _enable_standalone_polly=true;    _any_flag_set=true; }
_tfvar_is_true "enable_standalone_insights" && { _enable_standalone_insights=true; _any_flag_set=true; }
_tfvar_is_true "enable_sandboxes"          && _enable_sandboxes=true

# Validate legacy addon dependencies (standalone flags do not require enable_deployments).
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_polly" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi

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

  if [[ "$_any_flag_set" == "true" ]]; then
    if [[ "$enabled" == "true" ]]; then
      if [[ -f "$f" ]]; then
        VALUES_ARGS+=(-f "$f")
        echo "  ✔ langsmith-values-${addon}.yaml"
      else
        echo "  ✗ langsmith-values-${addon}.yaml (enable_${flag_name}=true but file not found — run init-values.sh)"
      fi
    else
      if [[ -f "$f" ]]; then
        echo "  ○ langsmith-values-${addon}.yaml (file exists but enable_${flag_name}=false — skipped)"
      else
        echo "  ✗ langsmith-values-${addon}.yaml (not enabled)"
      fi
    fi
  else
    if [[ -f "$f" ]]; then
      VALUES_ARGS+=(-f "$f")
      echo "  ✔ langsmith-values-${addon}.yaml"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (not present — skipped)"
    fi
  fi
done
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain

# Guard: pending Helm states (often from interrupted --wait) block upgrades.
# Recover automatically before proceeding.
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
case "$_release_status" in
  pending-upgrade)
    echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in '${_release_status}' state."
    echo "         Rolling back to clear the lock..."
    helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
    echo ""
    ;;
  pending-install|pending-rollback|pending-uninstall)
    echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in '${_release_status}' state."
    echo "         Uninstalling stale release to clear lock before reinstall..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait
    echo ""
    ;;
  failed)
    echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'failed' state."
    echo "         This is commonly a hook timeout and does not always indicate unhealthy workloads."
    echo "         Proceeding with upgrade..."
    echo ""
    ;;
esac

echo "Deploying LangSmith (sizing: ${_sizing_profile})..."
echo "  (waiting for pods — 5-10 min on a cold cluster while nodes provision)"
echo ""

# --devel is required for pre-release chart versions (e.g. 0.15.0-rc.14).
# Helm silently skips any version tagged with -rc./-alpha./-beta. without it.
_devel_flag=""
if [[ -n "$CHART_VERSION" ]] && echo "$CHART_VERSION" | grep -qE '\-(rc|alpha|beta)\.'; then
  _devel_flag="--devel"
fi

set +e
_helm_output=$(helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  ${_devel_flag} \
  "${VALUES_ARGS[@]}" \
  --timeout 20m 2>&1)
_helm_exit=$?
set -e
echo "$_helm_output"

if [[ $_helm_exit -ne 0 ]]; then
  if echo "$_helm_output" | rg -q "post-(install|upgrade) hooks failed: resource not ready, name: ${RELEASE_NAME}-agent-bootstrap, kind: Job"; then
    echo ""
    echo "WARNING: Helm reported agent-bootstrap hook timeout."
    echo "         Continuing with non-blocking readiness checks."
  else
    echo "ERROR: Helm upgrade failed." >&2
    exit $_helm_exit
  fi
fi

echo ""
echo "LangSmith deployed. Waiting for core pods..."
echo ""

# Wait for core components without blocking on long-running hooks.
_core_deployments=(
  "${RELEASE_NAME}-frontend"
  "${RELEASE_NAME}-backend"
  "${RELEASE_NAME}-platform-backend"
  "${RELEASE_NAME}-ingest-queue"
  "${RELEASE_NAME}-queue"
)
if [[ "$_enable_deployments" == "true" ]]; then
  _core_deployments+=(
    "${RELEASE_NAME}-host-backend"
    "${RELEASE_NAME}-listener"
    "${RELEASE_NAME}-operator"
  )
fi
[[ "$_enable_fleet" == "true" ]]              && _core_deployments+=("langsmith-standalone-fleet-api-server")
[[ "$_enable_standalone_polly" == "true" ]]   && _core_deployments+=("langsmith-standalone-polly-api-server")
[[ "$_enable_standalone_insights" == "true" ]] && _core_deployments+=("langsmith-standalone-insights-api-server")

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
  echo "WARNING: Some deployments are still rolling out."
  echo "         Check with: kubectl get pods -n $NAMESPACE"
fi

# Informational only: agent bootstrap can take longer and should not block deploy.
if kubectl get job -n "$NAMESPACE" "${RELEASE_NAME}-agent-bootstrap" >/dev/null 2>&1; then
  _bootstrap_status=$(kubectl get job -n "$NAMESPACE" "${RELEASE_NAME}-agent-bootstrap" \
    -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
  if [[ "$_bootstrap_status" != "True" ]]; then
    echo ""
    echo "Agent bootstrap is still running (non-blocking):"
    echo "  kubectl logs -n $NAMESPACE job/${RELEASE_NAME}-agent-bootstrap --tail=120"
  fi
fi

echo ""

# ── Ensure langsmith-ksa carries the Workload Identity annotation ─────────────
# This SA is used by operator-spawned agent deployment pods. It is created by
# the operator on first use and is NOT part of the Helm release, so it does not
# survive namespace teardowns or fresh cluster rebuilds. Without it, new agent
# pod revisions cannot be scheduled and the agent-bootstrap job hangs indefinitely.
_wi_annotation=$(terraform -chdir="$INFRA_DIR" output -raw workload_identity_annotation 2>/dev/null || true)
if [[ -n "$_wi_annotation" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    iam.gke.io/gcp-service-account="$_wi_annotation" --overwrite
fi

# ── Post-deploy access info ───────────────────────────────────────────────────
_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
_gateway_ip=$(kubectl get gateway -n "$NAMESPACE" \
  -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)

echo "Access LangSmith:"
echo "  Port-forward:  kubectl port-forward svc/${RELEASE_NAME}-frontend -n ${NAMESPACE} 8080:80"
echo "  Then open:     http://localhost:8080"
if [[ -n "$_hostname" ]]; then
  echo "  URL:           https://${_hostname}"
fi
if [[ -n "$_gateway_ip" && "$_gateway_ip" != "$_hostname" ]]; then
  echo "  Gateway IP:    ${_gateway_ip}"
  echo "  (Point your DNS A record for ${_hostname} to ${_gateway_ip})"
fi
echo ""
echo "Next checks:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  helm status $RELEASE_NAME -n $NAMESPACE"
