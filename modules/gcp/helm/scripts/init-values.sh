#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# init-values.sh — Generates Helm values files from Terraform outputs.
#
# Usage (from gcp/):
#   ./helm/scripts/init-values.sh
#
# Reads:
#   - gcp/infra/terraform.tfvars    → project_id, region, name_prefix, environment,
#                                     tls_certificate_source, langsmith_domain,
#                                     postgres_source, redis_source
#   - terraform output              → storage_bucket_name, workload_identity_annotation,
#                                     cluster_name, ingress_ip
#
# Prompts for (on first run):
#   - Admin email
#   - Sizing profile (ha / light / none)
#   - Product tier (LangSmith only / +Deployments / +Agent Builder / +Insights)
#
# Creates:
#   - values/values-overrides.yaml              (auto-generated: hostname, WI annotations, GCS)
#   - values/langsmith-values-sizing-*.yaml     (based on sizing choice)
#   - values/langsmith-values-agent-*.yaml      (based on product tier)
#   - values/langsmith-values-insights.yaml     (if Insights tier chosen)
#   - values/langsmith-values-smithdb.yaml           (if enable_smithdb)
#   - values/langsmith-values-smithdb-overrides.yaml (if enable_smithdb)
#
# Re-running is safe: Terraform outputs are refreshed; choices are preserved
# if the files already exist.
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
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"
EXAMPLES_DIR="$VALUES_DIR/examples"

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

# ── Parse terraform.tfvars ────────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $INFRA_DIR/terraform.tfvars" >&2
  echo "Run: cp $INFRA_DIR/terraform.tfvars.example $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

_project_id=$(_parse_tfvar "project_id")
_name_prefix=$(_parse_tfvar "name_prefix")
_environment=$(_parse_tfvar "environment")
_region=$(_parse_tfvar "region")
_region="${_region:-us-west2}"
_tls_source=$(_parse_tfvar "tls_certificate_source")
_tls_source="${_tls_source:-none}"
_domain=$(_parse_tfvar "langsmith_domain")
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
_smithdb_migration_enabled=false
_tfvar_is_true "smithdb_migration_enabled" && _smithdb_migration_enabled=true
_smithdb_query_enabled=false
_tfvar_is_true "smithdb_query_enabled" && _smithdb_query_enabled=true

if [[ "$_enable_smithdb" != "true" ]] && \
   [[ "$_smithdb_ingestion_enabled" == "true" || "$_smithdb_migration_enabled" == "true" || "$_smithdb_query_enabled" == "true" ]]; then
  echo "ERROR: SmithDB integration gates require enable_smithdb = true." >&2
  exit 1
fi
if [[ "$_smithdb_ingestion_enabled" != "true" ]] && \
   [[ "$_smithdb_migration_enabled" == "true" || "$_smithdb_query_enabled" == "true" ]]; then
  echo "ERROR: smithdb_migration_enabled and smithdb_query_enabled both require smithdb_ingestion_enabled = true." >&2
  exit 1
fi

if [[ -z "$_project_id" || -z "$_name_prefix" || -z "$_environment" ]]; then
  echo "ERROR: Could not read project_id, name_prefix, and/or environment from $INFRA_DIR/terraform.tfvars." >&2
  echo "       Ensure terraform.tfvars has these values set." >&2
  exit 1
fi

# Derive protocol
if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "existing" ]]; then
  _protocol="https"
else
  _protocol="http"
fi

OUT_FILE="$VALUES_DIR/values-overrides.yaml"
_first_run="false"
[[ ! -f "$OUT_FILE" ]] && _first_run="true"

