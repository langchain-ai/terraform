#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Deploys or upgrades LangSmith via Helm on AWS.
#
# Values files loaded (in order, last wins):
#   1. langsmith-values.yaml            — the base AWS values, copied from examples/
#   2. langsmith-values-overrides.yaml  — everything else, in one file: hostname, IRSA,
#                                         S3, each enabled feature, SSO, SmithDB, and
#                                         your langsmith-values-local.yaml
#
# Write both files first: make init-values (or ./helm/scripts/init-values.sh).
# The deploy stops while either file is missing or was edited by hand, and when
# terraform.tfvars, a module file, or langsmith-values-local.yaml changed after
# make init-values wrote them.
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
MODULE_DIR="$(cd "$HELM_DIR/.." && pwd)"
INFRA_DIR="${LANGSMITH_INFRA_DIR:-$MODULE_DIR/infra}"
VALUES_DIR="${LANGSMITH_VALUES_DIR:-$HELM_DIR/values}"
source "$MODULE_DIR/infra/scripts/_common.sh"
# shellcheck source=_addon-storage.sh
source "$SCRIPT_DIR/_addon-storage.sh"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"
BASE_FILE="$VALUES_DIR/$_VALUES_BASE"
ENV_FILE="$VALUES_DIR/$_VALUES_OVERRIDES"
_stop_if_nginx_applied || exit 1

# Stop before anything touches the cluster: the 0.17 layout, a missing or
# hand-edited values file, or one that make init-values wrote for other inputs.
_values_check "$MODULE_DIR" "$VALUES_DIR" || exit 1
_values_stale=$(_values_resolved_drift "$ENV_FILE" \
  "enable_envoy_gateway=$(_read_applied_flag enable_envoy_gateway false)" \
  "enable_istio_gateway=$(_read_applied_flag enable_istio_gateway false)" \
  "enable_smithdb=$(_read_applied_flag enable_smithdb true)")
if [[ -n "$_values_stale" ]]; then
  echo "ERROR: $_VALUES_OVERRIDES is out of date:" >&2
  sed 's/^/         /' <<< "$_values_stale" >&2
  echo "       Run make init-values, then make deploy." >&2
  exit 1
fi

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
SANDBOX_RELEASE_NAME="${SANDBOX_RELEASE_NAME:-langsmith-sandbox}"
SANDBOX_VALUES_FILE="$VALUES_DIR/langsmith-sandbox-values-overrides.yaml"
# Pin the chart *line*: deploy the latest 0.18.x, never auto-jump to 0.19.
# Override with the CHART_VERSION env var for an exact patch if needed.
# An exported CHART_VERSION outlives the command that set it, so a value left over
# from an earlier session silently wins over the pin. Say so rather than deploying
# a different chart than the branch intends.
if [[ -n "${CHART_VERSION:-}" ]]; then
  echo "NOTE: CHART_VERSION='${CHART_VERSION}' comes from your environment and overrides the ~0.18.0 pin."
  echo "      Run 'unset CHART_VERSION' to deploy the pinned chart line."
fi
# Fall back to the langsmith_helm_chart_version tfvar before the line default, so
# the pin can live in version-controlled config rather than only in a shell
# variable. Env var still wins. Matches Azure and GCP.
if [[ -z "${CHART_VERSION:-}" ]]; then
  CHART_VERSION=$(_parse_tfvar "langsmith_helm_chart_version") || CHART_VERSION=""
  [[ -n "$CHART_VERSION" ]] && \
    echo "Chart version pinned by langsmith_helm_chart_version: ${CHART_VERSION}"
fi
CHART_VERSION="${CHART_VERSION:-~0.18.0}"
# An external runtime runs sandbox-host from its own langsmith-sandbox release in
# the sandbox cluster. That chart has no version setting here: it is the newest
# one whose appVersion equals the langsmith chart's, resolved below.
_sandbox_runtime_source=$(_parse_tfvar "sandbox_runtime_source") || _sandbox_runtime_source="in-cluster"

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

# Checks the sandbox values in the two values files. External runtime: the
# langsmith release runs no sandbox-host, so its values carry
# sandboxes.external.enabled instead of the JuiceFS block, and the runtime's
# values live in their own generated file. They must also name the dedicated
# service-auth key: with sandboxes.external.enabled the chart refuses
# api_key_salt, the default key for an existing Secret. In-cluster runtime: the
# values must name the JuiceFS Secret that Terraform creates. Keep identical to
# the GCP copy.
_validate_sandbox_values() {
  local enabled external secret_key juicefs_secret
  enabled=$(_values_get "$BASE_FILE" "$ENV_FILE" -- sandboxes enabled) || enabled=""
  if [[ "$_sandbox_runtime_source" == "external" ]]; then
    external=$(_values_get "$BASE_FILE" "$ENV_FILE" -- sandboxes external enabled) || external=""
    secret_key=$(_values_get "$BASE_FILE" "$ENV_FILE" -- sandboxes serviceAuth secretKey) || secret_key=""
    if [[ "$enabled" != "true" || "$external" != "true" ]] \
      || [[ "$secret_key" != "sandbox_service_auth_secret" || ! -f "$SANDBOX_VALUES_FILE" ]]; then
      echo "ERROR: external sandbox runtime values are missing or stale. Run: make init-values" >&2
      exit 1
    fi
    return 0
  fi
  juicefs_secret=$(_values_get "$BASE_FILE" "$ENV_FILE" -- sandboxes juicefs existingSecretName) || juicefs_secret=""
  if [[ "$enabled" != "true" || -z "$juicefs_secret" ]]; then
    echo "ERROR: enable_sandboxes = true, but the values files hold no generated sandbox values." >&2
    echo "       Run: make init-values  (or: ./helm/scripts/init-values.sh) after applying infra." >&2
    exit 1
  fi
}

