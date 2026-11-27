#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# Deploys or upgrades LangSmith via Helm on GCP.
#
# Values files applied, in order (last wins):
#   1. langsmith-values.yaml            — the base GCP values, copied from examples/
#   2. langsmith-values-overrides.yaml  — everything else: Terraform outputs, the
#                                         sizing profile, each enabled feature,
#                                         SmithDB, and langsmith-values-local.yaml
#
# make init-values writes both files. This script stops before it touches the
# cluster when a file is missing, was edited by hand, or was written for other
# inputs (terraform.tfvars, a module file, the local file, or langsmith_domain).
# The secrets go into the langsmith-config Secret, from the TF_VAR_* values that
# setup-env.sh exports. The values files hold none.
# Sourced directly, the `set -euo pipefail` below would leak into the caller's
# shell and leave it armed to exit on the next non-zero command, and any `exit`
# here would close that shell outright. So when sourced, hand off to a child
# process and return its status - `source` then behaves exactly like running it.
# Keep this above `set`.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
MODULE_DIR="$(cd "$HELM_DIR/.." && pwd)"
INFRA_DIR="${LANGSMITH_INFRA_DIR:-$MODULE_DIR/infra}"

# Defined here rather than further down because CHART_VERSION resolution below
# needs it, and the chart-line guard runs before the old definition site.
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
VALUES_DIR="${LANGSMITH_VALUES_DIR:-$HELM_DIR/values}"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"
BASE_FILE="$VALUES_DIR/$_VALUES_BASE"
ENV_FILE="$VALUES_DIR/$_VALUES_OVERRIDES"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
# Pin the chart *line*: deploy the latest 0.17.x, never auto-jump to 0.18.
# Override with the CHART_VERSION env var for an exact patch if needed.
#
# Read the pin from the Terraform output, not from terraform.tfvars. That file is
# only one of Terraform's variable sources, and not the highest priority one, so
# a parse of the file alone misses a value set in an .auto.tfvars file, a
# .tfvars.json file, -var, -var-file or TF_VAR_langsmith_helm_chart_version, and
# Helm then installs a different chart than the applied configuration declares.
# The output is a plain string and carries no secret.
#
# The read fails when the state carries outputs but not this one, which is a
# state applied before this output existed, and when terraform cannot run at all.
# Fall back to the file parse there, so an older state keeps its documented pin.
# An empty result is an answer rather than a failure: it means no pin, so let the
# chart line default below apply. A tree with no state at all also reads as
# empty, and the cluster_name check further down stops that run regardless.
_chart_version_pin_source="terraform output"
if ! _chart_version_pin=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_helm_chart_version 2>/dev/null); then
  _chart_version_pin_source="terraform.tfvars"
  _chart_version_pin=$(_parse_tfvar "langsmith_helm_chart_version") || _chart_version_pin=""
fi

# An exported CHART_VERSION outlives the command that set it, so a value left over
# from an earlier session silently wins over the pin. Say so rather than deploying
# a different chart than the branch intends, and name the version that an unset
# returns to, which is the pin when there is one.
if [[ -n "${CHART_VERSION:-}" ]]; then
  echo "NOTE: CHART_VERSION='${CHART_VERSION}' comes from your environment."
  if [[ -n "$_chart_version_pin" ]]; then
    echo "      It overrides langsmith_helm_chart_version=${_chart_version_pin} (${_chart_version_pin_source})."
    echo "      Run 'unset CHART_VERSION' to deploy ${_chart_version_pin}."
  else
    echo "      It overrides the ~0.18.0 chart line pin."
    echo "      Run 'unset CHART_VERSION' to deploy the pinned chart line."
  fi
elif [[ -n "$_chart_version_pin" ]]; then
  CHART_VERSION="$_chart_version_pin"
  echo "Chart version pinned by langsmith_helm_chart_version (${_chart_version_pin_source}): ${CHART_VERSION}"
fi
CHART_VERSION="${CHART_VERSION:-~0.18.0}"

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
# the AWS copy.
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

# ── tfvars helpers ────────────────────────────────────────────────────────────
# Values are cut at the closing quote, or at an inline # for bare booleans and
# numbers, so a commented flag line still reads as a flag. Keep identical to the
# other copies of this function.
_tfvar_is_true() { local v; v=$(_parse_tfvar "$1"); [[ "$v" == "true" ]]; }

# SmithDB on this module needs chart 0.17, which the line guard above already
# guarantees for every deploy, so there is no SmithDB-specific version gate
# here. These flags drive the values chain and the rollout wait below.
_smithdb_enabled=false
_tfvar_is_true "enable_smithdb" && _smithdb_enabled=true
_smithdb_ingestion_enabled=false
_tfvar_is_true "smithdb_ingestion_enabled" && _smithdb_ingestion_enabled=true
_smithdb_query_enabled=false
_tfvar_is_true "smithdb_query_enabled" && _smithdb_query_enabled=true

