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
#
# Re-running is safe: Terraform outputs are refreshed; choices are preserved
# if the files already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"
EXAMPLES_DIR="$VALUES_DIR/examples"

# ── tfvars parser ─────────────────────────────────────────────────────────────
_parse_tfvar() {
  local key="$1"
  awk -F= "/^[[:space:]]*${key}[[:space:]]*=/{gsub(/[ \"']/, \"\", \$2); print \$2; exit}" \
    "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
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

echo "  storage_bucket_name           = $BUCKET_NAME"
echo "  cluster_name                  = $CLUSTER_NAME"
echo "  workload_identity_annotation  = ${WI_ANNOTATION:-(not available — enable_gcp_iam_module=false?)}"
echo "  ingress_ip                    = ${INGRESS_IP:-(pending — deploy Helm first to get external IP)}"
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
  awk -F': ' -v k="$key" '$1 ~ "^[[:space:]]*"k"$" { gsub(/"/, "", $2); gsub(/[[:space:]]+$/, "", $2); print $2; exit }' "$OUT_FILE" 2>/dev/null || true
}

EXISTING_API_KEY_SALT=""
EXISTING_JWT_SECRET=""
EXISTING_ADMIN_PASSWORD=""
EXISTING_LICENSE_KEY=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_API_KEY_SALT=$(_extract_yaml_value "apiKeySalt")
  EXISTING_JWT_SECRET=$(_extract_yaml_value "jwtSecret")
  EXISTING_ADMIN_PASSWORD=$(_extract_yaml_value "initialOrgAdminPassword")
  EXISTING_LICENSE_KEY=$(_extract_yaml_value "langsmithLicenseKey")
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
_tfvars_drive_addons=false

# Read enable_* flags from terraform.tfvars if set
_tfvar_is_true "enable_deployments"     && { _enable_deployments=true;     _tfvars_drive_addons=true; }
_tfvar_is_true "enable_agent_builder"   && { _enable_agent_builder=true;   _tfvars_drive_addons=true; }
_tfvar_is_true "enable_insights"        && { _enable_insights=true;         _tfvars_drive_addons=true; }
_tfvar_is_true "enable_polly"           && { _enable_polly=true;             _tfvars_drive_addons=true; }
_tfvar_is_true "enable_usage_telemetry" && { _enable_usage_telemetry=true;  _tfvars_drive_addons=true; }

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
elif [[ "$_first_run" == "true" ]]; then
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
config:
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
config:
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

# ── Optional addon encryption keys (from setup-env.sh) ───────────────────────
_addon_keys_block=""
if [[ "$_enable_agent_builder" == "true" || "$_enable_insights" == "true" ]]; then
  _agent_builder_key="${TF_VAR_langsmith_agent_builder_encryption_key:-}"
  _insights_key="${TF_VAR_langsmith_insights_encryption_key:-}"

  if [[ "$_enable_agent_builder" == "true" && -z "$_agent_builder_key" ]]; then
    echo "ERROR: enable_agent_builder=true but TF_VAR_langsmith_agent_builder_encryption_key is not set." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi

  if [[ "$_enable_insights" == "true" && -z "$_insights_key" ]]; then
    echo "ERROR: enable_insights=true but TF_VAR_langsmith_insights_encryption_key is not set." >&2
    echo "       Run: source infra/scripts/setup-env.sh" >&2
    exit 1
  fi

  _addon_keys_block="
  agentBuilder:
    encryptionKey: \"${_agent_builder_key}\"
  insights:
    encryptionKey: \"${_insights_key}\""
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
  # Find it with: kubectl get gateway -n langsmith -o jsonpath='{.items[0].status.addresses[0].value}'
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

gateway:
  name: "${_gateway_name}"
  namespace: "envoy-gateway-system"
${_wi_block}
${_external_services_block}
YAML

echo "Written: $OUT_FILE"
if [[ -z "$HOSTNAME" ]]; then
  echo ""
  echo "WARNING: hostname is empty. Run again after the Envoy Gateway has an external IP:"
  echo "  kubectl get gateway -n langsmith -o jsonpath='{.items[0].status.addresses[0].value}'"
  echo "  Then set langsmith_domain in terraform.tfvars and re-run this script."
fi
echo ""
echo "Next step: ./helm/scripts/deploy.sh"