# These values use the chart 0.18 schema: the 0.17 layout (engineInsightsAgent,
# top-level insights/polly, the sandbox-host JuiceFS mount) plus keys that only
# chart 0.18 has, such as sandboxes.external. Chart 0.17 ignores those keys, so
# it would deploy a half-configured release. Refuse any other line.
_chart_line="$(printf '%s' "$CHART_VERSION" | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$_chart_line" != "0.18" ]]; then
  echo "ERROR: CHART_VERSION '$CHART_VERSION' does not resolve to the chart 0.18 line." >&2
  echo "       These values require chart 0.18 (sandbox-host JuiceFS mounts, engineInsightsAgent)." >&2
  echo "       Leave CHART_VERSION unset to use the pin, or name a 0.18 patch explicitly:" >&2
  echo "         CHART_VERSION=0.18.5 make deploy" >&2
  exit 1
fi

# Preflight: reject values still carrying the chart 0.15 schema. They can reach the
# overrides file only from langsmith-values-local.yaml. The chart does reject them,
# but its error names the key, not the file that carries it.
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
  echo "       Remove them from $_VALUES_LOCAL, then run 'make init-values'." >&2
  exit 1
fi

# ── Resolve environment from terraform.tfvars ─────────────────────────────────
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-}"
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_enable_sandboxes=false
_tfvar_is_true "enable_sandboxes" && _enable_sandboxes=true
_enable_engine=false
_tfvar_is_true "enable_engine" && _enable_engine=true
_direct_fleet_enabled=false
_tfvar_is_true "enable_fleet" && _direct_fleet_enabled=true
_direct_polly_enabled=false
_tfvar_is_true "enable_polly" && _direct_polly_enabled=true
_direct_insights_enabled=false
_tfvar_is_true "enable_insights" && _direct_insights_enabled=true

if [[ "$_enable_sandboxes" == "true" ]]; then
  if ! _chart_version_supports_sandboxes "$CHART_VERSION"; then
    echo "ERROR: enable_sandboxes = true requires chart 0.16.0 or newer; got CHART_VERSION=$CHART_VERSION." >&2
    exit 1
  fi
fi

# sandboxes.external ships with chart 0.18, and the runtime chart is picked below by
# this chart's appVersion, so the langsmith chart must be one exact version on
# 0.18 or later, and not a range (the default ~0.18.0 is one). Terraform checks
# langsmith_helm_chart_version the same way; this also covers CHART_VERSION.
# Keep the pattern in step with external_runtime_chart_version_pattern in
# infra/locals.tf.
_external_runtime_chart_re='^(0\.(1[89]|[2-9][0-9])|[1-9][0-9]*\.[0-9]+)\.[0-9]+(-[0-9A-Za-z.-]+)?$'
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]] \
  && ! [[ "$CHART_VERSION" =~ $_external_runtime_chart_re ]]; then
  echo "ERROR: sandbox_runtime_source = external needs one exact langsmith chart version" >&2
  echo "       on 0.18 or later; got CHART_VERSION='$CHART_VERSION'." >&2
  echo "       Set langsmith_helm_chart_version in terraform.tfvars, for example \"0.18.0\"." >&2
  echo "       The langsmith-sandbox chart is then picked by that chart's appVersion." >&2
  exit 1
fi

# Engine needs chart 0.17, which the chart-line check above already enforces.
if [[ "$_enable_engine" == "true" && "$_enable_sandboxes" != "true" ]]; then
  echo "ERROR: enable_engine = true requires enable_sandboxes = true. Every Engine run executes in a sandbox." >&2
  exit 1
fi

# The Engine IRSA role trusts the service account names that Terraform makes from
# langsmith_release_name and langsmith_namespace. A different release or namespace
# gives pods with no AWS credentials, and Bedrock calls then fail.
if [[ "$_enable_engine" == "true" ]]; then
  _tf_release_name=$(_parse_tfvar "langsmith_release_name") || _tf_release_name="langsmith"
  _tf_namespace=$(_parse_tfvar "langsmith_namespace") || _tf_namespace="langsmith"
  if [[ "$RELEASE_NAME" != "$_tf_release_name" || "$NAMESPACE" != "$_tf_namespace" ]]; then
    echo "ERROR: enable_engine = true, but this deploy uses release '$RELEASE_NAME' in namespace '$NAMESPACE'." >&2
    echo "       The Engine IRSA role trusts release '$_tf_release_name' in namespace '$_tf_namespace'" >&2
    echo "       (langsmith_release_name and langsmith_namespace in terraform.tfvars)." >&2
    echo "       Set RELEASE_NAME and NAMESPACE to these values, or change terraform.tfvars and run 'make apply'." >&2
    exit 1
  fi