echo "Parsed terraform.tfvars:"
echo "  project_id             = $_project_id"
echo "  name_prefix            = $_name_prefix"
echo "  environment            = $_environment"
echo "  region                 = $_region"
echo "  tls_certificate_source = $_tls_source (protocol: $_protocol)"
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
SMITHDB_METASTORE_USE_SSL="true"
SMITHDB_SECRET_NAME="smithdb-metastore"
SMITHDB_TASKDB_SECRET_NAME="smithdb-taskdb"
SMITHDB_USE_AUTH_PROXY="false"
SMITHDB_CONNECTION_NAME=""
SMITHDB_AUTH_PROXY_IMAGE=""
if [[ "$_enable_smithdb" == "true" ]]; then
  SMITHDB_BUCKET=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_object_store_bucket 2>/dev/null) || SMITHDB_BUCKET=""
  SMITHDB_GSA=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_gsa_email 2>/dev/null) || SMITHDB_GSA=""
  SMITHDB_METASTORE_PORT=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_port 2>/dev/null) || SMITHDB_METASTORE_PORT="5432"
  SMITHDB_METASTORE_USE_SSL=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_use_ssl 2>/dev/null) || SMITHDB_METASTORE_USE_SSL="true"
  SMITHDB_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_secret_name 2>/dev/null) || SMITHDB_SECRET_NAME="smithdb-metastore"
  SMITHDB_TASKDB_SECRET_NAME=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_taskdb_secret_name 2>/dev/null) || SMITHDB_TASKDB_SECRET_NAME="smithdb-taskdb"
  SMITHDB_USE_AUTH_PROXY=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_use_auth_proxy 2>/dev/null) || SMITHDB_USE_AUTH_PROXY="false"
  SMITHDB_CONNECTION_NAME=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_metastore_connection_name 2>/dev/null) || SMITHDB_CONNECTION_NAME=""
  SMITHDB_AUTH_PROXY_IMAGE=$(terraform -chdir="$INFRA_DIR" output -raw smithdb_auth_proxy_image 2>/dev/null) || SMITHDB_AUTH_PROXY_IMAGE=""

  echo "  smithdb_object_store_bucket   = ${SMITHDB_BUCKET:-(not available)}"
  echo "  smithdb_gsa_email             = ${SMITHDB_GSA:-(not available)}"
  echo "  smithdb_metastore_port        = $SMITHDB_METASTORE_PORT (useSsl: $SMITHDB_METASTORE_USE_SSL)"
  echo "  smithdb auth proxy            = $SMITHDB_USE_AUTH_PROXY${SMITHDB_CONNECTION_NAME:+ ($SMITHDB_CONNECTION_NAME)}"
  echo "  smithdb gates                 = ingestion:$_smithdb_ingestion_enabled migration:$_smithdb_migration_enabled query:$_smithdb_query_enabled"

  if [[ -z "$SMITHDB_BUCKET" || -z "$SMITHDB_GSA" ]]; then
    echo "ERROR: enable_smithdb = true but the SmithDB Terraform outputs are missing." >&2
    echo "       Run 'terraform apply' in infra/ before init-values.sh." >&2
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
# Priority: existing OUT_FILE > langsmith_domain tfvar > ingress IP > empty
EXISTING_HOSTNAME=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_HOSTNAME=$(grep -E '^\s*hostname:' "$OUT_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || EXISTING_HOSTNAME=""
fi

if [[ -n "$EXISTING_HOSTNAME" ]]; then
  HOSTNAME="$EXISTING_HOSTNAME"
elif [[ -n "$_domain" ]]; then
  HOSTNAME="$_domain"
elif [[ -n "$INGRESS_IP" && "$INGRESS_IP" != "pending" && "$INGRESS_IP" != "not installed" ]]; then
  HOSTNAME="$INGRESS_IP"
else
  HOSTNAME=""
fi

# ── Admin email ───────────────────────────────────────────────────────────────
EXISTING_EMAIL=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_EMAIL=$(grep -E '^\s*initialOrgAdminEmail:' "$OUT_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || EXISTING_EMAIL=""
fi

if [[ -n "$EXISTING_EMAIL" ]]; then
  ADMIN_EMAIL="$EXISTING_EMAIL"
  echo "Reusing existing admin email: $ADMIN_EMAIL"
else
  printf "Admin email: "
  read -r ADMIN_EMAIL
  if [[ -z "$ADMIN_EMAIL" ]]; then
    echo "ERROR: Admin email is required." >&2
    exit 1
  fi
fi
echo ""

# ── Stable runtime secrets (apiKeySalt / jwtSecret / admin password) ─────────
# Prefer TF_VAR_* from setup-env.sh, then existing file values.
_extract_yaml_value() {
  local key="$1"
  awk -F': ' -v k="$key" '
    $1 ~ "^[[:space:]]*"k"$" {
      v = $2
      gsub(/[[:space:]]+$/, "", v)
      if ((substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") ||
          (substr(v, 1, 1) == "\047" && substr(v, length(v), 1) == "\047")) {
        v = substr(v, 2, length(v) - 2)
      }
      print v
      exit
    }
  ' "$OUT_FILE" 2>/dev/null || true
}

EXISTING_API_KEY_SALT=""
EXISTING_JWT_SECRET=""
EXISTING_ADMIN_PASSWORD=""
EXISTING_LICENSE_KEY=""
EXISTING_SANDBOX_CALLBACK_SIGNING_JWK=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_API_KEY_SALT=$(_extract_yaml_value "apiKeySalt")
  EXISTING_JWT_SECRET=$(_extract_yaml_value "jwtSecret")
  EXISTING_ADMIN_PASSWORD=$(_extract_yaml_value "initialOrgAdminPassword")
  EXISTING_LICENSE_KEY=$(_extract_yaml_value "langsmithLicenseKey")
  EXISTING_SANDBOX_CALLBACK_SIGNING_JWK=$(_extract_yaml_value "callbackSigningJwk")
fi

API_KEY_SALT="${TF_VAR_langsmith_api_key_salt:-$EXISTING_API_KEY_SALT}"
if [[ -z "$API_KEY_SALT" ]]; then
  API_KEY_SALT="$(openssl rand -base64 32 | tr -d '\n')"
  echo "WARNING: TF_VAR_langsmith_api_key_salt not set; generated a new apiKeySalt."
  echo "         To avoid API key invalidation across redeploys, run: source infra/scripts/setup-env.sh"
fi

JWT_SECRET="${TF_VAR_langsmith_jwt_secret:-$EXISTING_JWT_SECRET}"
if [[ -z "$JWT_SECRET" ]]; then
  JWT_SECRET="$(openssl rand -base64 32 | tr -d '\n')"
  echo "WARNING: TF_VAR_langsmith_jwt_secret not set; generated a new jwtSecret."
  echo "         To avoid session invalidation across redeploys, run: source infra/scripts/setup-env.sh"
fi

ADMIN_PASSWORD="${TF_VAR_langsmith_admin_password:-$EXISTING_ADMIN_PASSWORD}"
if [[ -z "$ADMIN_PASSWORD" ]]; then
  printf "Initial admin password: "
  read -rs ADMIN_PASSWORD
  echo
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "ERROR: initial admin password is required." >&2
    exit 1
  fi
fi

LANGSMITH_LICENSE_KEY="${TF_VAR_langsmith_license_key:-$EXISTING_LICENSE_KEY}"
if [[ -z "$LANGSMITH_LICENSE_KEY" ]]; then
  echo "ERROR: LangSmith license key is required." >&2
  echo "       Set TF_VAR_langsmith_license_key (or run: source infra/scripts/setup-env.sh)." >&2
  exit 1
fi

# ── Sizing profile (from terraform.tfvars) ────────────────────────────────────
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  _sizing_example="$EXAMPLES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ ! -f "$_sizing_file" ]]; then
    if [[ -f "$_sizing_example" ]]; then
      cp "$_sizing_example" "$_sizing_file"
      echo "Sizing: ${_sizing_profile} (created langsmith-values-sizing-${_sizing_profile}.yaml)"
    else
      echo "WARNING: Example file not found for sizing_profile = ${_sizing_profile}. Skipping sizing file." >&2
    fi
  else
    echo "Sizing: ${_sizing_profile} (existing langsmith-values-sizing-${_sizing_profile}.yaml)"
  fi
else
  echo "Sizing: chart defaults (sizing_profile = default)"
fi
echo ""

# ── Product addons (from terraform.tfvars, with interactive fallback) ─────────
_deploys_file="$VALUES_DIR/langsmith-values-agent-deploys.yaml"
_builder_file="$VALUES_DIR/langsmith-values-agent-builder.yaml"
_insights_file="$VALUES_DIR/langsmith-values-insights.yaml"

_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_enable_usage_telemetry=false
_enable_fleet=false
_enable_standalone_polly=false
_enable_standalone_insights=false
_enable_sandboxes=false
_tfvars_drive_addons=false

# Resolve encryption keys up front so the standalone copy+inject blocks below
# can reference them before the _addon_keys_block section runs.
_agent_builder_key="${TF_VAR_langsmith_agent_builder_encryption_key:-}"
_insights_key="${TF_VAR_langsmith_insights_encryption_key:-}"
_polly_key="${TF_VAR_langsmith_polly_encryption_key:-}"

# Read enable_* flags from terraform.tfvars if set
_tfvar_is_true "enable_deployments"        && { _enable_deployments=true;        _tfvars_drive_addons=true; }
_tfvar_is_true "enable_agent_builder"      && { _enable_agent_builder=true;      _tfvars_drive_addons=true; }
_tfvar_is_true "enable_insights"           && { _enable_insights=true;           _tfvars_drive_addons=true; }
_tfvar_is_true "enable_polly"              && { _enable_polly=true;              _tfvars_drive_addons=true; }
_tfvar_is_true "enable_usage_telemetry"    && { _enable_usage_telemetry=true;    _tfvars_drive_addons=true; }
_tfvar_is_true "enable_fleet"              && { _enable_fleet=true;              _tfvars_drive_addons=true; }
_tfvar_is_true "enable_standalone_polly"   && { _enable_standalone_polly=true;   _tfvars_drive_addons=true; }
_tfvar_is_true "enable_standalone_insights" && { _enable_standalone_insights=true; _tfvars_drive_addons=true; }
_tfvar_is_true "enable_sandboxes"          && { _enable_sandboxes=true;          _tfvars_drive_addons=true; }

_sandbox_host_image_tag=$(_parse_tfvar "sandbox_host_image_tag") || _sandbox_host_image_tag=""
_sandbox_service_url_base_url=$(_parse_tfvar "sandbox_service_url_base_url") || _sandbox_service_url_base_url=""
SANDBOX_CALLBACK_SIGNING_JWK="${TF_VAR_sandbox_callback_signing_jwk:-$EXISTING_SANDBOX_CALLBACK_SIGNING_JWK}"
if [[ "$_enable_sandboxes" == "true" ]]; then
  if [[ -z "$_sandbox_host_image_tag" ]]; then
    echo "ERROR: sandbox_host_image_tag is required when enable_sandboxes = true." >&2
    exit 1
  fi
  if [[ -z "$SANDBOX_CALLBACK_SIGNING_JWK" ]]; then
    echo "ERROR: TF_VAR_sandbox_callback_signing_jwk is required when enable_sandboxes = true." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi
  if [[ -z "$WI_ANNOTATION" ]]; then
    echo "ERROR: enable_sandboxes requires Workload Identity. Set enable_gcp_iam_module = true and re-run terraform apply." >&2
    exit 1
  fi
fi

echo "Product addons (from terraform.tfvars):"

if [[ "$_tfvars_drive_addons" == "true" ]]; then
  # Validate addon dependencies
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

  if [[ "$_enable_deployments" == "true" ]]; then
    if [[ ! -f "$_deploys_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" "$_deploys_file"
      echo "  ✔ Deployments (created langsmith-values-agent-deploys.yaml)"
    else
      echo "  ✔ Deployments (existing)"
    fi
  else
    echo "  ✗ Deployments (enable_deployments = false)"
  fi

  if [[ "$_enable_agent_builder" == "true" ]]; then
    if [[ ! -f "$_builder_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-agent-builder.yaml" "$_builder_file"
      echo "  ✔ Agent Builder (created langsmith-values-agent-builder.yaml)"
    else
      echo "  ✔ Agent Builder (existing)"
    fi
  else
    echo "  ✗ Agent Builder (enable_agent_builder = false)"
  fi

  if [[ "$_enable_insights" == "true" ]]; then
    echo "  ✔ Insights (enable_insights = true)"
    # File creation + ClickHouse prompt handled below
  else
    echo "  ✗ Insights (enable_insights = false)"
  fi

  if [[ "$_enable_polly" == "true" ]]; then
    _polly_file="$VALUES_DIR/langsmith-values-polly.yaml"
    if [[ ! -f "$_polly_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-polly.yaml" "$_polly_file"
      echo "  ✔ Polly (created langsmith-values-polly.yaml)"
    else
      echo "  ✔ Polly (existing)"
    fi
  else
    echo "  ✗ Polly (enable_polly = false)"
  fi

  if [[ "$_enable_fleet" == "true" ]]; then
    _fleet_file="$VALUES_DIR/langsmith-values-fleet.yaml"
    if [[ ! -f "$_fleet_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-fleet.yaml" "$_fleet_file"
      echo "  ✔ Fleet (created langsmith-values-fleet.yaml)"
    else
      echo "  ✔ Fleet (existing)"
    fi
  else
    echo "  ✗ Fleet (enable_fleet = false)"
  fi

  if [[ "$_enable_standalone_polly" == "true" ]]; then
    _sp_file="$VALUES_DIR/langsmith-values-standalone-polly.yaml"
    if [[ ! -f "$_sp_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-standalone-polly.yaml" "$_sp_file"
      echo "  ✔ Standalone Polly (created langsmith-values-standalone-polly.yaml; encryptionKey written to values-overrides.yaml)"
    else
      echo "  ✔ Standalone Polly (existing; encryptionKey in values-overrides.yaml)"
    fi
  else
    echo "  ✗ Standalone Polly (enable_standalone_polly = false)"
  fi

  if [[ "$_enable_standalone_insights" == "true" ]]; then
    _si_file="$VALUES_DIR/langsmith-values-standalone-insights.yaml"
    if [[ ! -f "$_si_file" ]]; then
      cp "$EXAMPLES_DIR/langsmith-values-standalone-insights.yaml" "$_si_file"
      echo "  ✔ Standalone Insights (created langsmith-values-standalone-insights.yaml; encryptionKey written to values-overrides.yaml)"
    else
      echo "  ✔ Standalone Insights (existing; encryptionKey in values-overrides.yaml)"
    fi
  else
    echo "  ✗ Standalone Insights (enable_standalone_insights = false)"
  fi

  if [[ "$_enable_sandboxes" == "true" ]]; then
    echo "  ✔ Sandboxes (sandbox-host; JuiceFS CSI config secret: ${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME})"
  else
    echo "  ✗ Sandboxes (enable_sandboxes = false)"
  fi

elif [[ "$_first_run" == "true" && "$_enable_sandboxes" != "true" ]]; then
  # No tfvars flags set — interactive fallback on first run
  echo "  (no enable_* flags in terraform.tfvars — prompting interactively)"
  echo ""
  echo "  Product tier:"
  echo "  1) LangSmith only"
  echo "  2) LangSmith + Deployments (LangGraph Platform)"
  echo "  3) LangSmith + Deployments + Agent Builder"
  echo "  4) LangSmith + Deployments + Agent Builder + Insights"
  echo ""
  printf "  Choice [1]: "
  read -r _tier_choice
  _tier_choice="${_tier_choice:-1}"

  case "$_tier_choice" in
    1)
      ;;
    2|3|4)
      cp "$EXAMPLES_DIR/langsmith-values-agent-deploys.yaml" "$_deploys_file"
      echo "  Created: langsmith-values-agent-deploys.yaml"
      _enable_deployments=true

      if [[ "$_tier_choice" == "3" || "$_tier_choice" == "4" ]]; then
        cp "$EXAMPLES_DIR/langsmith-values-agent-builder.yaml" "$_builder_file"
        echo "  Created: langsmith-values-agent-builder.yaml"
        _enable_agent_builder=true
      fi

      if [[ "$_tier_choice" == "4" ]]; then
        _enable_insights=true
      fi
      ;;
    *)
      echo "ERROR: Invalid choice '$_tier_choice'. Expected 1–4." >&2
      exit 1
      ;;
  esac
  echo ""
  echo "  Tip: set enable_deployments / enable_agent_builder / enable_insights"
  echo "  in terraform.tfvars to skip this prompt on future runs."
else
  # Re-run with no tfvars flags — report what's already on disk
  [[ -f "$_deploys_file" ]]  && { _enable_deployments=true;  echo "  ✔ Deployments (existing file)"; } || echo "  ✗ Deployments"
  [[ -f "$_builder_file" ]]  && { _enable_agent_builder=true; echo "  ✔ Agent Builder (existing file)"; } || echo "  ✗ Agent Builder"
  [[ -f "$_insights_file" ]] && { _enable_insights=true;      echo "  ✔ Insights (existing file)"; } || echo "  ✗ Insights"
  [[ -f "$VALUES_DIR/langsmith-values-fleet.yaml" ]]               && echo "  ✔ Fleet (existing file)"               || echo "  ✗ Fleet"
  [[ -f "$VALUES_DIR/langsmith-values-standalone-polly.yaml" ]]    && echo "  ✔ Standalone Polly (existing file)"    || echo "  ✗ Standalone Polly"
  [[ -f "$VALUES_DIR/langsmith-values-standalone-insights.yaml" ]] && echo "  ✔ Standalone Insights (existing file)" || echo "  ✗ Standalone Insights"
fi

if [[ "$_tfvars_drive_addons" != "true" ]]; then
  if [[ "$_enable_sandboxes" == "true" ]]; then
    echo "  ✔ Sandboxes (sandbox-host; JuiceFS CSI config secret: ${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME})"
  else
    echo "  ✗ Sandboxes (enable_sandboxes = false)"
  fi
fi

# Insights — create file based on clickhouse_source
if [[ "$_enable_insights" == "true" && ! -f "$_insights_file" ]]; then
  echo ""
  if [[ "$_clickhouse_source" == "in-cluster" ]]; then
    cat > "$_insights_file" <<CHEOF
# Auto-generated by init-values.sh — in-cluster ClickHouse.
# ClickHouse runs as a StatefulSet pod in the cluster (dev/POC only).
# For production, set clickhouse_source = "external" in terraform.tfvars
# and re-run init-values.sh to configure an external ClickHouse connection.
insights:
  enabled: true
CHEOF
    echo "  ✔ Insights (in-cluster ClickHouse — created langsmith-values-insights.yaml)"
  else
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
    if ! [[ "$_ch_port" =~ ^[0-9]+$ ]]; then
      echo "ERROR: ClickHouse port must be numeric." >&2
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

    cat > "$_insights_file" <<CHEOF
# Auto-generated by init-values.sh — ClickHouse connection details.
# Re-run init-values.sh or edit this file to update.
# Password is stored in the langsmith-clickhouse K8s Secret (not this file).
insights:
  enabled: true

clickhouse:
  external:
    enabled: true
    host: "${_ch_host}"
    port: "${_ch_port}"
    database: "${_ch_db}"
    user: "${_ch_user}"
    tls: ${_ch_tls_val}
    existingSecretName: "langsmith-clickhouse"
CHEOF

    echo "  Created: langsmith-values-insights.yaml"
    echo ""
    echo "  Creating langsmith-clickhouse K8s Secret..."
    if ! kubectl create secret generic langsmith-clickhouse -n "${NAMESPACE:-langsmith}" \
      --from-literal=clickhouse_host="${_ch_host}" \
      --from-literal=clickhouse_port="${_ch_port}" \
      --from-literal=clickhouse_user="${_ch_user}" \
      --from-literal=clickhouse_password="${_ch_pass}" \
      --from-literal=clickhouse_db="${_ch_db}" \
      --from-literal=clickhouse_tls="${_ch_tls_val}" \
      --dry-run=client -o yaml | kubectl apply -f -; then
      echo "  WARNING: Could not create langsmith-clickhouse K8s Secret." >&2
      echo "           Ensure kubectl is configured and re-run, or create the secret manually." >&2
    else
      echo "  Secret langsmith-clickhouse created/updated."
    fi
  fi
fi

# Patch tlsEnabled in agent-deploys if TLS is configured
if [[ -f "$_deploys_file" && "$_enable_deployments" == "true" ]]; then
  if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "existing" ]]; then
    sed -i.bak 's/tlsEnabled: false/tlsEnabled: true/' "$_deploys_file" && rm -f "$_deploys_file.bak"
  fi
fi
echo ""

# ── SmithDB (chart 0.16+) ─────────────────────────────────────────────────────
# Two files: the overlay (copied once from examples/, safe to hand-edit for
# scheduling and sizing) and the overrides file (regenerated every run from
# Terraform outputs). deploy.sh loads them in that order, so the overrides win.
_smithdb_file="$VALUES_DIR/langsmith-values-smithdb.yaml"
_smithdb_overrides_file="$VALUES_DIR/langsmith-values-smithdb-overrides.yaml"

if [[ "$_enable_smithdb" == "true" ]]; then
  echo "SmithDB (enable_smithdb = true):"

  if [[ ! -f "$_smithdb_file" ]]; then
    cp "$EXAMPLES_DIR/langsmith-values-smithdb.yaml" "$_smithdb_file"
    echo "  ✔ Created langsmith-values-smithdb.yaml (from examples/)"
  else
    echo "  ○ langsmith-values-smithdb.yaml already exists — left as-is"
  fi

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
      # merged into the init-container maximum, so this lands against the
      # namespace ResourceQuota once per SmithDB Pod. Both are set because the
      # quota rejects any container that omits limits.
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

  cat > "$_smithdb_overrides_file" << SMITHDBYAML
# Auto-generated by init-values.sh — do not edit manually.
# Re-run init-values.sh to refresh from Terraform outputs.
#
# Loaded after langsmith-values-smithdb.yaml, so anything here wins.
#
# The integration gates below come from infra/terraform.tfvars. Advance them one
# stage at a time (ingestion, then any historical migration, then query), and
# keep ClickHouse enabled throughout.

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

  # The migration Job reads its own useSsl leaf, which the chart defaults to
  # false, so it has to be set alongside the one above or the two modes disagree
  # and the pre-install hook fails on connect while the services are fine.
  metastoreMigration:
    useSsl: ${SMITHDB_METASTORE_USE_SSL}

  # The chart refuses to render with the migration gate on unless taskdb has a
  # credential, so always point it at the Terraform-created secret.
  #
  # The backfill's *source* blob store - the traces bucket holding the run
  # payloads LangSmith offloaded out of ClickHouse - needs nothing here. From
  # chart 0.16.6 the migration Job follows config.blobStorage.engine, so a GCS
  # engine renders the native GCS provider, which takes no credential fields and
  # authenticates as the Pod's Workload Identity principal. deploy.sh refuses to
  # deploy an older patch with this gate on, because chart 0.16.5 and earlier
  # asked for s3 regardless of engine and failed every read on GCP.
  #
  # What the source store does need is the read grant, and that is Terraform's
  # side: modules/smithdb holds roles/storage.objectViewer on the traces bucket
  # while smithdb_migration_enabled is true. Helm cannot create a GCP IAM
  # binding, so the chart fix alone is not sufficient.
  migration:
    taskdb:
      postgres:
        auth:
          existingSecretName: "${SMITHDB_TASKDB_SECRET_NAME}"

  langsmith:
    ingestion:
      enabled: ${_smithdb_ingestion_enabled}
    migration:
      enabled: ${_smithdb_migration_enabled}
    query:
      enabled: ${_smithdb_query_enabled}
SMITHDBYAML

  echo "  ✔ Written langsmith-values-smithdb-overrides.yaml"
  echo ""
else
  if [[ -f "$_smithdb_file" ]]; then
    echo "NOTE: langsmith-values-smithdb.yaml exists but enable_smithdb = false — deploy.sh will skip it."
    echo ""
  fi
fi

# ── In-cluster postgres/redis overrides ───────────────────────────────────────
_external_services_block=""
if [[ "$_postgres_source" == "in-cluster" ]]; then
  _external_services_block+="
postgres:
  external:
    enabled: false"
fi
if [[ "$_redis_source" == "in-cluster" ]]; then
  _external_services_block+="
redis:
  external:
    enabled: false"
fi

_sandbox_config_block=""
_sandbox_top_level_block=""
if [[ "$_enable_sandboxes" == "true" ]]; then
  _sandbox_service_url_block=""
  if [[ -n "$_sandbox_service_url_base_url" ]]; then
    _sandbox_service_url_block="
  serviceUrlBaseUrl: \"${_sandbox_service_url_base_url}\""
  fi
  _sandbox_config_block="
sandboxes:
  enabled: true${_sandbox_service_url_block}
  callbackSigningJwk: '${SANDBOX_CALLBACK_SIGNING_JWK}'
  juicefs:
    csi:
      existingSecretName: \"${SANDBOX_JUICEFS_CSI_CONFIG_SECRET_NAME}\"
      node:
        serviceAccount:
          annotations:
            iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
  sandboxHost:
    deployment:
      nodeSelector:
        sandbox.langsmith.com/host: \"true\""
  _sandbox_top_level_block="
images:
  sandboxHostImage:
    tag: \"${_sandbox_host_image_tag}\""
fi

# ── Optional addon encryption keys (from setup-env.sh) ───────────────────────
_addon_keys_block=""
_fleet_key_block=""
_standalone_polly_key_block=""
_standalone_insights_key_block=""
if [[ "$_enable_agent_builder" == "true" || "$_enable_fleet" == "true" || \
      "$_enable_insights" == "true" || "$_enable_standalone_insights" == "true" || \
      "$_enable_polly" == "true" || "$_enable_standalone_polly" == "true" ]]; then

  if [[ ( "$_enable_agent_builder" == "true" || "$_enable_fleet" == "true" ) && -z "$_agent_builder_key" ]]; then
    echo "ERROR: TF_VAR_langsmith_agent_builder_encryption_key is not set." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi

  if [[ ( "$_enable_insights" == "true" || "$_enable_standalone_insights" == "true" ) && -z "$_insights_key" ]]; then
    echo "ERROR: TF_VAR_langsmith_insights_encryption_key is not set." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi

  if [[ ( "$_enable_polly" == "true" || "$_enable_standalone_polly" == "true" ) && -z "$_polly_key" ]]; then
    echo "ERROR: TF_VAR_langsmith_polly_encryption_key is not set." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi

  # config.agentBuilder is still the Agent Builder enablement path in chart 0.16.
  # config.insights and config.polly were removed in 0.15.1 — validate.yaml rejects
  # them on presence alone, so their keys go on the top-level blocks below.
  if [[ "$_enable_agent_builder" == "true" ]]; then
    _addon_keys_block="
  agentBuilder:
    encryptionKey: \"${_agent_builder_key}\""
  fi

  if [[ "$_enable_fleet" == "true" ]]; then
    _fleet_key_block="
fleet:
  encryptionKey: \"${_agent_builder_key}\""
  fi

  # One top-level block per feature regardless of which flag turned it on. Writing
  # a legacy and a standalone variant separately would emit the key twice in the
  # same document, and the second mapping would win silently.
  if [[ "$_enable_polly" == "true" || "$_enable_standalone_polly" == "true" ]]; then
    _standalone_polly_key_block="
polly:
  encryptionKey: \"${_polly_key}\""
  fi

  if [[ "$_enable_insights" == "true" || "$_enable_standalone_insights" == "true" ]]; then
    _standalone_insights_key_block="
insights:
  encryptionKey: \"${_insights_key}\""
  fi
fi

# ── Agent defaults ────────────────────────────────────────────────────────────
# Chart 0.16 ships insights.enabled and polly.enabled as true. Without an explicit
# false a base install grows two agent deployments nobody asked for, and because
# this module sets no config.existingSecretName the chart then hard-fails on the
# missing encryptionKey. Make the terraform enable_* flags authoritative. The
# addon overlays load after this file, so an enabled feature still turns itself on.
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
_wi_block=""
if [[ -n "$WI_ANNOTATION" ]]; then
  _wi_block="
# Workload Identity — annotate each component's service account.
# The chart does not support a global serviceAccount block.
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

# Deployments feature components — annotations are harmless if the addon is not enabled.
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
      iam.gke.io/gcp-service-account: \"${WI_ANNOTATION}\"
# langsmith-ksa is used by operator-spawned agent deployment pods and must also
# carry the Workload Identity annotation. Apply it after Helm creates the SA:
#   kubectl annotate serviceaccount langsmith-ksa -n langsmith \\
#     iam.gke.io/gcp-service-account=${WI_ANNOTATION} --overwrite"
fi

# ── Write values-overrides.yaml ───────────────────────────────────────────────
cat > "$OUT_FILE" << YAML
# Auto-generated by init-values.sh — do not edit auto-filled fields manually.
# Re-run init-values.sh to refresh Terraform outputs.
#
# GCS blob storage: LangSmith accesses GCS via the S3-compatible API.
# Set accessKey and accessKeySecret to HMAC credentials created in:
#   GCP Console → Cloud Storage → Settings → Interoperability → Service Account HMAC Keys
# The service account must have Storage Admin on the ${BUCKET_NAME} bucket.

config:
  # Envoy Gateway IP — required for OAuth and Deployments features.
  # Find it with: kubectl get gateway -n envoy-gateway-system -o jsonpath='{.items[0].status.addresses[0].value}'
  hostname: "${HOSTNAME}"
  langsmithLicenseKey: "${LANGSMITH_LICENSE_KEY}"
  apiKeySalt: "${API_KEY_SALT}"
  initialOrgAdminEmail: "${ADMIN_EMAIL}"
  basicAuth:
    jwtSecret: "${JWT_SECRET}"
    initialOrgAdminPassword: "${ADMIN_PASSWORD}"
${_addon_keys_block}
  deployment:
    # URL used by the operator to build agent deployment endpoints.
    # Must match config.hostname with correct protocol — wrong value keeps
    # deployments stuck in DEPLOYING state.
    url: "${_protocol}://${HOSTNAME}"
  blobStorage:
    bucketName: "${BUCKET_NAME}"
    # TODO: Set HMAC credentials for GCS S3-compatible API access.
    # Leave empty only if you are using Workload Identity + the chart's native GCS support.
    accessKey: ""
    accessKeySecret: ""
    region: "${_region}"
    apiURL: "https://storage.googleapis.com"
    s3UsePathStyle: false
${_sandbox_config_block}

gateway:
  name: "${_gateway_name}"
  namespace: "envoy-gateway-system"
${_wi_block}
${_external_services_block}
${_fleet_key_block}
${_standalone_polly_key_block}
${_standalone_insights_key_block}
${_sandbox_top_level_block}
${_agent_defaults_block}
YAML

echo "Written: $OUT_FILE"
if [[ -z "$HOSTNAME" ]]; then
  echo ""
  echo "WARNING: hostname is empty. Run again after the Envoy Gateway has an external IP:"
  echo "  kubectl get gateway -n envoy-gateway-system -o jsonpath='{.items[0].status.addresses[0].value}'"
  echo "  Then set langsmith_domain in terraform.tfvars and re-run this script."
fi
echo ""
echo "Next step: ./helm/scripts/deploy.sh"
