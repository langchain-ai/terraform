#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# init-values.sh — Writes the two Helm values files from Terraform outputs.
#
# Usage (from gcp/):
#   make init-values  (or: ./helm/scripts/init-values.sh)
#
# Reads:
#   - gcp/infra/terraform.tfvars    → project_id, region, name_prefix, environment,
#                                     tls_certificate_source, postgres_source, redis_source,
#                                     clickhouse_source, sizing_profile, the enable_* flags
#   - terraform output              → langsmith_domain, storage_bucket_name, cluster_name,
#                                     workload_identity_annotation, ingress_ip, and the
#                                     SmithDB and sandbox outputs
#   - helm/values/examples/         → the base values, the sizing profile, and each enabled feature
#   - helm/values/langsmith-values-local.yaml → your own changes (optional), merged last
#
# Prompts for the admin email when terraform.tfvars does not set it, and for the
# external ClickHouse connection while the langsmith-clickhouse Secret does not exist.
#
# Writes, on every run:
#   - values/langsmith-values.yaml            (the base, copied from examples/)
#   - values/langsmith-values-overrides.yaml  (everything else, merged into one file:
#                                              Terraform outputs, the sizing profile,
#                                              each enabled feature, SmithDB, and the
#                                              local file)
#   - values/langsmith-sandbox-values-overrides.yaml (langsmith-sandbox chart, if
#                                                     sandbox_runtime_source = external)
#
# make deploy applies langsmith-values.yaml, then langsmith-values-overrides.yaml.
# Neither file holds a secret: deploy.sh writes them into the langsmith-config
# Secret from the TF_VAR_* values that setup-env.sh exports. A re-run rewrites
# both files. No script writes langsmith-values-local.yaml. When a generated file
# was edited by hand, the run stops and prints the change instead.
#
# LANGSMITH_INFRA_DIR and LANGSMITH_VALUES_DIR point the script at another
# terraform.tfvars and values directory. The values tests use them.
#
# This script has to run in its own process. Sourced directly, the `set -euo
# pipefail` below would leak into the caller's shell and stay armed after the
# script finishes, so that shell would then die on the next non-zero command or
# unset variable; and any `exit` here would exit the caller instead, closing an
# interactive terminal outright. Both are silent and easy to misread as a crash.
#
# So when sourced, hand off to a child process and return its status - `source`
# behaves exactly like running it, with the options and exits contained. Keep
# this above `set`, so nothing has changed the caller's shell by this point.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  bash "${BASH_SOURCE[0]}" ${@+"$@"}
  return $?
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
MODULE_DIR="$(cd "$HELM_DIR/.." && pwd)"
INFRA_DIR="${LANGSMITH_INFRA_DIR:-$MODULE_DIR/infra}"
VALUES_DIR="${LANGSMITH_VALUES_DIR:-$HELM_DIR/values}"
EXAMPLES_DIR="$HELM_DIR/values/examples"

# ── tfvars parser ─────────────────────────────────────────────────────────────
# Values are cut at the closing quote, or at an inline # for bare booleans and
# numbers. Without that, `enable_smithdb = true  # step 9` reads as "true#step9"
# and every gate below silently stays off. Keep identical to the other copies.
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
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1")
  [[ "$val" == "true" ]]
}

# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"

# ── Parse terraform.tfvars ────────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $INFRA_DIR/terraform.tfvars" >&2
  echo "Run: cp $INFRA_DIR/terraform.tfvars.example $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is not installed. init-values.sh merges the values files with it." >&2
  exit 1
fi
_values_legacy_stop "$VALUES_DIR" "$EXAMPLES_DIR" || exit 1

# The generated pieces of the overrides file, merged by _values_write below.
_frag_dir=$(mktemp -d)
trap 'rm -rf "$_frag_dir"' EXIT

_project_id=$(_parse_tfvar "project_id")
# Same order Terraform uses: terraform.tfvars, then TF_VAR_*, then the
# variables.tf default. Keep identical across the GCP scripts.
_name_prefix=$(_parse_tfvar "name_prefix")
_name_prefix="${_name_prefix:-${TF_VAR_name_prefix:-ls}}"
_environment=$(_parse_tfvar "environment")
_environment="${_environment:-${TF_VAR_environment:-prod}}"
_region=$(_parse_tfvar "region")
_region="${_region:-us-west2}"
_tls_source=$(_parse_tfvar "tls_certificate_source")
_tls_source="${_tls_source:-none}"
# Resolve the domain through Terraform rather than by parsing terraform.tfvars
# alone. That file is only one of Terraform's variable sources and not the
# highest priority one, so a file parse misses a value set in an .auto.tfvars
# file, a .tfvars.json file, -var, -var-file or TF_VAR_langsmith_domain. Where
# the two disagree, Terraform creates the Gateway listener for its value while
# this script writes the file's value into config.hostname, and every request
# then fails the listener match with NoMatchingListenerHostname. A domain name
# is not a secret.
#
# A read failure means the state predates the langsmith_domain output, so fall
# back to the file parse and keep an older stack working. An empty result from a
# successful read is an answer rather than a failure: no domain is configured.
# A tree with no state also reads empty, and the storage_bucket_name check below
# stops that run regardless.
_domain_source="terraform output"
if ! _domain=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_domain 2>/dev/null); then
  _domain_source="terraform.tfvars"
  _domain=$(_parse_tfvar "langsmith_domain") || _domain=""