fi

# Terraform rejects the standalone switches that 0.18 removed, but only at plan,
# and this script reads terraform.tfvars without one. Chat or Insights that only
# a switch turned on would deploy as off.
for _switch in enable_standalone_polly enable_standalone_insights; do
  if _tfvar_is_true "$_switch"; then
    _switch_feature="${_switch#enable_standalone_}"
    echo "ERROR: $_switch was removed in 0.18. Replace it with enable_${_switch_feature} = true and" >&2
    echo "       ${_switch_feature}_storage = \"external\" in terraform.tfvars, then run 'make apply', 'make init-values' and 'make deploy'." >&2
    exit 1
  fi
done

if [[ -z "$_environment" || -z "$_region" ]]; then
  echo "ERROR: Could not resolve environment and/or region from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has 'environment' and 'region' set." >&2
  exit 1
fi

if [[ "$_enable_sandboxes" == "true" ]]; then
  _validate_sandbox_values
fi

_sandbox_cluster_name=""
_sandbox_namespace=""
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  _sandbox_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_name 2>/dev/null) || {
    echo "ERROR: Could not read sandbox_cluster_name. Is terraform apply complete?" >&2
    exit 1
  }
  _sandbox_namespace=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_namespace 2>/dev/null) || _sandbox_namespace="langsmith-sandbox"
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────────
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read cluster_name. Is 'terraform apply' complete?" >&2
  exit 1
}
echo "Updating kubeconfig for cluster: $_cluster_name..."
_use_cluster_kubeconfig "$_cluster_name" "$_region"
echo "  Active context: $(kubectl config current-context)"
echo ""

# ── Preflight checks ──────────────────────────────────────────────────────────
"$SCRIPT_DIR/preflight-check.sh"
echo ""

# Here, after kubectl points at this cluster: make init-values asks for the
# external ClickHouse details on its first run only.
_values_clickhouse_secret_check "$NAMESPACE" "$BASE_FILE" "$ENV_FILE" || exit 1

# Chart 0.16 mounted sandbox volumes through a bundled JuiceFS CSI driver, which
# chart 0.17 deletes. If the upgrade removes the driver while those volumes are
# mounted, kubelet can no longer unmount them and the old sandbox-host pods hang in
# Terminating on juicefs.com/finalizer. Draining needs the driver alive, so stop
# here until no JuiceFS claim or mount pod is left. Checked whatever
# enable_sandboxes says: turning the flag off does not remove a running driver.
# Keep identical to the GCP copy.
if kubectl get daemonset juicefs-csi-node -n "$NAMESPACE" >/dev/null 2>&1; then
  _jfs_workloads=$(kubectl get deployments,statefulsets -n "$NAMESPACE" -o name 2>/dev/null \
    | grep -E 'sandbox-host$' || true)
  _jfs_pvcs=$(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null | grep -Ei 'juicefs|smithbox' || true)
  _jfs_mount_pods=$(kubectl get pods -n "$NAMESPACE" -o name 2>/dev/null \
    | grep -i 'juicefs' | grep -Eiv '/juicefs-csi-(node|controller)' || true)
  if [[ -n "${_jfs_pvcs}${_jfs_mount_pods}" ]]; then
    echo "ERROR: namespace $NAMESPACE still mounts sandbox volumes through the chart 0.16 JuiceFS CSI driver." >&2
    echo "       Chart 0.17 removes that driver, and upgrading now leaves the old sandbox-host pods" >&2
    echo "       stuck in Terminating. Drain the volumes while the driver still runs, then re-run:" >&2
    while IFS= read -r _obj; do
      [[ -z "$_obj" ]] && continue
      echo "         kubectl delete -n $NAMESPACE $_obj" >&2
    done < <(printf '%s\n%s\n' "$_jfs_workloads" "$_jfs_pvcs")
    echo "         kubectl get pods -n $NAMESPACE | grep juicefs   # wait until only juicefs-csi-* pods remain" >&2
    echo "       Running sandboxes stop. Their data stays in object storage and Redis, and chart 0.17" >&2
    echo "       mounts the same JuiceFS volume." >&2
    exit 1
  fi