_enable_sandboxes=false
_tfvar_is_true "enable_sandboxes" && _enable_sandboxes=true
if [[ "$_enable_sandboxes" == "true" ]]; then
  if ! _chart_version_supports_sandboxes "$CHART_VERSION"; then
    echo "ERROR: enable_sandboxes = true requires chart 0.16.0 or newer; got CHART_VERSION=$CHART_VERSION." >&2
    exit 1
  fi
fi

# An external runtime runs sandbox-host from its own langsmith-sandbox release in
# the sandbox cluster. That chart has no version setting here: it is the newest
# one whose appVersion equals the langsmith chart's, resolved below.
SANDBOX_RELEASE_NAME="${SANDBOX_RELEASE_NAME:-langsmith-sandbox}"
SANDBOX_VALUES_FILE="$VALUES_DIR/langsmith-sandbox-values-overrides.yaml"
_sandbox_runtime_source=$(_parse_tfvar "sandbox_runtime_source")
_sandbox_runtime_source="${_sandbox_runtime_source:-in-cluster}"
_external_sandbox_runtime=false
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  _external_sandbox_runtime=true
fi

# sandboxes.external ships with chart 0.18, and the runtime chart is picked below by
# this chart's appVersion, so the langsmith chart must be one exact version on
# 0.18 or later, and not a range (the default ~0.18.0 is one). Terraform checks
# langsmith_helm_chart_version the same way; this also covers CHART_VERSION.
# Keep the pattern in step with external_runtime_chart_version_pattern in
# infra/locals.tf.
_external_runtime_chart_re='^(0\.(1[89]|[2-9][0-9])|[1-9][0-9]*\.[0-9]+)\.[0-9]+(-[0-9A-Za-z.-]+)?$'
if [[ "$_external_sandbox_runtime" == "true" ]] && ! [[ "$CHART_VERSION" =~ $_external_runtime_chart_re ]]; then
  echo "ERROR: sandbox_runtime_source = external needs one exact langsmith chart version" >&2
  echo "       on 0.18 or later; got CHART_VERSION='$CHART_VERSION'." >&2
  echo "       Set langsmith_helm_chart_version in terraform.tfvars, for example \"0.18.0\"." >&2
  echo "       The langsmith-sandbox chart is then picked by that chart's appVersion." >&2
  exit 1
fi

_sandbox_cluster_name=""
_sandbox_cluster_location=""
_sandbox_namespace=""
if [[ "$_external_sandbox_runtime" == "true" ]]; then
  _sandbox_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_name 2>/dev/null) || _sandbox_cluster_name=""
  _sandbox_cluster_location=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_location 2>/dev/null) || _sandbox_cluster_location=""
  _sandbox_namespace=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_namespace 2>/dev/null) || _sandbox_namespace=""
  if [[ -z "$_sandbox_cluster_name" || "$_sandbox_cluster_name" == "null" || -z "$_sandbox_cluster_location" || -z "$_sandbox_namespace" ]]; then
    echo "ERROR: Could not read the sandbox cluster outputs (sandbox_cluster_name, sandbox_cluster_location," >&2
    echo "       sandbox_namespace). Is terraform apply complete with sandbox_runtime_source = external?" >&2
    exit 1
  fi
fi

# Read the domain from the Terraform output, not from terraform.tfvars. That
# file is only one of Terraform's variable sources and not the highest priority
# one, so a file parse misses a value set in an .auto.tfvars file, a
# .tfvars.json file, -var, -var-file or TF_VAR_langsmith_domain. A domain name
# is not a secret. A read failure means the state predates the langsmith_domain
# output, so fall back to the file parse. An empty result from a successful read
# is an answer: no domain is configured, so this is an IP-based install.
if ! _langsmith_domain=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_domain 2>/dev/null); then
  _langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
fi

# The 0.17 layout, a missing or hand-edited values file, or one that make
# init-values wrote for other inputs. init-values.sh bakes the terraform.tfvars
# values into the overrides file and make deploy never regenerates it, so a
# tfvars edit afterward would leave Terraform and Helm deploying different
# configurations. Terraform creates the Gateway listener for langsmith_domain,
# so a hostname written for another domain fails every request.
_values_check "$MODULE_DIR" "$VALUES_DIR" || exit 1
_values_stale=$(_values_resolved_drift "$ENV_FILE" "langsmith_domain=$_langsmith_domain")
if [[ -n "$_values_stale" ]]; then
  echo "ERROR: $_VALUES_OVERRIDES is out of date:" >&2
  printf '         %s\n' "$_values_stale" >&2
  echo "       Run make init-values, then make deploy." >&2
  exit 1
fi

if [[ "$_enable_sandboxes" == "true" ]]; then
  _validate_sandbox_values
fi