fi
_postgres_source=$(_parse_tfvar "postgres_source")
_postgres_source="${_postgres_source:-external}"
_redis_source=$(_parse_tfvar "redis_source")
_redis_source="${_redis_source:-external}"
_clickhouse_source=$(_parse_tfvar "clickhouse_source")
_clickhouse_source="${_clickhouse_source:-in-cluster}"
_sizing_profile=$(_parse_tfvar "sizing_profile")
_sizing_profile="${_sizing_profile:-default}"
_gateway_name="${_name_prefix}-${_environment}-gateway"
_enable_smithdb=false
_tfvar_is_true "enable_smithdb" && _enable_smithdb=true
_smithdb_ingestion_enabled=false
_tfvar_is_true "smithdb_ingestion_enabled" && _smithdb_ingestion_enabled=true
_smithdb_query_enabled=false
_tfvar_is_true "smithdb_query_enabled" && _smithdb_query_enabled=true

if [[ "$_enable_smithdb" != "true" ]] && \
   [[ "$_smithdb_ingestion_enabled" == "true" || "$_smithdb_query_enabled" == "true" ]]; then
  echo "ERROR: SmithDB integration gates require enable_smithdb = true." >&2
  exit 1
fi
if [[ "$_smithdb_ingestion_enabled" != "true" ]] && \
   [[ "$_smithdb_query_enabled" == "true" ]]; then
  echo "ERROR: smithdb_query_enabled requires smithdb_ingestion_enabled = true." >&2
  exit 1
fi

if [[ -z "$_project_id" ]]; then
  echo "ERROR: Could not read project_id from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has it set." >&2
  exit 1
fi

# Derive protocol
if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "existing" ]]; then
  _protocol="https"
else
  _protocol="http"
fi

OUT_FILE="$VALUES_DIR/$_VALUES_OVERRIDES"

echo "Parsed terraform.tfvars:"
echo "  project_id             = $_project_id"
echo "  name_prefix            = $_name_prefix"
echo "  environment            = $_environment"
echo "  region                 = $_region"
echo "  tls_certificate_source = $_tls_source (protocol: $_protocol)"
echo "  langsmith_domain       = ${_domain:-(none)} (from $_domain_source)"
echo "  postgres_source        = $_postgres_source"
echo "  redis_source           = $_redis_source"
echo "  clickhouse_source      = $_clickhouse_source"
echo "  sizing_profile         = $_sizing_profile"
echo "  enable_smithdb         = $_enable_smithdb"
echo ""

# ── Terraform outputs ─────────────────────────────────────────────────────────
echo "Reading Terraform outputs..."

BUCKET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw storage_bucket_name 2>/dev/null) || {
  echo "ERROR: Could not read storage_bucket_name. Is 'terraform apply' complete?" >&2; exit 1
}
CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || {
  echo "ERROR: Could not read cluster_name. Is 'terraform apply' complete?" >&2; exit 1
}
WI_ANNOTATION=$(terraform -chdir="$INFRA_DIR" output -raw workload_identity_annotation 2>/dev/null) || WI_ANNOTATION=""
INGRESS_IP=$(terraform -chdir="$INFRA_DIR" output -raw ingress_ip 2>/dev/null) || INGRESS_IP=""
SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_juicefs_csi_config_secret_name 2>/dev/null) || SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME="juicefs-csi-config"

echo "  storage_bucket_name           = $BUCKET_NAME"
echo "  cluster_name                  = $CLUSTER_NAME"
echo "  workload_identity_annotation  = ${WI_ANNOTATION:-(not available — enable_gcp_iam_module=false?)}"
echo "  ingress_ip                    = ${INGRESS_IP:-(pending — deploy Helm first to get external IP)}"