fi

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
  if [[ "$_enable_sandboxes" == "true" ]]; then
    _require_env "TF_VAR_sandbox_callback_signing_jwk"
  fi
  if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
    _require_env "TF_VAR_sandbox_service_auth_secret"
  fi
  if [[ "$_direct_fleet_enabled" == "true" ]]; then
    _require_env "TF_VAR_langsmith_agent_builder_encryption_key"
  fi
  if [[ "$_direct_polly_enabled" == "true" ]]; then
    _require_env "TF_VAR_langsmith_polly_encryption_key"
  fi
  if [[ "$_direct_insights_enabled" == "true" ]]; then
    _require_env "TF_VAR_langsmith_insights_encryption_key"
  fi
  if [[ "$_enable_engine" == "true" ]]; then
    _require_env "TF_VAR_langsmith_engine_encryption_key"
    _require_env "TF_VAR_langsmith_engine_usage_signing_secret"
  fi

  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  _sandbox_secret_literals=()
  if [[ "$_enable_sandboxes" == "true" ]]; then
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _sandbox_secret_literals=(
      --from-literal=sandbox_callback_signing_jwk="${TF_VAR_sandbox_callback_signing_jwk}"
    )
  fi
  if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
    # The dedicated service-auth secret; Terraform writes the same value into
    # the sandbox cluster's runtime Secret.
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _sandbox_secret_literals+=(
      --from-literal=sandbox_service_auth_secret="${TF_VAR_sandbox_service_auth_secret}"
    )
  fi
  _fleet_secret_literals=()
  if [[ "$_direct_fleet_enabled" == "true" ]]; then
    # The chart reads Fleet's key from langsmith-config by its historical name.
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _fleet_secret_literals=(
      --from-literal=agent_builder_encryption_key="${TF_VAR_langsmith_agent_builder_encryption_key}"
    )
  fi
  _polly_secret_literals=()
  if [[ "$_direct_polly_enabled" == "true" ]]; then
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _polly_secret_literals=(
      --from-literal=polly_encryption_key="${TF_VAR_langsmith_polly_encryption_key}"
    )
  fi
  _insights_secret_literals=()
  if [[ "$_direct_insights_enabled" == "true" ]]; then
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _insights_secret_literals=(
      --from-literal=insights_encryption_key="${TF_VAR_langsmith_insights_encryption_key}"
    )
  fi
  _engine_secret_literals=()
  if [[ "$_enable_engine" == "true" ]]; then
    # shellcheck disable=SC2154  # exported by setup-env.sh; _require_env above asserts it
    _engine_secret_literals=(
      --from-literal=engine_encryption_key="${TF_VAR_langsmith_engine_encryption_key}"
      --from-literal=engine_usage_signing_secret="${TF_VAR_langsmith_engine_usage_signing_secret}"
    )
  fi

  # Bash 3.2 treats an empty array as unset under nounset, so each optional
  # array expands only when it has elements.
  # shellcheck disable=SC2154  # TF_VAR_* exported by setup-env.sh; _require_env above asserts them
  kubectl create secret generic langsmith-config \
    --namespace "$NAMESPACE" \
    --from-literal=langsmith_license_key="${LANGSMITH_LICENSE_KEY}" \
    --from-literal=api_key_salt="${TF_VAR_langsmith_api_key_salt}" \
    --from-literal=jwt_secret="${TF_VAR_langsmith_jwt_secret}" \
    --from-literal=initial_org_admin_password="${LANGSMITH_ADMIN_PASSWORD}" \
    ${_sandbox_secret_literals[@]+"${_sandbox_secret_literals[@]}"} \
    ${_fleet_secret_literals[@]+"${_fleet_secret_literals[@]}"} \
    ${_polly_secret_literals[@]+"${_polly_secret_literals[@]}"} \
    ${_insights_secret_literals[@]+"${_insights_secret_literals[@]}"} \
    ${_engine_secret_literals[@]+"${_engine_secret_literals[@]}"} \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  langsmith-config secret ready (direct)."
else
  # These CRD resources can't be managed by Terraform (CRDs must exist at plan time).
  # Applied here after ESO is installed by terraform apply.
  # Run standalone to re-sync ESO without a full redeploy: ./helm/scripts/apply-eso.sh
  NAMESPACE="$NAMESPACE" INFRA_DIR="$INFRA_DIR" "$SCRIPT_DIR/apply-eso.sh"
fi

# Each enabled add-on reads its keys from langsmith-config with optional: false,
# and apply-eso.sh adds a key only when its SSM parameter exists: Fleet reads
# agent_builder_encryption_key, Chat polly_encryption_key, Insights
# insights_encryption_key, and Engine engine_encryption_key and
# engine_usage_signing_secret. The chart checks for them only when Helm can read
# the Secret, so check here first, by key name only. ESO can take a few seconds to
# write a new key after apply-eso.sh.
_required_keys=""
[[ "$_direct_fleet_enabled" != "true" ]] || _required_keys+=" agent_builder_encryption_key"
[[ "$_direct_polly_enabled" != "true" ]] || _required_keys+=" polly_encryption_key"
[[ "$_direct_insights_enabled" != "true" ]] || _required_keys+=" insights_encryption_key"
[[ "$_enable_engine" != "true" ]] || _required_keys+=" engine_encryption_key engine_usage_signing_secret"
if [[ -n "$_required_keys" ]]; then
  _keys_missing=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    _keys_missing=""
    for _key in $_required_keys; do
      _present=$(kubectl get secret langsmith-config -n "$NAMESPACE" \
        -o go-template="{{with .data}}{{if index . \"${_key}\"}}yes{{end}}{{end}}" 2>/dev/null) || _present=""
      [[ "$_present" == "yes" ]] || _keys_missing+=" ${_key}"
    done
    [[ -z "$_keys_missing" ]] && break
    sleep 5
  done
  if [[ -n "$_keys_missing" ]]; then
    echo "ERROR: Secret langsmith-config in $NAMESPACE has no key:${_keys_missing}" >&2
    echo "       The add-ons that terraform.tfvars turns on read these keys. Create the SSM parameters," >&2
    echo "       then sync them and re-run:" >&2
    echo "         source infra/scripts/setup-env.sh   # creates the encryption keys of the enabled add-ons" >&2
    echo "         make apply-eso" >&2
    exit 1
  fi
  echo "  langsmith-config has${_required_keys}."
fi
echo ""