if [[ -z "$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname || true)" ]]; then
  echo "ERROR: config.hostname must be set in $_VALUES_OVERRIDES before deploying." >&2
  echo "Run: make init-values" >&2
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

# Here, after kubectl points at this cluster: make init-values asks for the
# external ClickHouse details on its first run only.
_values_clickhouse_secret_check "$NAMESPACE" "$BASE_FILE" "$ENV_FILE" || exit 1

# Chart 0.16 mounted sandbox volumes through a bundled JuiceFS CSI driver, which
# chart 0.17 deletes. If the upgrade removes the driver while those volumes are
# mounted, kubelet can no longer unmount them and the old sandbox-host pods hang in
# Terminating on juicefs.com/finalizer. Draining needs the driver alive, so stop
# here until no JuiceFS claim or mount pod is left. Checked whatever
# enable_sandboxes says: turning the flag off does not remove a running driver.
# Keep identical to the AWS copy.
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

# ── Pre-deploy Gateway IP staleness check ────────────────────────────────────
# If the Envoy Gateway IP has changed since last deploy (e.g. after Gateway
# resource recreation), warn the operator and update the overrides file
# to prevent the Deployments operator from hitting stale endpoints.
#
# This only applies to IP-based installs. When langsmith_domain is set,
# config.hostname must remain the DNS name: Terraform creates the Gateway
# listener with that hostname, so rewriting the chart's hostname to the IP
# leaves no intersection between the HTTPRoute and the listener. The route then
# reports NoMatchingListenerHostname and every request 404s behind an otherwise
# valid TLS certificate. The AWS module already guards this the same way.
# _langsmith_domain is the Terraform output read above: reading terraform.tfvars
# alone would take this branch for a domain set elsewhere and rewrite the
# hostname to the Gateway IP — the exact failure this guard exists to prevent.
_live_gateway_ip=$(kubectl get gateway -n envoy-gateway-system \
  -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)