# SmithDB outputs — only present when enable_smithdb = true.
SMITHDB_BUCKET=""
SMITHDB_GSA=""
SMITHDB_METASTORE_PORT="5432"
SMITHDB_METASTORE_USE_SSL=""
SMITHDB_SECRET_NAME="smithdb-metastore"
SMITHDB_USE_AUTH_PROXY=""
SMITHDB_CONNECTION_NAME=""
SMITHDB_AUTH_PROXY_IMAGE=""
SMITHDB_HELM_VALUES=""
if [[ "$_enable_smithdb" == "true" ]]; then
  SMITHDB_BUCKET=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_object_store_bucket 2>/dev/null) || SMITHDB_BUCKET=""
  SMITHDB_GSA=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_gsa_email 2>/dev/null) || SMITHDB_GSA=""
  SMITHDB_METASTORE_PORT=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_port 2>/dev/null) || SMITHDB_METASTORE_PORT="5432"
  # Terraform resolves the TLS mode from smithdb_metastore_source when the tfvars
  # leave it unset. No fixed fallback here, because it could be the wrong mode.
  SMITHDB_METASTORE_USE_SSL=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_use_ssl 2>/dev/null) || SMITHDB_METASTORE_USE_SSL=""
  SMITHDB_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_secret_name 2>/dev/null) || SMITHDB_SECRET_NAME="smithdb-metastore"
  SMITHDB_USE_AUTH_PROXY=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_use_auth_proxy 2>/dev/null) || SMITHDB_USE_AUTH_PROXY=""
  SMITHDB_CONNECTION_NAME=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_connection_name 2>/dev/null) || SMITHDB_CONNECTION_NAME=""
  SMITHDB_AUTH_PROXY_IMAGE=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_auth_proxy_image 2>/dev/null) || SMITHDB_AUTH_PROXY_IMAGE=""
  SMITHDB_HELM_VALUES=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_helm_values 2>/dev/null) || SMITHDB_HELM_VALUES=""

  echo "  smithdb_object_store_bucket   = ${SMITHDB_BUCKET:-(not available)}"
  echo "  smithdb_gsa_email             = ${SMITHDB_GSA:-(not available)}"
  echo "  smithdb_metastore_port        = $SMITHDB_METASTORE_PORT (useSsl: $SMITHDB_METASTORE_USE_SSL)"
  echo "  smithdb auth proxy            = $SMITHDB_USE_AUTH_PROXY${SMITHDB_CONNECTION_NAME:+ ($SMITHDB_CONNECTION_NAME)}"
  echo "  smithdb gates                 = ingestion:$_smithdb_ingestion_enabled query:$_smithdb_query_enabled"

  if [[ -z "$SMITHDB_BUCKET" || -z "$SMITHDB_GSA" ]]; then
    echo "ERROR: enable_smithdb = true but the SmithDB Terraform outputs are missing." >&2
    echo "       Run 'terraform apply' in infra/ before init-values.sh." >&2
    exit 1
  fi

  if [[ -z "$SMITHDB_HELM_VALUES" || -z "$SMITHDB_USE_AUTH_PROXY" || -z "$SMITHDB_METASTORE_USE_SSL" ]]; then
    echo "ERROR: enable_smithdb = true but smithdb_helm_values or the resolved metastore TLS" >&2
    echo "       outputs are missing. The state is older than this module. Run 'make apply'." >&2
    exit 1
  fi

  # The connection name is the proxy's only positional argument. Without it the
  # sidecar would render with no target and every SmithDB pod would come up with
  # a proxy that exits immediately.
  if [[ "$SMITHDB_USE_AUTH_PROXY" == "true" && -z "$SMITHDB_CONNECTION_NAME" ]]; then
    echo "ERROR: smithdb_metastore_use_auth_proxy = true but smithdb_metastore_connection_name is empty." >&2
    echo "       That output is null for an external metastore. Re-apply infra/, or configure" >&2
    echo "       the proxy sidecar by hand — see the metastore TLS section of SMITHDB.md." >&2
    exit 1
  fi
fi
echo ""

# ── Hostname ──────────────────────────────────────────────────────────────────
# Priority: langsmith_domain > existing overrides file > ingress IP > empty
EXISTING_HOSTNAME=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_HOSTNAME=$(_values_get "$OUT_FILE" -- config hostname) || EXISTING_HOSTNAME=""
fi

if [[ -n "$EXISTING_HOSTNAME" && -n "$_domain" && "$EXISTING_HOSTNAME" != "$_domain" ]]; then
  # Self-heal: Terraform owns the Gateway listener hostname, so a configured
  # langsmith_domain outranks whatever the file holds. Earlier revisions of
  # deploy.sh rewrote the hostname to the Gateway IP unconditionally, and
  # because the existing file outranked the variable the wrong value survived
  # every regeneration.
  #
  # Test for "differs", not for "is an IPv4 literal". A stale DNS name left
  # behind by an earlier langsmith_domain fails the listener match exactly as a
  # bare IP does, and an IPv4-only test preserves it silently.
  echo "Replacing hostname ${EXISTING_HOSTNAME} with langsmith_domain ${_domain}"
  HOSTNAME="$_domain"
elif [[ -n "$EXISTING_HOSTNAME" ]]; then
  HOSTNAME="$EXISTING_HOSTNAME"
elif [[ -n "$_domain" ]]; then
  HOSTNAME="$_domain"
elif [[ -n "$INGRESS_IP" && "$INGRESS_IP" != "pending" && "$INGRESS_IP" != "not installed" ]]; then
  HOSTNAME="$INGRESS_IP"
else
  HOSTNAME=""
fi

# ── Admin email ───────────────────────────────────────────────────────────────
ADMIN_EMAIL=$(_parse_tfvar "langsmith_admin_email") || ADMIN_EMAIL=""
EXISTING_EMAIL=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_EMAIL=$(_values_get "$OUT_FILE" -- config initialOrgAdminEmail) || EXISTING_EMAIL=""
fi

if [[ -n "$ADMIN_EMAIL" ]]; then
  echo "Admin email (from terraform.tfvars): $ADMIN_EMAIL"
elif [[ -n "$EXISTING_EMAIL" ]]; then
  ADMIN_EMAIL="$EXISTING_EMAIL"
  echo "Reusing existing admin email: $ADMIN_EMAIL"
elif [[ -n "${LANGSMITH_ADMIN_EMAIL:-}" ]]; then
  ADMIN_EMAIL="$LANGSMITH_ADMIN_EMAIL"
  echo "Admin email (from LANGSMITH_ADMIN_EMAIL): $ADMIN_EMAIL"
else
  # read returns 1 at EOF and set -euo pipefail aborts there, so a headless run
  # exits 1 with nothing printed. Tolerate the failure and report on the empty
  # value instead. Testing "is there a tty" would be the wrong gate: piped stdin
  # is not a tty either, and `printf ... | init-values.sh` is how a script drives
  # this prompt.
  #
  # Keep whatever read assigned: `|| true`, not `|| ADMIN_EMAIL=""`. read assigns
  # the partial line and then returns 1 when the input has no trailing newline,
  # so clearing the variable on failure discards a value the operator did supply.
  # `printf 'you@example.com' | init-values.sh` is that case. At a true EOF read
  # assigns the empty string, which the check below still catches.
  printf "Admin email: "
  read -r ADMIN_EMAIL || true
  if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "" >&2
    echo "ERROR: Admin email is required." >&2
    echo "       Supply it without a prompt:" >&2
    echo "         export LANGSMITH_ADMIN_EMAIL=you@example.com" >&2
    exit 1
  fi