# ── Read feature flags from terraform.tfvars ─────────────────────────────────
_enable_deployments=false
_enable_insights=false
_enable_polly=false
_enable_fleet=false
_enable_sandboxes=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true
_tfvar_is_true "enable_insights"      && _enable_insights=true
_tfvar_is_true "enable_polly"         && _enable_polly=true
_tfvar_is_true "enable_fleet"               && _enable_fleet=true
_tfvar_is_true "enable_sandboxes"     && _enable_sandboxes=true
_enable_smithdb=$(_read_applied_flag "enable_smithdb" true)

# Gateway flags come from the Terraform outputs, not the tfvars text: enable_envoy_gateway
# is derived (unset = on unless Istio was chosen), and getting this wrong sends the
# hostname resolution below to the Ingress status instead of the Terraform ALB.
_enable_envoy_gateway=$(_read_applied_flag "enable_envoy_gateway" false)
_enable_istio_gateway=$(_read_applied_flag "enable_istio_gateway" false)

# Classic ALB Ingress mode = none of the gateway routing modes are enabled.
# In that mode the AWS Load Balancer Controller creates and owns the ALB, so the
# external hostname must be read from the Ingress status — not the Terraform ALB
# (alb_dns_name), which is a separate, unused ALB in this mode.
_alb_ingress_mode=false
if [[ "$_enable_envoy_gateway" != "true" && "$_enable_istio_gateway" != "true" ]]; then
  _alb_ingress_mode=true
fi

# Resolve the external entry hostname for the hostname-sync logic below.
#   $1 = max attempts (1 = single best-effort read, no waiting between attempts).
# In ALB Ingress mode the controller-owned ALB's DNS is published on the Ingress
# status; it appears a couple minutes after the first helm upgrade, so callers
# that run post-deploy pass a retry count. In Envoy/Istio modes the
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

# ── Build values args ─────────────────────────────────────────────────────────
# The two files that make init-values wrote. The only value set here is the
# sandbox-host image tag, which follows the chart that helm resolves below.
VALUES_ARGS=(-f "$BASE_FILE" -f "$ENV_FILE")

echo ""
echo "Values:"
echo "  ✔ $_VALUES_BASE (the base values, from examples/)"
echo "  ✔ $_VALUES_OVERRIDES (make init-values: Terraform outputs and the enabled features)"
if [[ -f "$VALUES_DIR/$_VALUES_LOCAL" ]]; then
  echo "    with your changes from $_VALUES_LOCAL"
fi

# SSO is one-way (LangSmith does not support going back to basic auth), so the deploy stops rather than redeploy a live SSO install with basic auth.
if ! _tfvar_is_true "enable_sso_oidc"; then
  # The chart sets BASIC_AUTH_ENABLED to "false" only when SSO is on, and names the ConfigMap <release>-config when the release name contains "langsmith".
  _auth_cm="${RELEASE_NAME}-langsmith-config"
  [[ "$RELEASE_NAME" == *langsmith* ]] && _auth_cm="${RELEASE_NAME}-config"
  if [[ "$(kubectl get configmap "$_auth_cm" -n "$NAMESPACE" -o jsonpath='{.data.BASIC_AUTH_ENABLED}' 2>/dev/null)" == "false" ]]; then
    echo "  ✗ SSO is on in the cluster, and LangSmith does not support turning it off — set enable_sso_oidc = true in terraform.tfvars" >&2
    exit 1
  fi
fi

# init-values.sh points Fleet, Chat, Insights and Engine at the shared RDS and
# ElastiCache. Stop while the live release still keeps that data in the cluster.
_engine_insights_agent=false
[[ "$_enable_insights" == "true" || "$_enable_engine" == "true" ]] && _engine_insights_agent=true
_unconfirmed_storage=()
if [[ "$_enable_fleet" == "true" && "$(_parse_tfvar fleet_storage || true)" != "external" ]]; then
  _unconfirmed_storage+=(fleet)
fi
if [[ "$_enable_polly" == "true" && "$(_parse_tfvar polly_storage || true)" != "external" ]]; then
  _unconfirmed_storage+=(polly)
fi
if [[ "$_engine_insights_agent" == "true" && "$(_parse_tfvar insights_storage || true)" != "external" ]]; then
  _unconfirmed_storage+=(engineInsightsAgent)
fi
_addon_storage_cutover_check "$RELEASE_NAME" "$NAMESPACE" ${_unconfirmed_storage[@]+"${_unconfirmed_storage[@]}"} || exit 1
if [[ "$_enable_fleet" == "true" || "$_enable_polly" == "true" || "$_engine_insights_agent" == "true" ]]; then
  echo "  ✔ Fleet, Chat, Insights and Engine storage (shared RDS and ElastiCache)"
fi

