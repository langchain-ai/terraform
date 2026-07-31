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
#  11. langsmith-values-smithdb.yaml                    — SmithDB overlay (if enable_smithdb)
#  12. langsmith-values-smithdb-overrides.yaml          — SmithDB env-specific: bucket, WI, metastore (if enable_smithdb)
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

# ── tfvars helpers ────────────────────────────────────────────────────────────
# Values are cut at the closing quote, or at an inline # for bare booleans and
# numbers, so a commented flag line still reads as a flag. Keep identical to the
# other copies of this function.
_parse_tfvar() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      if (substr($0, 1, 1) == "\"") { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/#.*$/, ""); gsub(/[[:space:]]+$/, "") }
      print; exit
    }
  ' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}
_tfvar_is_true() { local v; v=$(_parse_tfvar "$1"); [[ "$v" == "true" ]]; }

# ── Chart version ─────────────────────────────────────────────────────────────
# Default pins the chart *line*: latest 0.15.x, never auto-jump to 0.16.
#
# Enabling SmithDB infrastructure does not move that line on its own — upgrading
# the whole application is the operator's decision, not a side effect. SmithDB
# callers pass an explicit version instead.
_chart_version_was_set="${CHART_VERSION+x}"
CHART_VERSION="${CHART_VERSION:-~0.15.1}"

_smithdb_enabled=false
_tfvar_is_true "enable_smithdb" && _smithdb_enabled=true
_smithdb_ingestion_enabled=false
_tfvar_is_true "smithdb_ingestion_enabled" && _smithdb_ingestion_enabled=true
_smithdb_migration_enabled=false
_tfvar_is_true "smithdb_migration_enabled" && _smithdb_migration_enabled=true
_smithdb_query_enabled=false
_tfvar_is_true "smithdb_query_enabled" && _smithdb_query_enabled=true