fi
echo ""

# ── Sizing profile (from terraform.tfvars) ────────────────────────────────────
# sizing_profile is the only input, so a re-run writes the same file and make
# deploy can tell when it changed.
if [[ "$_sizing_profile" != "default" ]]; then
  if [[ ! -f "$EXAMPLES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml" ]]; then
    echo "ERROR: sizing_profile = ${_sizing_profile}, and examples/ has no langsmith-values-sizing-${_sizing_profile}.yaml." >&2
    exit 1
  fi
  echo "Sizing: ${_sizing_profile} (examples/langsmith-values-sizing-${_sizing_profile}.yaml)"
else
  echo "Sizing: the base values (sizing_profile = default)"
fi
echo ""

# ── Product addons (from terraform.tfvars) ────────────────────────────────────
# An unset flag is off. terraform.tfvars is the only input, so a re-run writes the
# same file and make deploy can tell when a flag changed.
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

_sandbox_service_url_base_url=$(_parse_tfvar "sandbox_service_url_base_url") || _sandbox_service_url_base_url=""
_sandbox_runtime_source=$(_parse_tfvar "sandbox_runtime_source") || _sandbox_runtime_source=""
_sandbox_runtime_source="${_sandbox_runtime_source:-in-cluster}"
SANDBOX_CLUSTER_NAME=""
SANDBOX_RUNTIME_SECRET_NAME=""
if [[ "$_enable_sandboxes" == "true" ]]; then
  if [[ "$_sandbox_runtime_source" == "external" ]]; then
    # The sandbox cluster calls ${_protocol}://${HOSTNAME}/api, so the name has
    # to resolve to the Envoy Gateway from inside the VPC. langsmith_domain = ""
    # with an internal gateway uses its private IP.
    if [[ -z "$HOSTNAME" || "$HOSTNAME" == "langsmith.example.com" ]]; then
      echo "ERROR: an external sandbox runtime needs a LangSmith hostname the sandbox cluster can resolve (now: '${HOSTNAME}')." >&2
      echo "       Set langsmith_domain to a name that resolves from the VPC, or set langsmith_domain = \"\"" >&2
      echo "       and run deploy.sh once so the gateway IP is known, then re-run init-values." >&2
      exit 1
    fi
    SANDBOX_CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_name 2>/dev/null) || SANDBOX_CLUSTER_NAME=""
    SANDBOX_RUNTIME_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_runtime_secret_name 2>/dev/null) || SANDBOX_RUNTIME_SECRET_NAME=""
    if [[ -z "$SANDBOX_CLUSTER_NAME" || "$SANDBOX_CLUSTER_NAME" == "null" || -z "$SANDBOX_RUNTIME_SECRET_NAME" || "$SANDBOX_RUNTIME_SECRET_NAME" == "null" ]]; then
      echo "ERROR: Could not read sandbox_cluster_name and sandbox_runtime_secret_name. Is 'terraform apply' complete?" >&2
      exit 1
    fi
  elif [[ -z "$WI_ANNOTATION" ]]; then
    echo "ERROR: enable_sandboxes requires Workload Identity. Set enable_gcp_iam_module = true and re-run terraform apply." >&2
    exit 1
  fi
fi

if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
if [[ "$_enable_polly" == "true" && "$_enable_deployments" != "true" ]]; then
  echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
  exit 1
fi
# Fleet is the standalone successor to Agent Builder. Chart 0.16 removed the
# bundled agent-bootstrap Job, so the two paths can no longer be combined and
# the legacy one has no agent runtime of its own.
if [[ "$_enable_fleet" == "true" && "$_enable_agent_builder" == "true" ]]; then
  echo "ERROR: enable_fleet and enable_agent_builder are mutually exclusive — Fleet replaces the legacy Agent Builder path." >&2
  echo "       Set enable_agent_builder = false in terraform.tfvars." >&2
  exit 1
fi

echo "Product addons (from terraform.tfvars):"
for _addon in "Deployments:$_enable_deployments:enable_deployments" \
  "Agent Builder:$_enable_agent_builder:enable_agent_builder" \
  "Insights:$_enable_insights:enable_insights" \
  "Polly:$_enable_polly:enable_polly" \
  "Fleet:$_enable_fleet:enable_fleet" \
  "Standalone Polly:$_enable_standalone_polly:enable_standalone_polly" \
  "Standalone Insights:$_enable_standalone_insights:enable_standalone_insights"; do
  IFS=: read -r _label _on _flag <<< "$_addon"
  if [[ "$_on" == "true" ]]; then
    echo "  ✔ $_label"
  else
    echo "  ✗ $_label ($_flag = false)"
  fi
done
if [[ "$_enable_sandboxes" == "true" ]]; then
  echo "  ✔ Sandboxes (${_sandbox_runtime_source}; JuiceFS config secret: ${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME})"
else
  echo "  ✗ Sandboxes (enable_sandboxes = false)"
fi

