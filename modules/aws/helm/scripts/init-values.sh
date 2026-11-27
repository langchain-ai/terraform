#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# init-values.sh — Writes the two Helm values files from Terraform outputs.
#
# Usage (from aws/):
#   make init-values  (or: ./helm/scripts/init-values.sh)
#
# Reads:
#   - aws/infra/terraform.tfvars    → name_prefix, environment, region, tls_certificate_source,
#                                     and the enable_* flags
#   - terraform output              → bucket_name, langsmith_irsa_role_arn, alb outputs,
#                                     engine_irsa_role_arn, and the SmithDB and sandbox outputs
#   - helm/values/examples/         → the base values and the values of each enabled feature
#   - helm/values/langsmith-values-local.yaml → your own changes (optional), merged last
#
# Falls back to prompting for the admin email when it is not in Terraform.
#
# Writes, on every run:
#   - values/langsmith-values.yaml            (the base, copied from examples/)
#   - values/langsmith-values-overrides.yaml  (everything else, merged into one file:
#                                              Terraform outputs, each enabled feature,
#                                              SSO, SmithDB, and the local file)
#   - values/langsmith-sandbox-values-overrides.yaml (langsmith-sandbox chart, if
#                                                     sandbox_runtime_source = external)
#
# make deploy applies langsmith-values.yaml, then langsmith-values-overrides.yaml.
# Neither file holds a secret: ESO syncs the secrets from SSM into langsmith-config.
# A re-run rewrites both files. No script writes langsmith-values-local.yaml. When a
# generated file was edited by hand, the run stops and prints the change instead.
#
# LANGSMITH_INFRA_DIR and LANGSMITH_VALUES_DIR point the script at another
# terraform.tfvars and values directory. The values tests use them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
MODULE_DIR="$(cd "$HELM_DIR/.." && pwd)"
INFRA_DIR="${LANGSMITH_INFRA_DIR:-$MODULE_DIR/infra}"
VALUES_DIR="${LANGSMITH_VALUES_DIR:-$HELM_DIR/values}"
EXAMPLES_DIR="$HELM_DIR/values/examples"
source "$MODULE_DIR/infra/scripts/_common.sh"
source "$MODULE_DIR/infra/scripts/_smithdb.sh"
# shellcheck source=_values.sh
source "$SCRIPT_DIR/_values.sh"
# shellcheck source=_addon-storage.sh
source "$SCRIPT_DIR/_addon-storage.sh"

# ── Parse terraform.tfvars ────────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $INFRA_DIR/terraform.tfvars" >&2
  echo "Run: cp $INFRA_DIR/terraform.tfvars.example $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

_stop_if_nginx_applied || exit 1

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm is not installed. init-values.sh merges the values files with it." >&2
  exit 1
fi
_values_legacy_stop "$VALUES_DIR" "$EXAMPLES_DIR" || exit 1

# The generated pieces of the overrides file, merged by _values_write at the end.
_frag_dir=$(mktemp -d)
trap 'rm -rf "$_frag_dir"' EXIT

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
_acm_arn=$(_parse_tfvar "acm_certificate_arn") || _acm_arn=""
_alb_scheme=$(_parse_tfvar "alb_scheme") || _alb_scheme="internet-facing"
_clickhouse_source=$(_parse_tfvar "clickhouse_source") || _clickhouse_source="in-cluster"
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_sandbox_runtime_source=$(_parse_tfvar "sandbox_runtime_source") || _sandbox_runtime_source="in-cluster"
# Gateway mode comes from the Terraform outputs, not the tfvars text: enable_envoy_gateway
# is derived (unset = on unless Istio was chosen), so a tfvars that never mentions
# Envoy still deploys it. Reading the applied state keeps this script in agreement with
# what Terraform actually built.
_enable_envoy_gateway=$(_read_applied_flag "enable_envoy_gateway" false)
_enable_istio_gateway=$(_read_applied_flag "enable_istio_gateway" false)

# The defaults match variables.tf, for a run before the first apply.
_enable_smithdb=$(_read_applied_flag "enable_smithdb" true)
_smithdb_ingestion_enabled=$(_read_applied_flag "smithdb_ingestion_enabled" true)
_smithdb_query_enabled=$(_read_applied_flag "smithdb_query_enabled" true)
_smithdb_metastore_use_ssl=$(_parse_tfvar "smithdb_metastore_use_ssl") || _smithdb_metastore_use_ssl="true"

# The gates default to true and count only with SmithDB on (as in outputs.tf).
if [[ "$_enable_smithdb" != "true" ]]; then
  _smithdb_ingestion_enabled=false; _smithdb_query_enabled=false
fi
if [[ "$_smithdb_ingestion_enabled" != "true" && "$_smithdb_query_enabled" == "true" ]]; then
  echo "ERROR: SmithDB queries require smithdb_ingestion_enabled = true." >&2
  exit 1
fi
# upgrade-guard.sh covers only make apply, and an unset query gate defaults to on,
# so confirm it against the live release before writing it.
if [[ "$_smithdb_query_enabled" == "true" ]] && ! _tfvar_is_true "smithdb_query_enabled"; then
  _tf_release_name=$(_parse_tfvar "langsmith_release_name") || _tf_release_name="langsmith"
  _tf_namespace=$(_parse_tfvar "langsmith_namespace") || _tf_namespace="langsmith"
  _smithdb_query_cutover_check "${RELEASE_NAME:-$_tf_release_name}" "${NAMESPACE:-$_tf_namespace}" || exit 1
fi

_gateway_modes=0
[[ "$_enable_envoy_gateway" == "true" ]] && _gateway_modes=$(( _gateway_modes + 1 )) || true
[[ "$_enable_istio_gateway" == "true" ]] && _gateway_modes=$(( _gateway_modes + 1 )) || true
if (( _gateway_modes > 1 )); then
  echo "ERROR: Only one of enable_envoy_gateway / enable_istio_gateway can be true." >&2
  echo "       Envoy Gateway is the default when enable_envoy_gateway is unset — set it to false explicitly in terraform.tfvars to run Istio, then re-apply." >&2
  exit 1
fi

# Classic ALB Ingress mode = none of the gateway routing modes enabled.
# In that mode the AWS Load Balancer Controller creates and owns the ALB.
_alb_ingress_mode=false
(( _gateway_modes == 0 )) && _alb_ingress_mode=true

if [[ -z "$_name_prefix" || -z "$_environment" || -z "$_region" ]]; then
  echo "ERROR: Could not read name_prefix, environment, and/or region from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has these values set." >&2
  exit 1