# The pattern accepts prereleases because the 0.16 line has so far published
# release candidates only, and rejects range syntax: Helm's semver ranges never
# match a prerelease, so "~0.16.0" silently resolves to nothing and the deploy
# would fail later with an opaque "chart not found".
if [[ "$_smithdb_enabled" == "true" ]]; then
  if [[ "$_chart_version_was_set" != "x" ]]; then
    echo "ERROR: enable_smithdb = true requires an explicit CHART_VERSION of 0.16 or newer." >&2
    echo "       Example: CHART_VERSION=0.16.0-rc.22 make deploy" >&2
    echo "       List what is published: helm search repo langchain/langsmith --versions --devel" >&2
    exit 1
  fi
  if [[ "$CHART_VERSION" == "~"* || "$CHART_VERSION" == "^"* ]]; then
    echo "ERROR: SmithDB requires an exact chart version, not the range '$CHART_VERSION'." >&2
    echo "       Helm semver ranges never match prereleases, and the 0.16 line is" >&2
    echo "       prerelease-only, so the range would resolve to no chart at all." >&2
    echo "       Example: CHART_VERSION=0.16.0-rc.22 make deploy" >&2
    exit 1
  fi
  # The prerelease and build-metadata groups follow semver: hyphens are legal
  # inside a prerelease identifier (0.16.0-rc-1), and +build suffixes appear on
  # internally published charts. The character classes stay restricted to
  # [0-9A-Za-z.-] because this is the only gate on an operator-supplied value
  # that is later interpolated into the helm command line.
  if [[ ! "$CHART_VERSION" =~ ^0\.(1[6-9]|[2-9][0-9]|[1-9][0-9]{2,})(\.[0-9]+)?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    echo "ERROR: SmithDB requires a chart version of 0.16 or newer; got '$CHART_VERSION'." >&2
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
_live_gateway_ip=$(kubectl get gateway -n envoy-gateway-system \
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
_any_flag_set=false
_tfvar_is_true "enable_deployments"        && { _enable_deployments=true;        _any_flag_set=true; }
_tfvar_is_true "enable_agent_builder"      && { _enable_agent_builder=true;      _any_flag_set=true; }
_tfvar_is_true "enable_insights"           && { _enable_insights=true;            _any_flag_set=true; }
_tfvar_is_true "enable_polly"              && { _enable_polly=true;               _any_flag_set=true; }
_tfvar_is_true "enable_fleet"              && { _enable_fleet=true;               _any_flag_set=true; }
_tfvar_is_true "enable_standalone_polly"   && { _enable_standalone_polly=true;    _any_flag_set=true; }
_tfvar_is_true "enable_standalone_insights" && { _enable_standalone_insights=true; _any_flag_set=true; }

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

# SmithDB last, so its overrides beat every sizing and addon file above.
if [[ "$_smithdb_enabled" == "true" ]]; then
  _smithdb_file="$VALUES_DIR/langsmith-values-smithdb.yaml"
  _smithdb_overrides_file="$VALUES_DIR/langsmith-values-smithdb-overrides.yaml"

  if [[ ! -f "$_smithdb_file" || ! -f "$_smithdb_overrides_file" ]]; then
    echo "ERROR: enable_smithdb = true but the SmithDB values files are missing." >&2
    echo "Run: ./helm/scripts/init-values.sh" >&2
    exit 1
  fi

  VALUES_ARGS+=(-f "$_smithdb_file" -f "$_smithdb_overrides_file")
  echo "  ✔ langsmith-values-smithdb.yaml"
  echo "  ✔ langsmith-values-smithdb-overrides.yaml"
elif [[ -f "$VALUES_DIR/langsmith-values-smithdb.yaml" ]]; then
  echo "  ○ langsmith-values-smithdb.yaml (file exists but enable_smithdb=false — skipped)"
fi
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

# --devel is required for pre-release chart versions (e.g. 0.15.0-rc.14 or
# 0.16.0-rc.22). Helm silently skips any version carrying a semver prerelease
# component without it. Keyed off the prerelease component itself rather than a
# list of known tags, so forms like -rc22 or -alpha-3 are not missed; the part
# after a + is build metadata and never makes a version a prerelease.
_devel_flag=""
if [[ "${CHART_VERSION%%+*}" == *-* ]]; then
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

# SmithDB pods wait on the cluster autoscaler adding a node to the tainted
# Local SSD pool, which is slower than a normal rollout on a warm cluster.
_smithdb_deployments=()
if [[ "$_smithdb_enabled" == "true" ]]; then
  _smithdb_deployments=(
    "${RELEASE_NAME}-smithdb-cluster-manager"
    "${RELEASE_NAME}-smithdb-ingestion"
    "${RELEASE_NAME}-smithdb-query"
    "${RELEASE_NAME}-smithdb-compaction"
    "${RELEASE_NAME}-smithdb-compaction-worker"
  )
fi

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    echo "  ⏳ $dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

# Guarded on length because bash 3.2 (macOS /bin/bash) aborts under `set -u` when
# an empty array is expanded, and this array is empty whenever SmithDB is off.
if [[ ${#_smithdb_deployments[@]} -gt 0 ]]; then
  for dep in "${_smithdb_deployments[@]}"; do
    if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=10m 2>/dev/null; then
      echo "  ⏳ $dep not ready within 10m (Local SSD nodes may still be provisioning)"
      _all_ready=false
    fi
  done
fi

if [[ "$_all_ready" == "true" ]]; then
  echo "All core deployments ready."
else
  echo ""
  echo "WARNING: Some deployments are still rolling out."
  echo "         Check with: kubectl get pods -n $NAMESPACE"
  if [[ "$_smithdb_enabled" == "true" ]]; then
    echo ""
    echo "         If SmithDB pods are Pending, confirm the Local SSD nodes came up and"
    echo "         advertise enough allocatable ephemeral-storage:"
    echo "           kubectl get nodes -l smithdb-local/instance-store=true"
    echo "           kubectl get node NODE -o jsonpath='{.status.allocatable.ephemeral-storage}'"
  fi
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
_gateway_ip=$(kubectl get gateway -n envoy-gateway-system \
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

if [[ "$_smithdb_enabled" == "true" ]]; then
  echo ""
  echo "SmithDB services are deployed. LangSmith integration advances in stages,"
  echo "driven by infra/terraform.tfvars; ClickHouse stays enabled throughout."
  echo "  ingestion: $_smithdb_ingestion_enabled   migration: $_smithdb_migration_enabled   query: $_smithdb_query_enabled"
  echo ""
  echo "  Verify the cache mount is on Local SSD, not the boot disk:"
  echo "    kubectl exec -n $NAMESPACE deploy/${RELEASE_NAME}-smithdb-query -- df -h /data"
  echo ""
  echo "  Confirm the metastore migration Job completed:"
  echo "    kubectl get job -n $NAMESPACE -l app.kubernetes.io/component=${RELEASE_NAME}-smithdb-metastore-migration"
  echo ""
  if [[ "$_smithdb_ingestion_enabled" == "true" ]]; then
    echo "  Confirm segments are landing in the bucket:"
    echo "    gcloud storage ls gs://\$(terraform -chdir=$INFRA_DIR output -raw smithdb_object_store_bucket)/**"
  else
    echo "  Advance to the next stage by setting smithdb_ingestion_enabled = true in"
    echo "  $INFRA_DIR/terraform.tfvars, then re-running: make init-values && make deploy"
  fi
fi