if [[ -n "$_live_gateway_ip" && -n "$_langsmith_domain" ]]; then
  # Domain-based install: never rewrite the hostname. Surface a DNS mismatch
  # instead, since that is the actual thing an operator needs to fix.
  #
  # Only claim a resolution result when a resolver is actually available —
  # otherwise an absent dig would report "does not resolve yet" for a domain that
  # resolves perfectly well.
  if command -v dig >/dev/null 2>&1; then
    # Compare the whole A-record set against the one Gateway address. Taking a
    # single record instead ties the verdict to the order the resolver happens
    # to return, which rotates: a domain answering with both the Gateway IP and
    # a stale one then passes on some runs and warns on others, and a run that
    # passes hides that part of the traffic never reaches this cluster.
    # Keep only IPv4 literals, since dig prints the CNAME target as well when
    # the name is an alias.
    _resolved_ips=$(dig +short "$_langsmith_domain" A 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$') || _resolved_ips=""
    if [[ -z "$_resolved_ips" ]]; then
      echo "NOTE: ${_langsmith_domain} does not resolve yet."
      echo "      Point its DNS A record at ${_live_gateway_ip} — TLS issuance and"
      echo "      ingress stay pending until it does."
      echo ""
    elif ! printf '%s\n' "$_resolved_ips" | grep -qxF "$_live_gateway_ip"; then
      echo "WARNING: ${_langsmith_domain} resolves to ${_resolved_ips//$'\n'/, }, not the"
      echo "         Gateway IP ${_live_gateway_ip}. Update the DNS A record."
      echo ""
    elif [[ $(printf '%s\n' "$_resolved_ips" | wc -l) -gt 1 ]]; then
      echo "WARNING: ${_langsmith_domain} resolves to ${_resolved_ips//$'\n'/, }."
      echo "         Only ${_live_gateway_ip} is this Gateway. Requests that take one of"
      echo "         the other addresses do not reach it. Remove the stale A records."
      echo ""
    fi
  else
    echo "NOTE: Gateway IP is ${_live_gateway_ip}; config.hostname stays"
    echo "      ${_langsmith_domain}. Install dig to have this checked against DNS."
    echo ""
  fi
elif [[ -n "$_live_gateway_ip" ]]; then
  _configured_hostname=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname) || _configured_hostname=""
  if [[ -n "$_configured_hostname" && "$_configured_hostname" != "$_live_gateway_ip" ]]; then
    _current_url=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config deployment url) || _current_url=""
    _protocol="http"
    [[ "$_current_url" == https://* ]] && _protocol="https"
    echo "WARNING: config.hostname is stale."
    echo "  Configured: $_configured_hostname"
    echo "  Gateway IP: $_live_gateway_ip"
    echo "  Updating $_VALUES_OVERRIDES before deploy..."
    _values_set_strings "$ENV_FILE" "config.hostname=${_live_gateway_ip}" \
      "config.deployment.url=${_protocol}://${_live_gateway_ip}" || exit 1
    # The sandbox runtime reaches the API through the same address.
    if [[ "$_external_sandbox_runtime" == "true" && -f "$SANDBOX_VALUES_FILE" ]]; then
      sed -i.bak "s|endpoint: \"${_protocol}://[^\"/]*/api\"|endpoint: \"${_protocol}://${_live_gateway_ip}/api\"|" "$SANDBOX_VALUES_FILE" && rm -f "$SANDBOX_VALUES_FILE.bak"
    fi
    echo "  Done."
    echo ""
  fi
fi

# ── Values ────────────────────────────────────────────────────────────────────
VALUES_ARGS=(-f "$BASE_FILE" -f "$ENV_FILE")
_sizing_profile=$(_parse_tfvar "sizing_profile")
_sizing_profile="${_sizing_profile:-default}"

echo "Values:"
echo "  ✔ $_VALUES_BASE (base)"
echo "  ✔ $_VALUES_OVERRIDES (sizing_profile = ${_sizing_profile}, and each enabled feature)"
if [[ -f "$VALUES_DIR/$_VALUES_LOCAL" ]]; then
  echo "    with your changes from $_VALUES_LOCAL"
fi
if [[ "$_sizing_profile" == "minimum" ]]; then
  echo ""
  echo "  ⚠️  WARNING: sizing_profile = minimum — NOT for production use."
  echo "     Resources are at the absolute floor. Expect degraded performance"
  echo "     under real workloads. Use sizing_profile = production for production."
  echo ""
fi

# The features: they pick the keys of the langsmith-config Secret and the
# rollouts checked below. Their values are in the overrides file.
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_enable_fleet=false
_enable_standalone_polly=false
_enable_standalone_insights=false
_enable_sandboxes=false
_enable_sso_oidc=false
_tfvar_is_true "enable_deployments"         && _enable_deployments=true
_tfvar_is_true "enable_agent_builder"       && _enable_agent_builder=true
_tfvar_is_true "enable_insights"            && _enable_insights=true
_tfvar_is_true "enable_polly"               && _enable_polly=true
_tfvar_is_true "enable_fleet"               && _enable_fleet=true
_tfvar_is_true "enable_standalone_polly"    && _enable_standalone_polly=true
_tfvar_is_true "enable_standalone_insights" && _enable_standalone_insights=true
_tfvar_is_true "enable_sandboxes"           && _enable_sandboxes=true
_tfvar_is_true "enable_sso_oidc"            && _enable_sso_oidc=true

# Validate legacy addon dependencies (standalone flags do not require enable_deployments).
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_polly" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi

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

# With config.existingSecretName set, the chart reads the OIDC client ID, secret,
# and issuer URL from langsmith-config. Check them first, for a clear message.
# The payload check below covers every key.
if [[ "$_enable_sso_oidc" == "true" ]] && \
   [[ -z "${TF_VAR_langsmith_oauth_client_id:-}" || -z "${TF_VAR_langsmith_oauth_client_secret:-}" || -z "${TF_VAR_langsmith_oauth_issuer_url:-}" ]]; then
  echo "ERROR: enable_sso_oidc = true but OIDC credentials are not set." >&2
  echo "       Run: source infra/scripts/setup-env.sh" >&2
  exit 1
fi

# Build the whole payload before kubectl runs. In a pipe, a failed ${VAR:?} ends
# only the left side, and kubectl apply then replaces langsmith-config with the
# keys printed before the failure.
if ! _langsmith_config_env=$(
  printf 'langsmith_license_key=%s\n' "${TF_VAR_langsmith_license_key:?}"
  printf 'api_key_salt=%s\n' "${TF_VAR_langsmith_api_key_salt:?}"
  printf 'jwt_secret=%s\n' "${TF_VAR_langsmith_jwt_secret:?}"
  printf 'initial_org_admin_password=%s\n' "${TF_VAR_langsmith_admin_password:?}"
  if [[ "$_enable_agent_builder" == "true" || "$_enable_fleet" == "true" ]]; then
    printf 'agent_builder_encryption_key=%s\n' "${TF_VAR_langsmith_agent_builder_encryption_key:?}"
  fi
  if [[ "$_enable_insights" == "true" || "$_enable_standalone_insights" == "true" ]]; then
    printf 'insights_encryption_key=%s\n' "${TF_VAR_langsmith_insights_encryption_key:?}"
  fi
  if [[ "$_enable_polly" == "true" || "$_enable_standalone_polly" == "true" ]]; then
    printf 'polly_encryption_key=%s\n' "${TF_VAR_langsmith_polly_encryption_key:?}"
  fi
  if [[ "$_enable_sandboxes" == "true" ]]; then
    printf 'sandbox_callback_signing_jwk=%s\n' "${TF_VAR_sandbox_callback_signing_jwk:?}"
  fi
  # The dedicated service-auth secret; Terraform writes the same value into the
  # sandbox cluster's runtime Secret.
  if [[ "$_external_sandbox_runtime" == "true" ]]; then
    printf 'sandbox_service_auth_secret=%s\n' "${TF_VAR_sandbox_service_auth_secret:?}"
  fi
  if [[ "$_enable_sso_oidc" == "true" ]]; then
    printf 'oauth_client_id=%s\n' "${TF_VAR_langsmith_oauth_client_id:?}"
    printf 'oauth_client_secret=%s\n' "${TF_VAR_langsmith_oauth_client_secret:?}"
    printf 'oauth_issuer_url=%s\n' "${TF_VAR_langsmith_oauth_issuer_url:?}"
  fi
); then
  echo "ERROR: a langsmith-config value is not set. The Secret was not changed." >&2
  echo "       Run: source infra/scripts/setup-env.sh" >&2
  exit 1
fi
printf '%s\n' "$_langsmith_config_env" | kubectl create secret generic langsmith-config \
  --namespace "$NAMESPACE" \
  --from-env-file=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✔ langsmith-config secret"

echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain

# Guard: pending Helm states (often from interrupted --wait) block upgrades.
# Recover automatically before proceeding, but never uninstall a release that
# has a revision to roll back to: stop and print the rollback instead.
#
# Prints the newest revision a rollback can restore: one Helm counts as good
# (deployed or superseded), or the one an interrupted uninstall left behind.
# Prints nothing when there is none; fails when the history cannot be read or
# holds no revision.
_last_good_revision() {
  local _history
  _history=$(helm history "$RELEASE_NAME" -n "$NAMESPACE" --output json 2>/dev/null) || return 1
  # Every release in these states has a revision. No parsable revision is a read failure.
  grep -q '"revision":[0-9]' <<< "$_history" || return 1
  tr '{' '\n' <<< "$_history" | grep -E '"status":"(deployed|superseded|uninstalling)"' \
    | grep -o '"revision":[0-9]*' | cut -d: -f2 | sort -n | tail -1 || true
}
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
case "$_release_status" in
  pending-upgrade)
    echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in '${_release_status}' state."
    echo "         Rolling back to clear the lock..."
    helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
    echo ""
    ;;
  pending-install|pending-rollback|uninstalling)
    # An uninstall deletes every workload and the revision history, so only a
    # release with nothing to restore (an interrupted first install) is cleared here.
    # A history that cannot be read counts as one with a revision to restore.
    _good_rev=$(_last_good_revision || echo "<revision>")
    if [[ -n "$_good_rev" ]]; then
      echo "ERROR: Helm release '${RELEASE_NAME}' is in '${_release_status}' state." >&2
      echo "       deploy.sh does not uninstall a release that has a revision to restore." >&2
      echo "       Check the history, roll back, then deploy again:" >&2
      echo "         helm history $RELEASE_NAME -n $NAMESPACE --max 5" >&2
      if [[ "$_good_rev" == "<revision>" ]]; then
        echo "       (helm history could not be read, so the revision number is not known.)" >&2
      fi
      echo "         helm rollback $RELEASE_NAME $_good_rev -n $NAMESPACE --wait --timeout 5m" >&2
      echo "         make deploy" >&2
      exit 1
    fi
    echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in '${_release_status}' state."
    echo "         Uninstalling stale release to clear lock before reinstall..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait
    echo ""
    ;;
  failed)
    # A failed first install leaves no revision to upgrade from, and
    # `helm upgrade --install` can then abort with "has no deployed releases".
    # Upgrade in place when a deployed, superseded or uninstalling revision
    # exists, or when the history cannot be read. Clear the record only when no
    # such revision exists.
    if [[ -n "$(_last_good_revision || echo "<revision>")" ]]; then
      echo "WARNING: Prior Helm release '${RELEASE_NAME}' is in 'failed' state."
      echo "         This is commonly a hook timeout and does not always indicate unhealthy workloads."
      echo "         An earlier revision deployed, or helm history could not be read,"
      echo "         so upgrading in place..."
      echo ""
    else
      echo "WARNING: Helm release '${RELEASE_NAME}' failed on its first install, so no"
      echo "         deployed revision exists to upgrade from. Removing the dead release"
      echo "         record so this run can install cleanly..."
      helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait
      echo ""
    fi
    ;;