fi

# Derive protocol for config.deployment.url
if [[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]]; then
  _protocol="https"
else
  _protocol="http"
fi

OUT_FILE="$VALUES_DIR/$_VALUES_OVERRIDES"
SANDBOX_VALUES_FILE="$VALUES_DIR/langsmith-sandbox-values-overrides.yaml"

echo "Parsed terraform.tfvars:"
echo "  name_prefix            = ${_name_prefix:-(empty)}"
echo "  environment            = $_environment"
echo "  region                 = $_region"
echo "  tls_certificate_source = $_tls_source (protocol: $_protocol)"
echo "  sandbox_runtime_source = $_sandbox_runtime_source"
echo ""

# ── Terraform outputs ─────────────────────────────────────────────────────────
echo "Reading Terraform outputs..."

BUCKET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw bucket_name 2>/dev/null) || {
  echo "ERROR: Could not read bucket_name. Is 'terraform apply' complete?" >&2; exit 1
}
IRSA_ROLE_ARN=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_irsa_role_arn 2>/dev/null) || {
  echo "ERROR: Could not read langsmith_irsa_role_arn. Is 'terraform apply' complete?" >&2; exit 1
}
ALB_ARN=$(terraform -chdir="$INFRA_DIR" output -raw alb_arn 2>/dev/null) || ALB_ARN=""
ALB_DNS_NAME=$(terraform -chdir="$INFRA_DIR" output -raw alb_dns_name 2>/dev/null) || ALB_DNS_NAME=""
ALB_SCHEME=$(terraform -chdir="$INFRA_DIR" output -raw alb_scheme 2>/dev/null) || ALB_SCHEME="$_alb_scheme"
ACM_CERT_ARN=$(terraform -chdir="$INFRA_DIR" output -raw acm_certificate_arn 2>/dev/null) || ACM_CERT_ARN=""
# Fallback to tfvars if the output isn't available (older infra module)
if [[ -z "$ACM_CERT_ARN" && -n "$_acm_arn" ]]; then
  ACM_CERT_ARN="$_acm_arn"
fi

echo "  bucket_name            = $BUCKET_NAME"
echo "  langsmith_irsa_role_arn = $IRSA_ROLE_ARN"
echo "  alb_arn                = ${ALB_ARN:-(not provisioned)}"
echo "  alb_dns_name           = ${ALB_DNS_NAME:-(not provisioned)}"
echo "  alb_scheme             = $ALB_SCHEME"
echo "  acm_certificate_arn    = ${ACM_CERT_ARN:-(not set)}"
echo ""