# Insights. In-cluster ClickHouse runs as the chart's StatefulSet (dev/POC only).
# The chart reads every connection field of an external ClickHouse from the
# langsmith-clickhouse Secret, so the values hold only the pointer to it. As on
# 0.17, the details are asked for on the first run only: an earlier overrides
# file or langsmith-values-local.yaml that names the Secret means it was set up,
# and a re-run then needs no cluster. deploy.sh checks that the Secret exists.
if [[ "$_enable_insights" == "true" && "$_clickhouse_source" != "in-cluster" ]]; then
  cat > "$_frag_dir/clickhouse.yaml" <<'CHEOF'
clickhouse:
  external:
    enabled: true
    existingSecretName: "langsmith-clickhouse"
CHEOF
  _ch_ref=""
  for _ch_file in "$VALUES_DIR/$_VALUES_OVERRIDES" "$VALUES_DIR/$_VALUES_LOCAL"; do
    [[ -z "$_ch_ref" && -f "$_ch_file" ]] || continue
    _ch_ref=$(_values_get "$_ch_file" -- clickhouse external existingSecretName 2>/dev/null) || _ch_ref=""
  done
  _ch_state=present
  if [[ -z "$_ch_ref" ]] && ! _ch_state=$(_values_secret_state "${NAMESPACE:-langsmith}" langsmith-clickhouse); then
    echo "ERROR: kubectl could not check namespace ${NAMESPACE:-langsmith} for the Secret langsmith-clickhouse (message above)." >&2
    echo "       Point kubectl at this cluster (make kubeconfig), then re-run make init-values." >&2
    exit 1
  fi
  if [[ "$_ch_state" == missing ]]; then
    if [[ ! -t 0 ]]; then
      echo "ERROR: clickhouse_source = ${_clickhouse_source}, and namespace ${NAMESPACE:-langsmith} has no Secret langsmith-clickhouse." >&2
      echo "       Run make init-values in a terminal to enter the ClickHouse connection details." >&2
      exit 1
    fi
    echo ""
    echo "Insights requires an external ClickHouse instance."
    printf "  ClickHouse host: "
    read -r _ch_host
    if [[ -z "$_ch_host" ]]; then
      echo "ERROR: ClickHouse host is required." >&2
      exit 1
    fi
    printf "  ClickHouse port [8123]: "
    read -r _ch_port
    _ch_port="${_ch_port:-8123}"
    printf "  ClickHouse native port [9000]: "
    read -r _ch_native_port
    _ch_native_port="${_ch_native_port:-9000}"
    if ! [[ "$_ch_port" =~ ^[0-9]+$ && "$_ch_native_port" =~ ^[0-9]+$ ]]; then
      echo "ERROR: ClickHouse ports must be numeric." >&2
      exit 1
    fi
    printf "  ClickHouse database [default]: "
    read -r _ch_db
    _ch_db="${_ch_db:-default}"
    printf "  ClickHouse username [default]: "
    read -r _ch_user
    _ch_user="${_ch_user:-default}"
    printf "  ClickHouse password: "
    read -rs _ch_pass
    echo ""
    printf "  Enable TLS? [Y/n]: "
    read -r _ch_tls
    _ch_tls="${_ch_tls:-Y}"
    [[ "$_ch_tls" =~ ^[Yy] ]] && _ch_tls_val="true" || _ch_tls_val="false"

    # The password goes through a file only its owner can read, never
    # --from-literal: argv is world-readable in the process list for as long
    # as kubectl runs. The EXIT trap removes $_frag_dir and the file.
    _ch_pass_file="$_frag_dir/clickhouse-password"
    (umask 077 && printf '%s' "$_ch_pass" > "$_ch_pass_file")
    unset _ch_pass

    echo ""
    echo "  Creating langsmith-clickhouse K8s Secret..."
    # A failure stops here, before any overrides file names a Secret that the
    # next run would then take as set up.
    if ! kubectl create secret generic langsmith-clickhouse -n "${NAMESPACE:-langsmith}" \
      --from-literal=clickhouse_host="${_ch_host}" \
      --from-literal=clickhouse_port="${_ch_port}" \
      --from-literal=clickhouse_native_port="${_ch_native_port}" \
      --from-literal=clickhouse_user="${_ch_user}" \
      --from-file=clickhouse_password="$_ch_pass_file" \
      --from-literal=clickhouse_db="${_ch_db}" \
      --from-literal=clickhouse_tls="${_ch_tls_val}" \
      --dry-run=client -o yaml | kubectl apply -f -; then
      echo "ERROR: could not create the Secret langsmith-clickhouse in namespace ${NAMESPACE:-langsmith} (message above)." >&2
      echo "       Point kubectl at this cluster (make kubeconfig), then re-run make init-values." >&2
      exit 1
    fi
    echo "  Secret langsmith-clickhouse created/updated."
  fi
fi

# Deployments: the example leaves config.deployment.tlsEnabled false, and the
# operator builds the agent endpoint URLs from it.
if [[ "$_enable_deployments" == "true" && ( "$_tls_source" == "letsencrypt" || "$_tls_source" == "existing" ) ]]; then
  printf 'config:\n  deployment:\n    tlsEnabled: true\n' > "$_frag_dir/agent-deploys-tls.yaml"
fi
echo ""