esac

echo "Deploying LangSmith (sizing: ${_sizing_profile})..."
echo "  (waiting for pods — 5-10 min on a cold cluster while nodes provision)"
echo ""

# --devel is required for pre-release chart versions (any release candidate).
# Helm silently skips any version carrying a semver prerelease component without
# it. Keyed off the prerelease component itself rather than a list of known tags,
# so forms like -rc22 or -alpha-3 are not missed; the part after a + is build
# metadata and never makes a version a prerelease.
_devel_flag=""
if [[ "${CHART_VERSION%%+*}" == *-* ]]; then
  _devel_flag="--devel"
fi

# Resolve the pin to a concrete version and print it. Without this the only place
# the installed version shows up is `helm list`, after the release is already out.
_chart_metadata=$(helm show chart langchain/langsmith --version "$CHART_VERSION" ${_devel_flag:-} 2>/dev/null) || _chart_metadata=""
_resolved_chart=$(awk '/^version:/{print $2}' <<<"$_chart_metadata")
echo "Chart: langchain/langsmith  requested=${CHART_VERSION}  resolved=${_resolved_chart:-UNRESOLVED}"
if [[ -z "$_resolved_chart" ]]; then
  echo "ERROR: no chart matches '$CHART_VERSION' in the langchain repo." >&2
  exit 1