# ── Hostname ──────────────────────────────────────────────────────────────────
# Hostname priority: custom domain > existing value > entry-ALB hostname.
# The entry-ALB hostname depends on the routing mode:
#   - Classic ALB Ingress mode: the AWS Load Balancer Controller creates and owns
#     the ALB; its DNS name is only known from the Ingress status after the Ingress
#     is reconciled. Do NOT use the Terraform alb_dns_name here — that is a
#     separate, unused ALB in this mode, and pointing at it strands all routing.
#     On first run the Ingress doesn't exist yet, so this resolves to blank and
#     deploy.sh patches config.hostname/deployment.url once the controller
#     provisions the ALB.
#   - Envoy / Istio modes: the Terraform-provisioned ALB is the entry
#     point (it fronts the in-cluster controller/gateway via a TargetGroupBinding).
_ingress_alb_hostname() {
  kubectl get ingress langsmith-ingress -n "${NAMESPACE:-langsmith}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

EXISTING_HOSTNAME=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_HOSTNAME=$(_values_get "$OUT_FILE" -- config hostname) || EXISTING_HOSTNAME=""
  # HOSTNAME must stay bare: the output block writes "${_protocol}://${HOSTNAME}",
  # so reusing the stored value verbatim prepends a second scheme on every re-run
  # ("http://http://alb..."), which breaks OAuth redirects and deployment URLs.
  # Loop rather than strip once so an already-corrupted file self-heals.
  while [[ "$EXISTING_HOSTNAME" =~ ^https?:// ]]; do
    EXISTING_HOSTNAME="${EXISTING_HOSTNAME#http://}"
    EXISTING_HOSTNAME="${EXISTING_HOSTNAME#https://}"
  done
fi
if [[ -n "$_langsmith_domain" ]]; then
  HOSTNAME="$_langsmith_domain"
elif [[ -n "$EXISTING_HOSTNAME" ]]; then
  HOSTNAME="$EXISTING_HOSTNAME"
elif [[ "$_alb_ingress_mode" == "true" ]]; then
  HOSTNAME="$(_ingress_alb_hostname)"
elif [[ -n "$ALB_DNS_NAME" ]]; then
  HOSTNAME="$ALB_DNS_NAME"
else
  HOSTNAME=""
fi
# Strip any scheme — it's re-added below via ${_protocol}, and reusing an
# already-generated hostname verbatim (which includes one) would double it.
HOSTNAME="${HOSTNAME#http://}"
HOSTNAME="${HOSTNAME#https://}"

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
elif [[ -t 0 ]]; then
  # Interactive terminal — prompt
  printf "Admin email: "
  read -r ADMIN_EMAIL
  if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: Admin email is required." >&2
    exit 1
  fi
else
  echo "ERROR: Admin email is required. Set LANGSMITH_ADMIN_EMAIL env var or re-run interactively." >&2
  exit 1
fi
echo ""

# ── Product addons (driven by enable_* flags in terraform.tfvars) ────────────
_enable_deployments=false
_enable_insights=false
_enable_polly=false
_enable_usage_telemetry=false
_enable_fleet=false
_enable_sandboxes=false
_enable_engine=false
_enable_sso_oidc=false
_enable_llm_gateway=false
_enable_gateway_pii_redaction=false
_tfvar_is_true "enable_deployments"    && _enable_deployments=true
_tfvar_is_true "enable_insights"       && _enable_insights=true
_tfvar_is_true "enable_polly"          && _enable_polly=true
_tfvar_is_true "enable_usage_telemetry" && _enable_usage_telemetry=true
_tfvar_is_true "enable_fleet"               && _enable_fleet=true
_tfvar_is_true "enable_sandboxes"           && _enable_sandboxes=true
_tfvar_is_true "enable_engine"              && _enable_engine=true
_tfvar_is_true "enable_sso_oidc"            && _enable_sso_oidc=true
_tfvar_is_true "enable_llm_gateway"         && _enable_llm_gateway=true
_tfvar_is_true "enable_gateway_pii_redaction" && _enable_gateway_pii_redaction=true

# Engine runs every analysis in a sandbox, and the chart rejects Engine without them.
if [[ "$_enable_engine" == "true" && "$_enable_sandboxes" != "true" ]]; then
  echo "ERROR: enable_engine requires enable_sandboxes = true in terraform.tfvars." >&2
  exit 1
fi

# Presidio only serves the gateway. Terraform's validation refuses the same pair.
if [[ "$_enable_gateway_pii_redaction" == "true" && "$_enable_llm_gateway" != "true" ]]; then
  echo "ERROR: enable_gateway_pii_redaction requires enable_llm_gateway = true in terraform.tfvars." >&2
  exit 1
fi

# Fail fast rather than let this surface later as a CreateContainerConfigError.
# apply-eso.sh gates the whole oauth block (client id/secret/issuer url) behind
# a single existence check on oauth-client-secret and silently skips syncing
# any of them if it's missing — but the SSO values file disables basicAuth
# whenever enable_sso_oidc is true, regardless of SSM state. With
# no admin login path and secretKeyRef optional: false on the missing key,
# backend/platformBackend would otherwise just fail to start with no message
# pointing back at the actual cause.
if [[ "$_enable_sso_oidc" == "true" ]]; then
  _sso_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"
  _sso_timeout_bin=""
  for _t in timeout gtimeout; do
    if command -v "$_t" >/dev/null 2>&1; then _sso_timeout_bin="$_t"; break; fi
  done
  _sso_check() {
    if [[ -n "$_sso_timeout_bin" ]]; then
      "$_sso_timeout_bin" 10 aws ssm get-parameter --region "$_region" --name "$1" --query Parameter.Name --output text >/dev/null 2>&1
    else
      aws ssm get-parameter --region "$_region" --name "$1" --query Parameter.Name --output text >/dev/null 2>&1
    fi
  }
  _sso_missing=""
  for _key in oauth-client-id oauth-client-secret oauth-issuer-url; do
    _sso_check "${_sso_ssm_prefix}/${_key}" || _sso_missing="$_sso_missing ${_sso_ssm_prefix}/${_key}"
  done
  if [[ -n "$_sso_missing" ]]; then
    echo "ERROR: enable_sso_oidc = true but the following SSM parameters are missing:" >&2
    for _m in $_sso_missing; do echo "         $_m" >&2; done
    echo "" >&2
    echo "       basicAuth is disabled the moment this flag is on, so without these," >&2
    echo "       backend/platformBackend would fail to start (CreateContainerConfigError)" >&2
    echo "       instead of failing here with a clear reason." >&2
    echo "" >&2
    echo "       Populate all three, then re-run:" >&2
    echo "         ./infra/scripts/manage-ssm.sh set oauth-client-id '<value>'" >&2
    echo "         ./infra/scripts/manage-ssm.sh set oauth-client-secret '<value>'" >&2
    echo "         ./infra/scripts/manage-ssm.sh set oauth-issuer-url '<value>'" >&2
    exit 1
  fi
fi

[[ "$_enable_sso_oidc" != "true" ]] || echo "  ✔ SSO login (examples/langsmith-values-sso.yaml)"

_sandbox_service_url_base_url=$(_parse_tfvar "sandbox_service_url_base_url") || _sandbox_service_url_base_url=""
SANDBOX_JUICEFS_CACHE_DIRS=""
SANDBOX_CLUSTER_NAME=""
SANDBOX_IRSA_ROLE_ARN=""
SANDBOX_RUNTIME_SECRET_NAME=""
SANDBOX_SERVICE_ACCOUNT_NAME=""
if [[ "$_enable_sandboxes" == "true" ]]; then
  SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_juicefs_csi_config_secret_name 2>/dev/null) || SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME="juicefs-csi-config"
  # Instance-store NVMe mounts on the sandbox-host nodes, e.g. /mnt/juicefs-cache0.
  # The list is empty when the nodes have no spare local NVMe, and the chart then
  # caches under its default /var/cache/juicefs on the root volume. Kept as a
  # space-separated string: an empty array trips set -u on the macOS bash 3.2.
  _cache_dirs_json=$(terraform -chdir="$INFRA_DIR" output -json sandbox_juicefs_host_cache_dirs 2>/dev/null) || _cache_dirs_json=""
  for _dir in $(printf '%s\n' "$_cache_dirs_json" | sed -e 's/[][" ]//g' -e 's/,/ /g'); do
    if [[ "$_dir" == /* ]]; then
      SANDBOX_JUICEFS_CACHE_DIRS+="${SANDBOX_JUICEFS_CACHE_DIRS:+ }${_dir}"
    fi
  done
  if [[ "$_sandbox_runtime_source" == "external" ]]; then
    if [[ -z "$HOSTNAME" ]]; then
      echo "ERROR: an external sandbox runtime requires a resolvable LangSmith hostname." >&2
      echo "       Set langsmith_domain or deploy the main ingress once, then re-run init-values." >&2
      exit 1
    fi
    SANDBOX_CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_cluster_name 2>/dev/null) || {
      echo "ERROR: Could not read sandbox_cluster_name. Is terraform apply complete?" >&2
      exit 1
    }
    SANDBOX_IRSA_ROLE_ARN=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_irsa_role_arn 2>/dev/null) || {
      echo "ERROR: Could not read sandbox_irsa_role_arn. Is terraform apply complete?" >&2
      exit 1
    }
    SANDBOX_RUNTIME_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_runtime_secret_name 2>/dev/null) || SANDBOX_RUNTIME_SECRET_NAME="langsmith-sandbox-runtime"
    # The sandbox IRSA role trusts exactly one ServiceAccount. Read that name
    # back from Terraform rather than hardcoding it here: the chart defaults
    # sandboxHost.serviceAccount.name to the sandbox-host fullname, which would
    # not match the trust policy and would fail IRSA at runtime with a
    # WebIdentityErr that points nowhere near this file.
    SANDBOX_SERVICE_ACCOUNT_NAME=$(terraform -chdir="$INFRA_DIR" output -raw sandbox_service_account_name 2>/dev/null) || SANDBOX_SERVICE_ACCOUNT_NAME=""
    if [[ -z "$SANDBOX_SERVICE_ACCOUNT_NAME" ]]; then
      echo "ERROR: Could not read sandbox_service_account_name. Upgrade the infra module and re-apply;" >&2
      echo "       without it the generated values cannot be matched to the sandbox IRSA trust policy." >&2
      exit 1
    fi
  fi
fi

echo "Product addons (from terraform.tfvars):"

# Deployments
if [[ "$_enable_deployments" == "true" ]]; then
  echo "  ✔ Deployments"
else
  echo "  ✗ Deployments (enable_deployments = false)"
fi

# Insights. In-cluster ClickHouse runs as the chart's StatefulSet (dev/POC only).
# The chart reads every connection field of an external ClickHouse from the
# langsmith-clickhouse Secret, so the values hold only the pointer to it. As on
# 0.17, the details are asked for on the first run only: an earlier overrides
# file or langsmith-values-local.yaml that names the Secret means it was set up,
# and a re-run then needs no cluster. deploy.sh checks that the Secret exists.
if [[ "$_enable_insights" == "true" ]]; then
  echo "  ✔ Insights (ClickHouse: $_clickhouse_source)"
  if [[ "$_clickhouse_source" != "in-cluster" ]]; then
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
        echo "ERROR: clickhouse_source = external, and namespace ${NAMESPACE:-langsmith} has no Secret langsmith-clickhouse." >&2
        echo "       Run make init-values in a terminal to enter the ClickHouse connection details." >&2
        exit 1
      fi
      echo ""
      echo "  Insights requires an external ClickHouse instance."
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
fi

# ── Fleet ────────────────────────────────────────────────────────────────────
# Fleet, Chat and Insights each use their own database on the shared RDS and
# their own DB index on the shared ElastiCache (K8s Secrets created by
# Terraform). The overrides file sets that storage and the IRSA service-account
# annotations. Their encryption keys reach the chart only through the
# langsmith-config Secret (SSM → ESO), never through values.
if [[ "$_enable_fleet" == "true" ]]; then
  echo "  ✔ Fleet"
else
  echo "  ✗ Fleet (enable_fleet = false)"
fi

if [[ "$_enable_polly" == "true" ]]; then
  echo "  ✔ LangSmith Chat (formerly Polly)"
else
  echo "  ✗ LangSmith Chat (formerly Polly) (enable_polly = false)"
fi

if [[ "$_enable_insights" != "true" ]]; then
  echo "  ✗ Insights (enable_insights = false)"
fi

if [[ "$_enable_sandboxes" == "true" ]]; then
  echo "  ✔ Sandboxes (${_sandbox_runtime_source}; JuiceFS config secret: ${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}; cache: ${SANDBOX_JUICEFS_CACHE_DIRS:-chart default})"
else
  echo "  ✗ Sandboxes (enable_sandboxes = false)"
fi

# Engine: the overlay turns Engine on. Its IRSA annotation and optional settings
# go into the overrides file below.
if [[ "$_enable_engine" == "true" ]]; then
  echo "  ✔ Engine (Bedrock through IRSA; the Insights database and Redis index)"
else
  echo "  ✗ Engine (enable_engine = false)"
fi

# LLM Gateway: generated rather than copied, because the gateway's service
# account carries the LangSmith IRSA role ARN, for the same S3 access as the rest
# of LangSmith. Presidio makes no AWS calls, so its service account gets no role.
# Presidio has a fragment of its own, merged only while
# enable_gateway_pii_redaction = true. The /gateway timeout is handled per
# routing mode: Terraform adds /gateway to the langsmith-fleet-streams HTTPRoute
# under Envoy Gateway, Istio sets no request timeout, and classic ALB Ingress
# mode raises the controller-owned ALB's idle timeout (see the routing block
# below).
if [[ "$_enable_llm_gateway" == "true" ]]; then
  cat > "$_frag_dir/llm-gateway.yaml" << LLMGW_EOF
# LLM Gateway (chart agentGateway, beta). Auto-generated by init-values.sh
# from enable_llm_gateway in terraform.tfvars.
# Clients: https://${HOSTNAME:-<langsmith host>}/gateway/v1 (OpenAI formats) or /gateway (Anthropic).
agentGateway:
  enabled: true
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"
LLMGW_EOF
  if [[ "$_enable_gateway_pii_redaction" == "true" ]]; then
    cat > "$_frag_dir/gateway-pii.yaml" << LLMGW_EOF
# LLM Gateway PII redaction (chart presidioAnalyzer). Auto-generated by
# init-values.sh from enable_gateway_pii_redaction in terraform.tfvars.
presidioAnalyzer:
  enabled: true
LLMGW_EOF
    echo "  ✔ LLM Gateway, with PII redaction"
  else
    echo "  ✔ LLM Gateway"
  fi
  if [[ "$_enable_envoy_gateway" == "true" && -z "$_langsmith_domain" ]]; then
    echo "  WARNING: enable_llm_gateway with Envoy Gateway and no langsmith_domain: Terraform creates the langsmith-fleet-streams route only with a domain, so model calls longer than Envoy's 15 s default fail." >&2
  fi
else
  echo "  ✗ LLM Gateway (enable_llm_gateway = false)"
fi

# The Deployments example sets tlsEnabled: false. The operator builds the agent
# endpoint URLs from it, so with TLS a false here keeps deployments in DEPLOYING.
if [[ "$_enable_deployments" == "true" && ( "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ) ]]; then
  printf 'config:\n  deployment:\n    tlsEnabled: true\n' > "$_frag_dir/agent-deploys-tls.yaml"
fi
echo ""

# ── Build ingress or gateway block ─────────────────────────────────────────────
_routing_block=""

if [[ "$_enable_envoy_gateway" == "true" ]]; then
  # ALB-always + Envoy Gateway mode: ALB is the external entry point.
  # The ALB forwards to Envoy proxy pods via a TargetGroupBinding (Terraform-managed).
  # Frontend service is ClusterIP — no internet-facing NLB is created.
  _routing_block="
ingress:
  enabled: false

gateway:
  enabled: true
  name: \"langsmith-gateway\"
  namespace: \"${NAMESPACE:-langsmith}\"

# ALB-always: frontend is ClusterIP. External traffic: ALB → Envoy proxy → HTTPRoute → frontend.
# The Terraform ALB module provisions a target group; k8s-bootstrap creates a TargetGroupBinding.
frontend:
  service:
    type: ClusterIP"
elif [[ "$_enable_istio_gateway" == "true" ]]; then
  # ALB-always + Istio Gateway mode: ALB is the external entry point.
  # The ALB forwards to Istio ingress gateway pods via a TargetGroupBinding (Terraform-managed).
  # Frontend service is ClusterIP — no internet-facing NLB is created.
  # Requires: istiod + istio-ingressgateway + a Gateway resource in the langsmith namespace.
  # See: helm/values/examples/langsmith-values-ingress-istio.yaml for the full prereq chain.
  _routing_block="
ingress:
  enabled: false

gateway:
  enabled: false

istioGateway:
  enabled: true
  name: \"langsmith-gateway\"
  namespace: \"${NAMESPACE:-langsmith}\"

# ALB-always: frontend is ClusterIP. External traffic: ALB → Istio gateway → VirtualService → frontend.
# The Terraform ALB module provisions a target group; k8s-bootstrap creates a TargetGroupBinding.
frontend:
  service:
    type: ClusterIP"
else
  # Classic ALB Ingress mode — the AWS Load Balancer Controller creates and owns
  # the ALB for this Ingress. There is no supported annotation to bind an Ingress
  # to a pre-provisioned ALB: the old `load-balancer-arn` annotation is not a real
  # controller annotation and was silently ignored, which produced a second,
  # orphaned ALB and stranded all routing. We therefore let the controller own the
  # ALB. `group.name` keeps the controller reusing a single stable ALB across
  # Ingress reconciliations (including the operator's dynamic /lgp/* deployment
  # paths). The hostname is read back from the Ingress status (see deploy.sh).
  _ingress_annotations=()

  # Always set scheme — the base values file no longer hardcodes it.
  _ingress_annotations+=("    alb.ingress.kubernetes.io/scheme: \"${ALB_SCHEME}\"")
  _ingress_annotations+=("    alb.ingress.kubernetes.io/group.name: \"${_name_prefix}-${_environment}\"")

  if [[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]]; then
    _ingress_annotations+=("    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}, {\"HTTPS\": 443}]'")
    _ingress_annotations+=("    alb.ingress.kubernetes.io/ssl-redirect: \"443\"")
    if [[ "$_tls_source" == "acm" && -n "$ACM_CERT_ARN" ]]; then
      _ingress_annotations+=("    alb.ingress.kubernetes.io/certificate-arn: \"${ACM_CERT_ARN}\"")
    fi
  fi

  # The controller-owned ALB idles out at 60 s, which cuts LLM Gateway model
  # calls; the chart's frontend allows /gateway 900 s. The Terraform ALB of the
  # other modes already idles at 3600 s. This file loads after the base values
  # file and replaces its annotation outright, so any attributes set there (access
  # logs, say) are carried over, and an idle timeout set there wins. The base
  # values come from examples/, so that is the file read here. The annotation in
  # langsmith-values-local.yaml replaces this one; set the idle timeout there too.
  if [[ "$_enable_llm_gateway" == "true" ]]; then
    _lb_attrs=""
    if [[ -f "$EXAMPLES_DIR/$_VALUES_BASE" ]]; then
      _lb_attrs=$(grep -E '^[[:space:]]*alb\.ingress\.kubernetes\.io/load-balancer-attributes:' "$EXAMPLES_DIR/$_VALUES_BASE" \
        | head -1 | sed -E "s/^[^:]*:[[:space:]]*//; s/[[:space:]]+\$//; s/^[\"'](.*)[\"']\$/\\1/") || _lb_attrs=""
    fi
    if [[ -z "$_lb_attrs" ]]; then
      _lb_attrs="idle_timeout.timeout_seconds=900"
    elif [[ "$_lb_attrs" != *idle_timeout.timeout_seconds=* ]]; then
      _lb_attrs="${_lb_attrs},idle_timeout.timeout_seconds=900"
    fi
    _ingress_annotations+=("    alb.ingress.kubernetes.io/load-balancer-attributes: \"${_lb_attrs}\"")
  fi

  if [[ ${#_ingress_annotations[@]} -gt 0 ]]; then
    _routing_block="
ingress:
  annotations:"
    for _ann in "${_ingress_annotations[@]}"; do
      _routing_block+=$'\n'"${_ann}"
    done
  fi
fi

# ── Standalone agent feature overrides (chart v0.15+) ────────────────────────
# Each enabled standalone feature needs IRSA annotations on the service accounts
# the chart creates. Its Fernet encryption key comes from the langsmith-config
# Secret, which ESO syncs from SSM, so no key goes into a values file. Features
# that are OFF get an explicit `enabled: false` so the chart's top-level default
# (polly/insights default to enabled: true) cannot silently turn them on
# (migration issue #6).
_standalone_block=""

if [[ "$_enable_fleet" == "true" ]]; then
  _standalone_block+="
fleet:
  postgres:
    external:
      enabled: true
      existingSecretName: \"langsmith-fleet-postgres\"
  redis:
    external:
      enabled: true
      existingSecretName: \"langsmith-fleet-redis\"
  apiServer:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\"
  queue:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\"

fleetToolServer:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\"

fleetTriggerServer:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\""
fi

if [[ "$_enable_polly" == "true" ]]; then
  _standalone_block+="
polly:
  postgres:
    external:
      enabled: true
      existingSecretName: \"langsmith-polly-postgres\"
  redis:
    external:
      enabled: true
      existingSecretName: \"langsmith-polly-redis\"
  apiServer:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\"
  queue:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\""
else
  _standalone_block+="
polly:
  enabled: false"
fi

# Chart 0.16 moved the Insights workload settings, the service accounts included,
# to `engineInsightsAgent` (below).
if [[ "$_enable_insights" != "true" ]]; then
  _standalone_block+="
insights:
  enabled: false"
fi

# ── Engine (enable_engine) ────────────────────────────────────────────────────
# langsmith-values-engine.yaml turns Engine on. Its keys reach the chart only
# through the langsmith-config Secret (SSM → ESO), never through values. Engine
# and Insights share the engineInsightsAgent deployment and its two service
# accounts. With Engine on, both run under the Engine IRSA role from terraform
# apply. That role trusts only these two service accounts.
_engine_agent_role_arn="$IRSA_ROLE_ARN"
if [[ "$_enable_engine" == "true" ]]; then
  ENGINE_IRSA_ROLE_ARN=$(terraform -chdir="$INFRA_DIR" output -raw engine_irsa_role_arn 2>/dev/null) || ENGINE_IRSA_ROLE_ARN=""
  if [[ "$ENGINE_IRSA_ROLE_ARN" != arn:* ]]; then
    echo "ERROR: enable_engine = true but terraform output engine_irsa_role_arn is empty." >&2
    echo "       Is 'terraform apply' complete in $INFRA_DIR with enable_engine = true?" >&2
    exit 1
  fi
  echo "Engine: engine_irsa_role_arn = $ENGINE_IRSA_ROLE_ARN"
  _engine_agent_role_arn="$ENGINE_IRSA_ROLE_ARN"

  _engine_tenant=$(_parse_tfvar "engine_sandbox_tenant_id") || _engine_tenant=""
  _engine_intel_url=$(_parse_tfvar "engine_intelligence_base_url") || _engine_intel_url=""
  _engine_settings=""
  if [[ -n "$_engine_tenant" ]]; then
    _engine_settings+="
  sandboxTenantId: \"${_engine_tenant}\""
  fi
  if [[ -n "$_engine_intel_url" ]]; then
    _engine_settings+="
  intelligenceBaseUrl: \"${_engine_intel_url}\""
  fi
  if [[ -n "$_engine_settings" ]]; then
    _standalone_block+="
engine:${_engine_settings}
"
  fi
fi

# The chart sets no requests or limits on the shared Engine and Insights
# deployment, and a strict ResourceQuota rejects a pod without them. The Engine
# example merges after this block, so a value set there wins, and so does one
# in langsmith-values-local.yaml. test-values.sh renders this block.
if [[ "$_enable_insights" == "true" || "$_enable_engine" == "true" ]]; then
  _engine_insights_agent_block=$(cat << ENGINE_INSIGHTS_AGENT_YAML
engineInsightsAgent:
  postgres:
    external:
      enabled: true
      existingSecretName: "langsmith-insights-postgres"
  redis:
    external:
      enabled: true
      existingSecretName: "langsmith-insights-redis"
  apiServer:
    deployment:
      resources:
        requests:
          cpu: "2"
          memory: 4Gi
        limits:
          cpu: "4"
          memory: 8Gi
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "${_engine_agent_role_arn}"
  queue:
    deployment:
      resources:
        requests:
          cpu: "1"
          memory: 2Gi
        limits:
          cpu: "2"
          memory: 4Gi
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "${_engine_agent_role_arn}"
ENGINE_INSIGHTS_AGENT_YAML
)
  _standalone_block+="
${_engine_insights_agent_block}"
fi

_sandbox_config_block=""
if [[ "$_enable_sandboxes" == "true" ]]; then
  _sandbox_service_url_block=""
  if [[ -n "$_sandbox_service_url_base_url" ]]; then
    _sandbox_service_url_block="
  serviceUrlBaseUrl: \"${_sandbox_service_url_base_url}\""
  fi
  if [[ "$_sandbox_runtime_source" == "external" ]]; then
    # The sandbox cluster runs untrusted code, so sandbox service auth uses a
    # dedicated key in langsmith-config (synced from SSM by apply-eso.sh), never
    # api_key_salt. Terraform writes the same value into the runtime Secret.
    _sandbox_config_block="
sandboxes:
  enabled: true
  external:
    enabled: true${_sandbox_service_url_block}
  serviceAuth:
    secretKey: \"sandbox_service_auth_secret\""

    # The runtime chart's own default is /var/cache/juicefs on the root volume.
    _sandbox_cache_dirs_block=""
    for _dir in ${SANDBOX_JUICEFS_CACHE_DIRS:-/var/cache/juicefs}; do
      _sandbox_cache_dirs_block+="
      - \"${_dir}\""
    done

    # Copied to SANDBOX_VALUES_FILE once the two values files are written.
    cat > "$_frag_dir/sandbox-runtime.yaml" << YAML
# Auto-generated by init-values.sh for the dedicated sandbox cluster.
# Terraform writes the runtime Secret (config.existingSecretName) in the
# sandbox cluster. The keys are the chart defaults, spelled out because the
# Secret depends on them. Both values match the same keys in langsmith-config;
# neither is the API key salt.
config:
  endpoint: "${_protocol}://${HOSTNAME}/api"
  existingSecretName: "${SANDBOX_RUNTIME_SECRET_NAME}"
  callbackSigningJwkSecretKey: "sandbox_callback_signing_jwk"
serviceAuth:
  secretKey: "sandbox_service_auth_secret"

# IRSA for sandbox-host and the JuiceFS formatter. The chart annotates the
# ServiceAccount from this block.
workloadIdentity:
  provider: aws
  aws:
    roleArn: "${SANDBOX_IRSA_ROLE_ARN}"

juicefs:
  existingSecretName: "${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}"
  hostMount:
    cacheDirs:${_sandbox_cache_dirs_block}

sandboxHost:
  enabled: true
  deployment:
    nodeSelector:
      sandbox.langsmith.com/host: "true"
  # serviceAccount.name is the IRSA contract with the sandbox IAM role's OIDC
  # 'sub' condition (Terraform: sandbox_service_account_name). Do not rename it
  # here alone — change the tfvar and re-run init-values so both sides move
  # together, or sandbox-host loses access to the trace bucket.
  serviceAccount:
    name: "${SANDBOX_SERVICE_ACCOUNT_NAME}"
YAML
  else
    _sandbox_cache_dirs_block=""
    if [[ -n "$SANDBOX_JUICEFS_CACHE_DIRS" ]]; then
      _sandbox_cache_dirs_block="
    hostMount:
      cacheDirs:"
      for _dir in $SANDBOX_JUICEFS_CACHE_DIRS; do
        _sandbox_cache_dirs_block+="
        - \"${_dir}\""
      done
    fi
    # sandbox-host mounts JuiceFS itself, and the chart's JuiceFS format Job runs
    # under the same ServiceAccount, so the bucket role goes on sandboxHost.
    _sandbox_config_block="
sandboxes:
  enabled: true${_sandbox_service_url_block}
  juicefs:
    existingSecretName: \"${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}\"${_sandbox_cache_dirs_block}
  sandboxHost:
    deployment:
      nodeSelector:
        sandbox.langsmith.com/host: \"true\"
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: \"${IRSA_ROLE_ARN}\""
  fi
fi

# ── The core of langsmith-values-overrides.yaml ───────────────────────────────
# Secrets (license key, api key salt, jwt secret, admin password, encryption keys)
# are NOT written here. ESO pulls them from SSM and creates the 'langsmith-config'
# K8s Secret (aws/infra/modules/k8s-bootstrap/main.tf and apply-eso.sh).
cat > "$_frag_dir/core.yaml" << YAML
config:
  # ALB hostname — required for OAuth and Deployments features.
  # In all modes (ALB, Envoy Gateway, Istio) the ALB is the external entry point.
  # Find it with: terraform -chdir=infra output -raw alb_dns_name
  # Or check: AWS Console → EC2 → Load Balancers → DNS name
  #
  # Include the protocol. The chart's hostnameWithProtocol helper defaults a bare
  # hostname to https://, which makes the browser-facing Fleet URLs
  # (VITE_AGENT_BUILDER_MCP_SERVER_URL, *_DEPLOYMENT_URL_PUBLIC, *_TRIGGERS_API_URL)
  # https — unreachable on an HTTP/TLS-none ALB (Fleet MCP -32001 + CORS failures).
  # Routing is unaffected: the chart strips the scheme via hostnameWithoutProtocol
  # for ingress/HTTPRoute/VirtualService host matching.
  hostname: "${_protocol}://${HOSTNAME}"
  initialOrgAdminEmail: "${ADMIN_EMAIL}"
  deployment:
    # URL used by the operator to build agent deployment endpoints.
    # Must match config.hostname with correct protocol — wrong value keeps
    # deployments stuck in DEPLOYING state.
    url: "${_protocol}://${HOSTNAME}"
  blobStorage:
    bucketName: "${BUCKET_NAME}"
    apiURL: "https://s3.${_region}.amazonaws.com"
${_sandbox_config_block}

commonEnv:
  - name: AWS_REGION
    value: "${_region}"
  - name: AWS_DEFAULT_REGION
    value: "${_region}"
  # The medium reads, medium writes pattern in the scale guide; commonEnv lives here
  # because a list in a later file replaces the base values' list.
  - name: CLICKHOUSE_ASYNC_INSERT_WAIT_PCT_FLOAT
    value: "0"
$( [[ "$_enable_usage_telemetry" == "true" ]] && cat <<'TELEMETRY'
  - name: PHONE_HOME_USAGE_REPORTING_ENABLED
    value: "true"
TELEMETRY
)

# IRSA: annotate each component's service account individually.
# The chart does not support a global serviceAccount block.
platformBackend:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

backend:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

ingestQueue:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

queue:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

# Deployments feature components — annotations are harmless if the addon is not enabled.
hostBackend:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

listener:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

operator:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"

# Playground calls model providers directly (e.g. Bedrock via workload
# identity) to test prompts interactively — needs the same IRSA role as
# backend/platformBackend, or it silently falls back to the node's instance
# role and gets AccessDeniedException on any Bedrock call.
playground:
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${IRSA_ROLE_ARN}"
# langsmith-ksa is used by operator-spawned agent deployment pods and must also
# carry the IRSA annotation. Apply it after Helm creates the service account:
#   kubectl annotate serviceaccount langsmith-ksa -n langsmith \
#     eks.amazonaws.com/role-arn=<irsa_role_arn> --overwrite
${_routing_block}
${_standalone_block}
YAML

# ── SmithDB (chart 0.17+) ─────────────────────────────────────────────────────
# The SmithDB example turns SmithDB on and sets its tier. The SmithDB values
# below add the object-store bucket, region, IRSA role ARN, and metastore
# secret-key mapping from the infra outputs, and the node selector and
# tolerations that put SmithDB on its own node group.
if [[ "$_enable_smithdb" == "true" ]]; then
  _smithdb_overrides="$_frag_dir/smithdb-overrides.yaml"

  SMITHDB_BUCKET=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_object_store_bucket 2>/dev/null) || SMITHDB_BUCKET=""
  SMITHDB_IRSA_ROLE_ARN=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_irsa_role_arn 2>/dev/null) || SMITHDB_IRSA_ROLE_ARN=""
  SMITHDB_CACHE_STORAGE_CLASS=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_cache_storage_class_name 2>/dev/null) || SMITHDB_CACHE_STORAGE_CLASS=""
  if [[ -z "$SMITHDB_BUCKET" || -z "$SMITHDB_IRSA_ROLE_ARN" || -z "$SMITHDB_CACHE_STORAGE_CLASS" ]]; then
    echo "ERROR: enable_smithdb = true but smithdb_object_store_bucket / smithdb_irsa_role_arn / smithdb_cache_storage_class_name outputs are empty." >&2
    echo "       Is 'terraform apply' complete in $INFRA_DIR with enable_smithdb = true?" >&2
    exit 1
  fi
  echo "  smithdb_object_store_bucket = $SMITHDB_BUCKET"
  echo "  smithdb_irsa_role_arn       = $SMITHDB_IRSA_ROLE_ARN"

  cat > "$_smithdb_overrides" << SMITHDB_YAML
# Auto-generated by init-values.sh — SmithDB environment-specific overrides.
# Re-run init-values.sh to refresh from Terraform outputs.
#
# Advance these flags one stage at a time by following the SmithDB installation
# guide.
smithdb:
  cache:
    storageClassName: "${SMITHDB_CACHE_STORAGE_CLASS}"
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "${SMITHDB_IRSA_ROLE_ARN}"
  config:
    objectStore:
      type: "s3"
      bucket: "${SMITHDB_BUCKET}"
      s3:
        region: "${_region}"
        accessKeyIdSecretKey: ""
        secretAccessKeySecretKey: ""
    metastore:
      hostSecretKey: "smithdb_metastore_db_host"
      databaseSecretKey: "smithdb_metastore_db_name"
      usernameSecretKey: "smithdb_metastore_db_username"
      passwordSecretKey: "smithdb_metastore_db_password"
      port: "5432"
      useSsl: ${_smithdb_metastore_use_ssl}
  metastoreMigration:
    useSsl: ${_smithdb_metastore_use_ssl}
    job:
$(_smithdb_pool_scheduling "      ")
  query:
    deployment:
$(_smithdb_pool_scheduling "      ")
  mutations:
    deployment:
$(_smithdb_pool_scheduling "      ")
  runRules:
    deployment:
$(_smithdb_pool_scheduling "      ")
  statsQuery:
    deployment:
$(_smithdb_pool_scheduling "      ")
  ingestion:
    deployment:
$(_smithdb_pool_scheduling "      ")
  compactionWorker:
    deployment:
$(_smithdb_pool_scheduling "      ")
  compaction:
    deployment:
$(_smithdb_pool_scheduling "      ")
  clusterManager:
    deployment:
$(_smithdb_pool_scheduling "      ")
  migration:
    taskdb:
      postgres:
        statefulSet:
$(_smithdb_pool_scheduling "          ")
  langsmith:
    ingestion:
      enabled: ${_smithdb_ingestion_enabled}
    query:
      enabled: ${_smithdb_query_enabled}
SMITHDB_YAML
fi

# ── Merge everything into langsmith-values-overrides.yaml ─────────────────────
# The sources merge in the order deploy.sh layered them on 0.17, after the base
# values, so a later one wins. The local file is the last file. The --set values
# apply after every file, so terraform.tfvars, not a values file, decides which
# features run, where their data lives, and how the SmithDB caches mount.
_values_plan_reset
_values_plan_file generated "$_frag_dir/core.yaml" "core values from Terraform outputs: hostname, IRSA, S3, routing, sandboxes, add-on wiring"
if [[ "$_enable_deployments" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml"
  if [[ -f "$_frag_dir/agent-deploys-tls.yaml" ]]; then
    _values_plan_file generated "$_frag_dir/agent-deploys-tls.yaml" "config.deployment.tlsEnabled from tls_certificate_source"
  fi
fi
if [[ "$_enable_engine" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-engine.yaml"
fi
if [[ "$_enable_insights" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-insights.yaml"
  if [[ -f "$_frag_dir/clickhouse.yaml" ]]; then
    _values_plan_file generated "$_frag_dir/clickhouse.yaml" "the external ClickHouse Secret, from clickhouse_source"
  fi
fi
if [[ "$_enable_polly" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-polly.yaml"
fi
if [[ "$_enable_fleet" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-fleet.yaml"
fi
if [[ "$_enable_llm_gateway" == "true" ]]; then
  _values_plan_file generated "$_frag_dir/llm-gateway.yaml" "the LLM Gateway and its IRSA role"
  if [[ "$_enable_gateway_pii_redaction" == "true" ]]; then
    _values_plan_file generated "$_frag_dir/gateway-pii.yaml" "the LLM Gateway PII redaction"
  fi
fi
if [[ "$_enable_sso_oidc" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-sso.yaml"
fi
if [[ "$_enable_smithdb" == "true" ]]; then
  _values_plan_file example "$EXAMPLES_DIR/langsmith-values-smithdb.yaml"
  _values_plan_file generated "$_smithdb_overrides" "SmithDB storage, identity, node group and gates from Terraform outputs"
fi
_values_plan_local "$VALUES_DIR"

# The SmithDB cache volumes and tier resources, worked out from the merged values
# with the base values first, as make deploy did before 0.18.
if [[ "$_enable_smithdb" == "true" ]]; then
  _smithdb_cache_storage=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_cache_storage 2>/dev/null) || _smithdb_cache_storage=""
  _smithdb_cache_storage=$(_smithdb_cache_mode "$_smithdb_cache_storage" "$(_parse_tfvar "smithdb_cache_storage" || true)") || exit 1
  VALUES_ARGS=(-f "$EXAMPLES_DIR/$_VALUES_BASE" "${_VALUES_PLAN_ARGS[@]}")
  _i=${#VALUES_ARGS[@]}
  _smithdb_managed_values "$_smithdb_cache_storage" || exit 1
  while (( _i < ${#VALUES_ARGS[@]} )); do
    _values_plan_set "${VALUES_ARGS[_i]}" "${VALUES_ARGS[_i + 1]}"
    _i=$((_i + 2))
  done
  _values_plan_resolved smithdb_cache_storage "$_smithdb_cache_storage"
  echo "SmithDB: ${SMITHDB_RESOURCE_TIER} tier, ${_smithdb_cache_storage} cache"
fi

# The chart defaults Chat and Insights to enabled, and Fleet needs host-backend.
_values_plan_set --set "polly.enabled=$_enable_polly"
_values_plan_set --set "insights.enabled=$_enable_insights"
if [[ "$_enable_fleet" == "true" ]]; then
  _values_plan_set --set "hostBackend.enabled=true"
fi
_engine_insights_agent=false
if [[ "$_enable_insights" == "true" || "$_enable_engine" == "true" ]]; then
  _engine_insights_agent=true
fi
VALUES_ARGS=()
_addon_storage_values "$_enable_fleet" "$_enable_polly" "$_engine_insights_agent"
_i=0
while (( _i < ${#VALUES_ARGS[@]} )); do
  _values_plan_set "${VALUES_ARGS[_i]}" "${VALUES_ARGS[_i + 1]}"
  _i=$((_i + 2))
done

# Recorded in the header, so make deploy stops when one of them changes.
_values_plan_tfvars name_prefix environment region tls_certificate_source acm_certificate_arn \
  alb_scheme clickhouse_source langsmith_domain langsmith_admin_email sandbox_runtime_source \
  sandbox_service_url_base_url enable_envoy_gateway enable_istio_gateway \
  enable_deployments enable_insights enable_polly enable_usage_telemetry enable_fleet \
  enable_sandboxes enable_engine enable_sso_oidc enable_llm_gateway enable_gateway_pii_redaction \
  engine_sandbox_tenant_id \
  engine_intelligence_base_url enable_smithdb smithdb_ingestion_enabled smithdb_query_enabled \
  smithdb_metastore_use_ssl smithdb_cache_storage
_values_plan_resolved enable_envoy_gateway "$_enable_envoy_gateway"
_values_plan_resolved enable_istio_gateway "$_enable_istio_gateway"
_values_plan_resolved enable_smithdb "$_enable_smithdb"
_values_plan_script "$MODULE_DIR" helm/scripts/init-values.sh helm/scripts/_values.sh \
  helm/scripts/_addon-storage.sh infra/scripts/_smithdb.sh

_values_write "$VALUES_DIR" "$EXAMPLES_DIR" || exit 1
echo "Written: $VALUES_DIR/$_VALUES_BASE (the base values, from examples/)"
echo "Written: $OUT_FILE"
if [[ -f "$VALUES_DIR/$_VALUES_LOCAL" ]]; then
  echo "         (with your changes from $_VALUES_LOCAL)"
fi
if [[ -f "$_frag_dir/sandbox-runtime.yaml" ]]; then
  cp "$_frag_dir/sandbox-runtime.yaml" "$SANDBOX_VALUES_FILE"
  echo "Written: $SANDBOX_VALUES_FILE (cluster: $SANDBOX_CLUSTER_NAME, serviceAccount: $SANDBOX_SERVICE_ACCOUNT_NAME)"
fi
echo ""
echo "Next step: make deploy"