# ── SmithDB (chart 0.17) ──────────────────────────────────────────────────────
# Three sources, in merge order: the sizing (terraform output
# smithdb_helm_values), the SmithDB example, and the bucket, Workload Identity,
# metastore and gate values from the other Terraform outputs. A later source
# wins, and langsmith-values-local.yaml wins over all three.
if [[ "$_enable_smithdb" == "true" ]]; then
  echo "SmithDB (enable_smithdb = true):"
  # To change the size or cache, set smithdb_sizing or smithdb_cache_storage in
  # infra/terraform.tfvars.
  printf '%s\n' "$SMITHDB_HELM_VALUES" > "$_frag_dir/smithdb-sizing.yaml"

  # Cloud SQL Auth Proxy sidecar. commonInitContainers rather than the
  # per-component deployment.sidecars key: the chart injects this one into every
  # SmithDB Deployment *and* both Jobs, including the metastore-migration
  # pre-install hook, which is the component that would otherwise have no proxy
  # to connect through. restartPolicy: Always makes it a native sidecar, so the
  # kubelet stops it once the Job's main container exits and the hook can
  # actually complete - a plain init container would never return, and a plain
  # sidecar in a Job would hold it Running forever.
  _smithdb_proxy_block=""
  if [[ "$SMITHDB_USE_AUTH_PROXY" == "true" ]]; then
    _smithdb_proxy_block=$(cat << PROXYYAML

  commonInitContainers:
    - name: cloud-sql-proxy
      image: "${SMITHDB_AUTH_PROXY_IMAGE}"
      imagePullPolicy: IfNotPresent
      restartPolicy: Always
      args:
        - "--address=127.0.0.1"
        - "--port=${SMITHDB_METASTORE_PORT}"
        # The proxy dials the instance's PUBLIC IP unless told otherwise, and
        # this module creates the metastore with ipv4_enabled = false. Without
        # this flag the proxy starts, passes its health checks and accepts the
        # local connection, then fails the dial with 'instance does not have IP
        # of type "PUBLIC"' - so the failure surfaces as the SmithDB container
        # getting its connection reset, not as a proxy that would not start.
        - "--private-ip"
        - "--structured-logs"
        - "--health-check"
        - "--http-address=0.0.0.0"
        - "--http-port=9090"
        - "${SMITHDB_CONNECTION_NAME}"
      ports:
        - name: proxy-health
          containerPort: 9090
          protocol: TCP
      startupProbe:
        httpGet:
          path: /startup
          port: proxy-health
        failureThreshold: 30
        periodSeconds: 2
        timeoutSeconds: 1
      readinessProbe:
        httpGet:
          path: /readiness
          port: proxy-health
        periodSeconds: 10
        timeoutSeconds: 1
      livenessProbe:
        httpGet:
          path: /liveness
          port: proxy-health
        periodSeconds: 10
        timeoutSeconds: 1
      # A native sidecar's requests are added to the Pod total rather than
      # merged into the init-container maximum, so the scheduler counts them
      # once per SmithDB Pod.
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
PROXYYAML
    )
  fi

  # The integration gates come from infra/terraform.tfvars. Change them there,
  # and keep ClickHouse enabled throughout.
  #
  # The metastore-migration hook Job inherits useSsl. The chart builds its env
  # from the shared smithdb.serviceEnv helper, which reads
  # config.metastore.useSsl for METASTORE__USE_SSL on every component, the Job
  # included, so no separate metastoreMigration.useSsl leaf is needed - the chart
  # does not read one.
  cat > "$_frag_dir/smithdb-overrides.yaml" << SMITHDBYAML
smithdb:
  serviceAccount:
    annotations:
      # Workload Identity — binds the chart's SmithDB service account to the
      # dedicated GCP service account that holds objectAdmin on the bucket below.
      iam.gke.io/gcp-service-account: "${SMITHDB_GSA}"
${_smithdb_proxy_block}
  config:
    existingSecretName: "${SMITHDB_SECRET_NAME}"
    objectStore:
      type: "gcs"
      bucket: "${SMITHDB_BUCKET}"
    metastore:
      # Field-to-key mapping for the Terraform-created Kubernetes secret.
      hostSecretKey: "smithdb_metastore_db_host"
      databaseSecretKey: "smithdb_metastore_db_name"
      usernameSecretKey: "smithdb_metastore_db_username"
      passwordSecretKey: "smithdb_metastore_db_password"
      # hostSecretKey resolves to 127.0.0.1 when the Auth Proxy is on, so the
      # same mapping covers both modes.
      port: "${SMITHDB_METASTORE_PORT}"
      useSsl: ${SMITHDB_METASTORE_USE_SSL}
  langsmith:
    ingestion:
      enabled: ${_smithdb_ingestion_enabled}
    query:
      enabled: ${_smithdb_query_enabled}
SMITHDBYAML
  echo "  ✔ SmithDB sizing, bucket, Workload Identity, metastore and gates (Terraform outputs)"
  echo ""
fi

# ── In-cluster postgres/redis overrides ───────────────────────────────────────
# The base values name the Secrets that k8s-bootstrap creates for Cloud SQL and
# Memorystore. k8s-bootstrap creates them only for external services. The chart
# uses existingSecretName whenever it is set, so clear it here, and the chart
# creates its own in-cluster Secret.
_external_services_block=""
if [[ "$_postgres_source" == "in-cluster" ]]; then
  _external_services_block+="
postgres:
  external:
    enabled: false
    existingSecretName: \"\""
fi
if [[ "$_redis_source" == "in-cluster" ]]; then
  _external_services_block+="
redis:
  external:
    enabled: false
    existingSecretName: \"\""
fi

# ── Sandboxes ─────────────────────────────────────────────────────────────────
# The callback signing key is not written here: the chart reads it from the
# langsmith-config Secret (sandbox_callback_signing_jwk), which deploy.sh writes.
_sandbox_config_block=""
_sandbox_service_url_block=""
if [[ "$_enable_sandboxes" == "true" && -n "$_sandbox_service_url_base_url" ]]; then
  _sandbox_service_url_block="
  serviceUrlBaseUrl: \"${_sandbox_service_url_base_url}\""