fi

# Chart 0.17 fails the release when images.sandboxHostImage.tag is empty. A tag
# pinned in a file lags every chart upgrade. The old sandbox-host image then runs,
# and the juicefs-format Job uses the same image. So set the tag from the
# appVersion of the resolved chart on every deploy, as the AWS module does.
# --set-string overrides any tag that an older init-values.sh wrote into a file.
# helm upgrade below installs the same resolved version, so the tag matches it.
# With an external runtime this release runs no sandbox-host, and the runtime chart
# runs the image of its own appVersion.
if [[ "$_enable_sandboxes" == "true" && "$_external_sandbox_runtime" != "true" ]]; then
  _sandbox_host_image_tag=$(awk '/^appVersion:/{print $2}' <<<"$_chart_metadata")
  if [[ -z "$_sandbox_host_image_tag" ]]; then
    echo "ERROR: chart $_resolved_chart does not declare an appVersion for the sandbox-host image." >&2
    exit 1
  fi
  VALUES_ARGS+=(--set-string "images.sandboxHostImage.tag=$_sandbox_host_image_tag")
  echo "Sandboxes: sandbox-host image tag=$_sandbox_host_image_tag (chart appVersion)"
  _legacy_sandbox_tag=$(_parse_tfvar "sandbox_host_image_tag") || _legacy_sandbox_tag=""
  if [[ -n "$_legacy_sandbox_tag" && "$_legacy_sandbox_tag" != "$_sandbox_host_image_tag" ]]; then
    echo "  ⚠️  sandbox_host_image_tag = \"$_legacy_sandbox_tag\" in terraform.tfvars is ignored. Remove it."
  fi
fi

# External runtime: the runtime chart pairs with the langsmith chart by
# appVersion, which is the LangSmith release both deploy, never by chart
# version. Install the newest langsmith-sandbox chart with the same appVersion.
# Resolved here, before either release changes, so a missing runtime chart stops
# the deploy instead of leaving the control plane upgraded without a runtime.
# Keep identical to the AWS copy.
_sandbox_chart_version=""
_langsmith_app_version=""
if [[ "$_external_sandbox_runtime" == "true" ]]; then
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

# Moving from the in-cluster runtime: Sandboxes that resume from saved memory
# keep trusting the egress proxy CA they started with, so the external runtime
# keeps the CA the langsmith chart generated. Copy it into the sandbox
# namespace before the upgrade below removes it. The Secret goes straight from
# one cluster to the other and is never printed.
_proxy_ca_secret="smithbox-proxy-ca"
if [[ "$_external_sandbox_runtime" == "true" ]] \
  && kubectl get secret "$_proxy_ca_secret" -n "$NAMESPACE" >/dev/null 2>&1; then
  if ! (
    _sandbox_kubeconfig=$(mktemp)
    trap 'rm -f "$_sandbox_kubeconfig"' EXIT
    KUBECONFIG="$_sandbox_kubeconfig" gcloud container clusters get-credentials "$_sandbox_cluster_name" \
      --region "$_sandbox_cluster_location" --project "$_project_id" >/dev/null || exit 1
    if KUBECONFIG="$_sandbox_kubeconfig" kubectl get secret "$_proxy_ca_secret" -n "$_sandbox_namespace" >/dev/null 2>&1; then
      exit 0
    fi
    if ! KUBECONFIG="$_sandbox_kubeconfig" kubectl get namespace "$_sandbox_namespace" >/dev/null 2>&1; then
      echo "ERROR: namespace $_sandbox_namespace is missing in $_sandbox_cluster_name. Run 'make apply' first." >&2
      exit 1
    fi
    kubectl get secret "$_proxy_ca_secret" -n "$NAMESPACE" -o json \
      | jq --arg ns "$_sandbox_namespace" '{apiVersion, kind, type,
          metadata: {name: .metadata.name, namespace: $ns},
          data: {"tls.crt": .data["tls.crt"], "tls.key": .data["tls.key"]}}' \
      | KUBECONFIG="$_sandbox_kubeconfig" kubectl apply -f - >/dev/null || exit 1
    echo "Copied the in-cluster runtime's proxy CA ($_proxy_ca_secret) into $_sandbox_namespace."
  ); then
    echo "ERROR: could not copy the proxy CA into the sandbox cluster. Nothing was changed; fix the error above and run make deploy again." >&2
    exit 1
  fi