# SmithDB: the tier comes from the values and the node size from Terraform, so
# only a deploy can compare them. The cache mode follows smithdb_cache_storage
# and the applied nodes, so a make apply that changed it needs make init-values.
if [[ "$_enable_smithdb" == "true" ]]; then
  source "$MODULE_DIR/infra/scripts/_smithdb.sh"
  _smithdb_cache_storage=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_cache_storage 2>/dev/null) || _smithdb_cache_storage=""
  _smithdb_cache_storage=$(_smithdb_cache_mode "$_smithdb_cache_storage" "$(_parse_tfvar "smithdb_cache_storage" || true)") || exit 1
  _values_stale=$(_values_resolved_drift "$ENV_FILE" "smithdb_cache_storage=$_smithdb_cache_storage")
  if [[ -n "$_values_stale" ]]; then
    echo "ERROR: $_VALUES_OVERRIDES is out of date: $_values_stale" >&2
    echo "       Run make init-values, then make deploy." >&2
    exit 1
  fi
  SMITHDB_RESOURCE_TIER=$(_values_get "$BASE_FILE" "$ENV_FILE" -- smithdb resourceTier) || SMITHDB_RESOURCE_TIER=small
  _smithdb_tier_fits "$SMITHDB_RESOURCE_TIER" "$_smithdb_cache_storage" || exit 1
  echo "  ✔ SmithDB ${SMITHDB_RESOURCE_TIER} tier fits node-group-smithdb (${_smithdb_cache_storage} cache)"
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
  _configured_hostname=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname) || _configured_hostname=""
  # Compare host-only: config.hostname carries a scheme (http(s)://) so the chart
  # emits correct browser URLs, but _live_lb is the bare ALB DNS.
  _configured_host_only="${_configured_hostname#*://}"
  if [[ -n "$_configured_host_only" && "$_configured_host_only" != "$_live_lb" ]]; then
    echo "WARNING: config.hostname is stale."
    echo "  Configured: $_configured_hostname"
    echo "  Actual:     $_live_lb"
    echo "  Updating $(basename "$ENV_FILE") before deploy..."

    _current_url=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config deployment url) || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    # Keep the scheme on config.hostname (chart defaults bare host to https).
    _values_set_strings "$ENV_FILE" "config.hostname=${_protocol}://${_live_lb}" \
      "config.deployment.url=${_protocol}://${_live_lb}"
    echo "  Done."
    echo ""
  fi
fi

echo ""
echo "Deploying LangSmith (environment: $_environment)..."
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
_irsa_arn_pre=$(_values_get "$BASE_FILE" "$ENV_FILE" -- \
  backend serviceAccount annotations eks.amazonaws.com/role-arn) || _irsa_arn_pre=""
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

# --server-side is a Helm 4 flag. Helm 3 has no server-side apply and rejects the
# whole invocation with "unknown flag: --server-side" (verified on v3.21.4), so
# passing it unconditionally blocks the deploy on the Helm 3 the docs require.
# On Helm 4, SSA is the default for a fresh install and fights the ALB ingress
# controller over .spec.rules ownership, so ask for client-side apply explicitly
# there. Helm 3 only ever applies client-side, making the flag redundant as well
# as unsupported. If the version cannot be read, omit it: omitting is valid on
# both majors, passing it fails outright on one.
_helm_major=$(helm version --template '{{.Version}}' 2>/dev/null | sed -e 's/^v//' -e 's/[^0-9].*$//') || _helm_major=""
_ssa_flag=""
if [[ -z "$_helm_major" ]]; then
  echo "WARNING: could not read the Helm version; omitting --server-side=false." >&2
elif [[ "$_helm_major" -ge 4 ]]; then
  _ssa_flag="--server-side=false"
fi

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
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "in-cluster" ]]; then
  _sandbox_host_image_tag=$(awk '/^appVersion:/{print $2}' <<<"$_chart_metadata")
  if [[ -z "$_sandbox_host_image_tag" ]]; then
    echo "ERROR: chart $_resolved_chart does not declare an appVersion for the Sandbox image." >&2
    exit 1
  fi
  VALUES_ARGS+=(--set-string "images.sandboxHostImage.tag=$_sandbox_host_image_tag")
  echo "Sandboxes: sandbox-host image tag=$_sandbox_host_image_tag"
fi

# External runtime: the runtime chart pairs with the langsmith chart by
# appVersion, which is the LangSmith release both deploy, never by chart
# version. Install the newest langsmith-sandbox chart with the same appVersion.
# Resolved here, before either release changes, so a missing runtime chart stops
# the deploy instead of leaving the control plane upgraded without a runtime.
_sandbox_chart_version=""
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: sandbox_runtime_source = external needs jq to pick the langsmith-sandbox chart." >&2
    exit 1
  fi
  _langsmith_app_version=$(awk '/^appVersion:/{print $2}' <<<"$_chart_metadata" | tr -d "\"'")
  if [[ -z "$_langsmith_app_version" ]]; then
    echo "ERROR: chart langchain/langsmith $_resolved_chart declares no appVersion to pair the sandbox runtime with." >&2
    exit 1
  fi
  # --devel: release candidates pair with prerelease runtime charts.
  _sandbox_chart_version=$(helm search repo langchain/langsmith-sandbox --versions --devel -o json 2>/dev/null \
    | jq -r --arg app "$_langsmith_app_version" \
      '[.[] | select(.name == "langchain/langsmith-sandbox" and .app_version == $app)][0].version // empty') \
    || _sandbox_chart_version=""
  if [[ -z "$_sandbox_chart_version" ]]; then
    echo "ERROR: no langchain/langsmith-sandbox chart has appVersion $_langsmith_app_version," >&2
    echo "       the appVersion of langchain/langsmith $_resolved_chart. The sandbox runtime must run" >&2
    echo "       the same LangSmith release as the control plane. Neither Helm release was changed." >&2
    echo "       List the published runtime charts with:" >&2
    echo "         helm search repo langchain/langsmith-sandbox --versions --devel" >&2
    exit 1
  fi
  echo "Chart: langchain/langsmith-sandbox  appVersion=${_langsmith_app_version}  resolved=${_sandbox_chart_version}"