fi
if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  # The control plane stays here; the langsmith-sandbox chart runs sandbox-host
  # in the sandbox cluster. The sandbox cluster runs untrusted code, so sandbox
  # service auth uses a dedicated key in langsmith-config (deploy.sh writes it
  # from Secret Manager), never api_key_salt. Terraform writes the same value
  # into the runtime Secret.
  _sandbox_config_block="
sandboxes:
  enabled: true
  external:
    enabled: true${_sandbox_service_url_block}
  serviceAuth:
    secretKey: \"sandbox_service_auth_secret\""
elif [[ "$_enable_sandboxes" == "true" ]]; then
  # The chart's JuiceFS format Job runs under the sandbox-host ServiceAccount, so
  # the Workload Identity annotation goes on sandboxHost. infra binds
  # langsmith-sandbox-host to the LangSmith GSA. sandbox-host itself runs on the
  # host network, gets the node service account instead, and mounts JuiceFS
  # through the bucket grant that infra gives that account.
  # images.sandboxHostImage.tag is not written here: deploy.sh sets it from the
  # appVersion of the chart it resolves, so it cannot lag a chart upgrade.
  # safe-to-evict=false stops the cluster autoscaler from removing a node that
  # runs sandbox-host (and its sandbox VMs) to consolidate the pool.
  # The format Job needs no KVM and no host path, and its deadline is 300 s. The
  # sandbox-host pool can be at 0 nodes. So the Job prefers a sandbox node, but
  # it can also run on any Linux node and does not wait for a new node to boot.
  _sandbox_config_block="