fi

if ! helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --version "$_resolved_chart" \
  ${_devel_flag} \
  "${VALUES_ARGS[@]}" \
  --timeout 20m; then
  echo "ERROR: Helm upgrade failed." >&2
  exit 1
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
# SmithDB pools, which is slower than a normal rollout on a warm cluster.
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
      echo "  ⏳ $dep not ready within 10m (SmithDB nodes may still be provisioning)"
      _all_ready=false
    fi
  done
fi

if [[ "$_enable_sandboxes" == "true" && "$_external_sandbox_runtime" != "true" ]]; then
  # The format Job name carries a hash, so select it by label. It writes to the
  # bucket through the langsmith-sandbox-host Workload Identity binding. Helm
  # does not run a failed Job again when the manifest is unchanged, so a failed
  # Job must be deleted before the next deploy.
  _format_selector="app.kubernetes.io/instance=${RELEASE_NAME},app.kubernetes.io/component=juicefs-format"
  _format_failed=$(kubectl get job -n "$NAMESPACE" -l "$_format_selector" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null) || _format_failed=""
  _format_waited=true
  if [[ "$_format_failed" != *True* ]] \
    && ! kubectl wait --for=condition=complete job -n "$NAMESPACE" -l "$_format_selector" --timeout=5m 2>/dev/null; then
    _format_waited=false
    _format_failed=$(kubectl get job -n "$NAMESPACE" -l "$_format_selector" \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null) || _format_failed=""
  fi
  if [[ "$_format_failed" == *True* ]]; then
    _format_reason=$(kubectl get job -n "$NAMESPACE" -l "$_format_selector" \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Failed")].reason}' 2>/dev/null) || _format_reason=""
    echo "  ✗ The JuiceFS format Job for release ${RELEASE_NAME} failed (${_format_reason:-no reason})."
    case "$_format_reason" in
      *DeadlineExceeded*)
        echo "     The Job did not finish in 300 s. Look for FailedScheduling or a slow image pull:"
        echo "     kubectl describe job -n $NAMESPACE -l $_format_selector"
        ;;
      *)
        echo "     Check the langsmith-sandbox-host Workload Identity binding (run: make apply):"
        echo "     kubectl logs -n $NAMESPACE -l $_format_selector"
        ;;
    esac
    echo "     Then delete the Job and deploy again. Helm creates it again:"
    echo "     kubectl delete job -n $NAMESPACE -l $_format_selector && make deploy"
    _all_ready=false
  elif ! kubectl get job -n "$NAMESPACE" -l "$_format_selector" -o name 2>/dev/null | grep -q .; then
    echo "  ⏳ No JuiceFS format Job found for release ${RELEASE_NAME}."
    _all_ready=false
  elif [[ "$_format_waited" == "false" ]]; then
    echo "  ⏳ The JuiceFS format Job for release ${RELEASE_NAME} is not complete within 5m."
    echo "     kubectl get jobs -n $NAMESPACE -l $_format_selector"
    _all_ready=false
  fi

  # Helm's fullname can include the chart name or an override, so select by the
  # release labels. rollout status exits 0 when nothing matches, so check first.
  _sandbox_host_selector="app.kubernetes.io/instance=${RELEASE_NAME},app=sandbox-host"
  if ! kubectl get deployment -n "$NAMESPACE" -l "$_sandbox_host_selector" -o name 2>/dev/null | grep -q .; then
    echo "  ⏳ No sandbox-host Deployment found for release ${RELEASE_NAME}."
    _all_ready=false
  elif ! kubectl rollout status deployment -n "$NAMESPACE" -l "$_sandbox_host_selector" --timeout=5m 2>/dev/null; then
    echo "  ⏳ sandbox-host for release ${RELEASE_NAME} not ready within 5m (sandbox-host nodes may still be starting)."
    echo "     If JuiceFS does not mount, check the sandbox node bucket grant (run: make apply):"
    echo "     kubectl logs -n $NAMESPACE -l $_sandbox_host_selector -c sandbox-host --tail=50"
    _all_ready=false
  fi
fi