fi

# A failed hook leaves Helm reporting only "hooks failed: job failed:
# BackoffLimitExceeded", which never names the job. The chart's hooks use
# hook-delete-policy before-hook-creation, so the failed Job and its pod are
# still in the cluster and can be read back.
_report_failed_hook_jobs() {
  local job failed
  echo "" >&2
  echo "Helm failed. Jobs in namespace ${NAMESPACE}:" >&2
  kubectl get jobs -n "$NAMESPACE" >&2 || true
  while read -r job failed; do
    [[ -n "$job" && "${failed:-}" =~ ^[0-9]+$ ]] || continue
    ((failed > 0)) || continue
    echo "" >&2
    echo "── failed hook job: ${job} ──" >&2
    kubectl describe job "$job" -n "$NAMESPACE" >&2 || true
    kubectl logs "job/$job" -n "$NAMESPACE" --all-containers --tail=200 >&2 || true
  done < <(kubectl get jobs -n "$NAMESPACE" \
    -o 'jsonpath={range .items[*]}{.metadata.name}{" "}{.status.failed}{"\n"}{end}' \
    2>/dev/null || true)
}

# Moving from the in-cluster runtime: Sandboxes that resume from saved memory
# keep trusting the egress proxy CA they started with, so the external runtime
# must keep the CA the langsmith chart generated. Copy it into the sandbox
# namespace before the upgrade below removes it. The Secret goes straight from
# one cluster to the other and is never printed.
_proxy_ca_secret="smithbox-proxy-ca"
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]] \
  && kubectl get secret "$_proxy_ca_secret" -n "$NAMESPACE" >/dev/null 2>&1; then
  (
    _main_kubeconfig="$KUBECONFIG"
    _use_cluster_kubeconfig "$_sandbox_cluster_name" "$_region" >/dev/null
    if kubectl get secret "$_proxy_ca_secret" -n "$_sandbox_namespace" >/dev/null 2>&1; then
      exit 0
    fi
    if ! kubectl get namespace "$_sandbox_namespace" >/dev/null 2>&1; then
      echo "ERROR: namespace $_sandbox_namespace is missing in $_sandbox_cluster_name. Run 'make apply' first." >&2
      exit 1
    fi
    KUBECONFIG="$_main_kubeconfig" kubectl get secret "$_proxy_ca_secret" -n "$NAMESPACE" -o json \
      | jq --arg ns "$_sandbox_namespace" '{apiVersion, kind, type,
          metadata: {name: .metadata.name, namespace: $ns},
          data: {"tls.crt": .data["tls.crt"], "tls.key": .data["tls.key"]}}' \
      | kubectl apply -f - >/dev/null
    echo "Copied the in-cluster runtime's proxy CA ($_proxy_ca_secret) into $_sandbox_namespace."
  )
fi

if ! helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  ${_devel_flag} \
  "${VALUES_ARGS[@]}" \
  ${_ssa_flag} \
  --timeout "$_helm_timeout"; then
  _report_failed_hook_jobs
  exit 1
fi

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
if [[ "$_enable_fleet" == "true" && "$_enable_deployments" != "true" ]]; then
  _core_deployments+=("${RELEASE_NAME}-host-backend")
fi
# Standalone agent features (chart v0.15+). Deployment names derive from
# <release>-<namePrefix>-<component>; namePrefix is standalone-{fleet,polly,insights}.
[[ "$_enable_fleet" == "true" ]]               && _core_deployments+=("${RELEASE_NAME}-standalone-fleet-api-server")
[[ "$_enable_polly" == "true" ]]               && _core_deployments+=("${RELEASE_NAME}-standalone-polly-api-server")
[[ "$_enable_insights" == "true" || "$_enable_engine" == "true" ]] && _core_deployments+=("${RELEASE_NAME}-standalone-insights-api-server")

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    echo "  ⏳ $dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "in-cluster" ]]; then
  # Helm's fullname can include the chart name or an override, so select by the release labels.
  if ! kubectl rollout status deployment -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE_NAME},app=sandbox-host" --timeout=5m 2>/dev/null; then
    echo "  ⏳ sandbox-host for release ${RELEASE_NAME} not ready within 5m (sandbox-host nodes may still be starting)"
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
# Envoy/Istio modes the Terraform-provisioned ALB output is used.
# Patch config.hostname + deployment.url in the overrides file if stale, then
# re-run helm upgrade so HTTPRoute hostname filters and deployment URLs are correct.
_active_host=""
_active_host=$(_resolve_entry_hostname 10) || true
[[ -n "$_active_host" ]] && echo "ALB hostname: $_active_host"