sandboxes:
  enabled: true${_sandbox_service_url_block}
  juicefs:
    existingSecretName: \"${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}\"
  sandboxHost:
    deployment:
      nodeSelector:
        sandbox.langsmith.com/host: \"true\"
      podAnnotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: \"false\"
    serviceAccount:
      annotations:
        iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
  juicefsFormatJob:
    nodeSelector:
      kubernetes.io/os: linux
    affinity:
      nodeAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: sandbox.langsmith.com/host
                  operator: In
                  values: [\"true\"]"
fi

# ── SSO/OIDC login (optional) ─────────────────────────────────────────────────
# WARNING: enable only after the initial install has completed with basic auth
# and you've confirmed org-admin access — flipping this on before an admin
# account exists locks you out of the UI. The chart reads the client ID, secret
# and issuer URL from the langsmith-config Secret, which deploy.sh writes.
_auth_block=""
if [[ "$_enable_sso_oidc" == "true" ]]; then
  _auth_block="
  basicAuth:
    enabled: false
  oauth:
    enabled: true"
fi

# ── Agent defaults ────────────────────────────────────────────────────────────
# Chart 0.16 ships insights.enabled and polly.enabled as true. Without an explicit
# false a base install grows two agent deployments nobody asked for. Make the
# terraform enable_* flags authoritative. The feature examples merge after the
# core values, so an enabled feature still turns itself on.
_agent_defaults_block=""
if [[ "$_enable_insights" != "true" && "$_enable_standalone_insights" != "true" ]]; then
  _agent_defaults_block+="
insights:
  enabled: false"
fi
if [[ "$_enable_polly" != "true" && "$_enable_standalone_polly" != "true" ]]; then
  _agent_defaults_block+="
polly:
  enabled: false"
fi

# ── Workload Identity annotation block ────────────────────────────────────────
# langsmith-ksa, the account of the agent deployment pods the operator creates,
# is not part of the release: deploy.sh annotates it after each deploy.
_wi_block=""
if [[ -n "$WI_ANNOTATION" ]]; then
  _wi_block="
platformBackend:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
backend:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
queue:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
ingestQueue:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
hostBackend:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
listener:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
operator:
  serviceAccount:
    annotations:
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\""
fi

# ── The core of langsmith-values-overrides.yaml ───────────────────────────────
# GCS blob storage: LangSmith accesses GCS natively (the base values set engine
# GCS), with Workload Identity, so no access keys are written.
cat > "$_frag_dir/core.yaml" << YAML
config:
  hostname: "${HOSTNAME}"
  initialOrgAdminEmail: "${ADMIN_EMAIL}"${_auth_block}
  deployment:
    # URL used by the operator to build agent deployment endpoints.
    # Must match config.hostname with correct protocol — wrong value keeps
    # deployments stuck in DEPLOYING state.
    url: "${_protocol}://${HOSTNAME}"
  blobStorage:
    bucketName: "${BUCKET_NAME}"
    region: "${_region}"
    apiURL: "https://storage.googleapis.com"
    s3UsePathStyle: false
${_sandbox_config_block}

gateway:
  name: "${_gateway_name}"
  namespace: "envoy-gateway-system"
${_wi_block}
${_external_services_block}
${_agent_defaults_block}
YAML

if [[ "$_enable_sandboxes" == "true" && "$_sandbox_runtime_source" == "external" ]]; then
  # No secrets in this file: Terraform writes both Secrets it names into the
  # sandbox cluster. Its keys are the chart defaults, spelled out because the
  # Secret depends on them. Copied to helm/values once the two values files are
  # written.
  cat > "$_frag_dir/sandbox-runtime.yaml" << YAML
# Auto-generated by init-values.sh for the dedicated sandbox cluster
# (${SANDBOX_CLUSTER_NAME}). deploy.sh installs the langsmith-sandbox chart with it.
# Both Secret values match the same keys in langsmith-config; neither is the
# API key salt.
config:
  endpoint: "${_protocol}://${HOSTNAME}/api"
  existingSecretName: "${SANDBOX_RUNTIME_SECRET_NAME}"
  callbackSigningJwkSecretKey: "sandbox_callback_signing_jwk"
serviceAuth:
  secretKey: "sandbox_service_auth_secret"

# sandbox-host runs on the host network, where GKE Workload Identity does not
# apply, so it uses the sandbox node service account. provider gcp moves the
# JuiceFS formatter onto the host network too, so one bucket grant (made by
# Terraform on the JuiceFS-only bucket) covers both pods.
workloadIdentity:
  provider: gcp

juicefs:
  existingSecretName: "${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}"

sandboxHost:
  enabled: true
  deployment:
    nodeSelector:
      sandbox.langsmith.com/host: "true"
    # Keeps the cluster autoscaler from removing a node that runs sandbox-host
    # (and its sandbox VMs) to consolidate the pool.
    podAnnotations:
      cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
YAML
fi

# ── Merge everything into langsmith-values-overrides.yaml ─────────────────────
# The sources merge in the order deploy.sh layered them on 0.17, after the base
# values, so a later one wins. The sizing profile comes before the feature
# examples, so a feature's own resources win over the profile. The local file is
# the last file. hostBackend.enabled applies after every file while Fleet is on,
# because Fleet's OAuth endpoints live in host-backend.
_values_plan_reset
_values_plan_file generated "$_frag_dir/core.yaml" "core values from Terraform outputs: hostname, admin email, GCS, Gateway, Workload Identity, sandboxes, databases"
if [[ "$_sizing_profile" != "default" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
fi
if [[ "$_enable_deployments" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml"
  if [[ -f "$_frag_dir/agent-deploys-tls.yaml" ]]; then
    _values_plan_file generated "$_frag_dir/agent-deploys-tls.yaml" "config.deployment.tlsEnabled from tls_certificate_source"
  fi
fi
if [[ "$_enable_agent_builder" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-agent-builder.yaml"
fi
if [[ "$_enable_insights" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-insights.yaml"
  if [[ -f "$_frag_dir/clickhouse.yaml" ]]; then
    _values_plan_file generated "$_frag_dir/clickhouse.yaml" "the pointer to the langsmith-clickhouse Secret (clickhouse_source = ${_clickhouse_source})"
  fi
fi
for _addon in polly:"$_enable_polly" fleet:"$_enable_fleet" \
  standalone-polly:"$_enable_standalone_polly" standalone-insights:"$_enable_standalone_insights"; do
  if [[ "${_addon#*:}" == "true" ]]; then
    _values_plan_file example "$EXAMPLES_DIR/langsmith-values-${_addon%%:*}.yaml"
  fi
done
if [[ "$_enable_smithdb" == "true" ]]; then
  _values_plan_file generated "$_frag_dir/smithdb-sizing.yaml" "SmithDB sizing from terraform output smithdb_helm_values"
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-smithdb.yaml"
  _values_plan_file generated "$_frag_dir/smithdb-overrides.yaml" "SmithDB bucket, Workload Identity, metastore and gates from Terraform outputs"
fi
_values_plan_local "$VALUES_DIR"
if [[ "$_enable_fleet" == "true" ]]; then
  _values_plan_set --set "hostBackend.enabled=true"
fi

# Recorded in the header, so make deploy stops when one of them changes.
_values_plan_tfvars project_id name_prefix environment region tls_certificate_source \
  langsmith_domain postgres_source redis_source clickhouse_source sizing_profile \
  langsmith_admin_email enable_deployments enable_agent_builder enable_insights \
  enable_polly enable_fleet enable_standalone_polly enable_standalone_insights \
  enable_sandboxes enable_sso_oidc enable_smithdb smithdb_ingestion_enabled \
  smithdb_query_enabled sandbox_runtime_source sandbox_service_url_base_url
_values_plan_resolved langsmith_domain "$_domain"
_values_plan_script "$MODULE_DIR" helm/scripts/init-values.sh helm/scripts/_values.sh

_values_write "$VALUES_DIR" "$EXAMPLES_DIR" || exit 1
echo "Written: $VALUES_DIR/$_VALUES_BASE (the base values, from examples/)"
echo "Written: $OUT_FILE"
if [[ -f "$VALUES_DIR/$_VALUES_LOCAL" ]]; then
  echo "  with your changes from $_VALUES_LOCAL"
fi
if [[ -f "$_frag_dir/sandbox-runtime.yaml" ]]; then
  SANDBOX_VALUES_FILE="$VALUES_DIR/langsmith-sandbox-values-overrides.yaml"
  cp "$_frag_dir/sandbox-runtime.yaml" "$SANDBOX_VALUES_FILE"
  echo "Written: $SANDBOX_VALUES_FILE (sandbox cluster: $SANDBOX_CLUSTER_NAME)"
fi

if [[ -z "$HOSTNAME" ]]; then
  echo ""
  echo "WARNING: hostname is empty. Run again after the Envoy Gateway has an external IP:"
  echo "  kubectl get gateway -n envoy-gateway-system -o jsonpath='{.items[0].status.addresses[0].value}'"
  echo "  Then set langsmith_domain in terraform.tfvars and re-run this script."
fi
echo ""
echo "Next step: make deploy"