# External runtime: install the runtime after the control plane, the upgrade
# order the charts document (langsmith first, the runtime within 72 hours).
# The sandbox cluster gets a throwaway kubeconfig, so the operator's current
# context stays on the LangSmith cluster. No --wait: hosts drain one at a time,
# so a slow roll is not a failed one, and the checks below only warn.
if [[ "$_external_sandbox_runtime" == "true" ]]; then
  echo ""
  echo "Deploying the sandbox runtime to cluster: $_sandbox_cluster_name (namespace $_sandbox_namespace)"
  echo "Chart: langchain/langsmith-sandbox ${_sandbox_chart_version} (appVersion ${_langsmith_app_version})"
  if ! (
    _sandbox_kubeconfig=$(mktemp)
    trap 'rm -f "$_sandbox_kubeconfig"' EXIT
    export KUBECONFIG="$_sandbox_kubeconfig"
    # set -e does not apply inside a subshell an if tests, so each step that
    # must stop the deploy exits explicitly.
    gcloud container clusters get-credentials "$_sandbox_cluster_name" \
      --region "$_sandbox_cluster_location" --project "$_project_id" >/dev/null || exit 1

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
      --version "$_sandbox_chart_version" \
      ${_devel_flag} \
      -f "$SANDBOX_VALUES_FILE" \
      ${_proxy_ca_args[@]+"${_proxy_ca_args[@]}"} \
      --timeout 20m || exit 1

    # The formatter runs on the host network as the sandbox node service
    # account, which Terraform grants on the JuiceFS bucket.
    _format_selector="app.kubernetes.io/instance=${SANDBOX_RELEASE_NAME},app.kubernetes.io/component=juicefs-format"
    if ! kubectl wait --for=condition=complete job -n "$_sandbox_namespace" -l "$_format_selector" --timeout=10m 2>/dev/null; then
      echo "  ⏳ The JuiceFS format Job is not complete within 10m (sandbox nodes may still be starting)."
      echo "     If it failed, check the sandbox node bucket grant (run: make apply), then delete it and deploy again:"
      echo "     kubectl logs -n $_sandbox_namespace -l $_format_selector"
      echo "     kubectl delete job -n $_sandbox_namespace -l $_format_selector && make deploy"
    fi
    _sandbox_host_selector="app.kubernetes.io/instance=${SANDBOX_RELEASE_NAME},app=sandbox-host"
    if ! kubectl rollout status deployment -n "$_sandbox_namespace" -l "$_sandbox_host_selector" --timeout=15m; then
      echo "  ⏳ sandbox-host is not ready within 15m; sandbox nodes may still be starting."
      echo "     kubectl logs -n $_sandbox_namespace -l $_sandbox_host_selector -c sandbox-host --tail=50"
    fi
  ); then
    echo "ERROR: the langsmith-sandbox release in $_sandbox_cluster_name failed. The control plane is" >&2
    echo "       upgraded; fix the error and run make deploy again within 72 hours." >&2
    exit 1
  fi
  echo "  Sandbox cluster credentials: gcloud container clusters get-credentials $_sandbox_cluster_name --region $_sandbox_cluster_location --project $_project_id"
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
    echo "         In network-disk mode, check the cache volumes: kubectl get pvc -n $NAMESPACE"
  fi
fi

# Chart 0.16 removed the bundled agent-bootstrap Job. Helm no longer owns it, so an
# upgrade from 0.15 strands the old Completed job in the namespace. Deleting it here
# clears that orphan on the first 0.16 deploy and is a no-op on a fresh install.
kubectl delete job -n "$NAMESPACE" "${RELEASE_NAME}-agent-bootstrap" \
  --ignore-not-found=true 2>/dev/null || true

echo ""

# ── Ensure langsmith-ksa carries the Workload Identity annotation ─────────────
# This SA is used by operator-spawned agent deployment pods. It is created by
# the operator on first use and is NOT part of the Helm release, so it does not
# survive namespace teardowns or fresh cluster rebuilds. Without it, new agent
# pod revisions cannot be scheduled.
_wi_annotation=$(terraform -chdir="$INFRA_DIR" output -raw workload_identity_annotation 2>/dev/null || true)
if [[ -n "$_wi_annotation" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    iam.gke.io/gcp-service-account="$_wi_annotation" --overwrite
fi

# ── Post-deploy access info ───────────────────────────────────────────────────
_hostname=$(_values_get "$BASE_FILE" "$ENV_FILE" -- config hostname) || _hostname=""
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
  echo "  ingestion: $_smithdb_ingestion_enabled   query: $_smithdb_query_enabled"
  echo ""
  echo "  Verify the cache mount (Local SSD for local-ssd, a PVC for network-disk):"
  echo "    kubectl exec -n $NAMESPACE deploy/${RELEASE_NAME}-smithdb-query -- df -h /data"
  echo ""
  echo "  Confirm the metastore migration Job completed:"
  echo "    kubectl get job -n $NAMESPACE -l app.kubernetes.io/component=${RELEASE_NAME}-smithdb-metastore-migration"
  echo ""
  if [[ "$_smithdb_ingestion_enabled" == "true" ]]; then
    echo "  Confirm segments are landing in the bucket:"
    echo "    gcloud storage ls gs://\$(terraform -chdir=$INFRA_DIR output -raw smithdb_object_store_bucket)/**"
  else
    echo "  Next stage: set smithdb_ingestion_enabled = true in infra/terraform.tfvars, then make deploy-all"
  fi
fi