if [[ -n "$_active_host" ]]; then
  echo ""
  _current_hostname=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname) || _current_hostname=""
  # Compare host-only: config.hostname carries a scheme; _active_host is bare DNS.
  _current_host_only="${_current_hostname#*://}"
  if [[ "$_current_host_only" != "$_active_host" && -z "$_langsmith_domain" ]]; then
    _current_url=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config deployment url) || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"

    # Keep the scheme on config.hostname (chart defaults bare host to https).
    _values_set_strings "$ENV_FILE" "config.hostname=${_protocol}://${_active_host}" \
      "config.deployment.url=${_protocol}://${_active_host}"
    echo "Updated config.hostname in $(basename "$ENV_FILE"): ${_current_hostname:-<blank>} → ${_protocol}://${_active_host}"
    echo "Re-running deploy for hostname to take effect..."
    echo ""
    if ! helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
      --namespace "$NAMESPACE" \
      ${CHART_VERSION:+--version "$CHART_VERSION"} \
      ${_devel_flag} \
      "${VALUES_ARGS[@]}" \
      ${_ssa_flag} \
      --timeout "$_helm_timeout"; then
      _report_failed_hook_jobs
      exit 1
    fi
    echo ""
    echo "LangSmith redeployed with hostname: $_active_host"
  fi
else
  echo "(Load balancer not yet ready — re-run deploy after a few minutes to get the hostname)"
fi

if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  # basePath matters because the sandbox reaches LangSmith at
  # <hostname>/<basePath>/api; dropping it yields a URL that passes the chart's
  # /api check and then 404s at runtime.
  _platform_host=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname) || _platform_host=""
  _platform_base_path=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config basePath) || _platform_base_path=""

  if [[ ! "$_platform_host" =~ ^https?://[^/]+ ]]; then
    echo "ERROR: an external sandbox runtime needs an absolute config.hostname in $(basename "$ENV_FILE")." >&2
    echo "       Found: '${_platform_host:-<empty>}'. Re-run 'make init-values' after the ALB is up," >&2
    echo "       or set langsmith_domain in terraform.tfvars." >&2
    exit 1
  fi

  _platform_endpoint="${_platform_host%/}"
  _platform_base_path="${_platform_base_path#/}"
  _platform_base_path="${_platform_base_path%/}"
  [[ -n "$_platform_base_path" ]] && _platform_endpoint+="/${_platform_base_path}"
  _platform_endpoint+="/api"

  echo ""
  echo "Deploying sandbox runtime to cluster: $_sandbox_cluster_name"
  echo "Chart: langchain/langsmith-sandbox ${_sandbox_chart_version} (appVersion ${_langsmith_app_version})"
  echo "Platform endpoint: $_platform_endpoint"

  # Subshell: the sandbox cluster gets its own kubeconfig file from main's
  # helper (~/.kube/langsmith-<cluster>), and the KUBECONFIG export ends with
  # the subshell. set -e still exits the script on a failure in here.
  # No images.sandboxHostImage.tag: the chart runs the image of its own appVersion.
  # No --wait or --atomic: hosts drain one at a time, so a slow roll is not a
  # failed one; the rollout check below only warns.
  (
    _use_cluster_kubeconfig "$_sandbox_cluster_name" "$_region"

    # A proxy CA Secret that this release does not own was copied in from the
    # in-cluster runtime (above, or by hand as the docs describe). Run on it:
    # the default generatedSecret mode would try to adopt it, and Helm refuses
    # a Secret it does not own.
    _proxy_ca_args=()
    if _proxy_ca_owner=$(kubectl get secret "$_proxy_ca_secret" -n "$_sandbox_namespace" \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null) \
      && [[ "$_proxy_ca_owner" != "$SANDBOX_RELEASE_NAME" ]]; then
      _proxy_ca_args=(--set proxyCa.mode=existingSecret --set-string "proxyCa.existingSecretName=$_proxy_ca_secret")
      echo "Proxy CA: using the copied Secret $_proxy_ca_secret"
    fi

    helm upgrade --install "$SANDBOX_RELEASE_NAME" langchain/langsmith-sandbox \
      --namespace "$_sandbox_namespace" \
      --create-namespace \
      --version "$_sandbox_chart_version" \
      -f "$SANDBOX_VALUES_FILE" \
      --set-string "config.endpoint=$_platform_endpoint" \
      ${_proxy_ca_args[@]+"${_proxy_ca_args[@]}"} \
      ${_ssa_flag} \
      --timeout "$_helm_timeout"

    if ! kubectl rollout status deployment -n "$_sandbox_namespace" \
      -l "app.kubernetes.io/instance=${SANDBOX_RELEASE_NAME},app=sandbox-host" --timeout=15m; then
      echo "WARNING: sandbox-host is not ready; sandbox nodes may still be starting." >&2
    fi
  )
  echo "  Sandbox cluster kubeconfig: $HOME/.kube/langsmith-${_sandbox_cluster_name}"
fi

echo ""
echo "Access LangSmith:"
echo "  Kubeconfig:    export KUBECONFIG=$KUBECONFIG"
echo "  Port-forward:  kubectl port-forward svc/${RELEASE_NAME}-frontend -n ${NAMESPACE} 8080:80"
echo "  Then open:     http://localhost:8080"
if [[ -n "${_langsmith_domain:-}" ]]; then
  echo "  URL:           https://${_langsmith_domain}"
elif [[ -n "${_active_host:-}" ]]; then
  echo "  URL:           http://${_active_host}"
fi
