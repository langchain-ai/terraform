#!/usr/bin/env bash
# init-values.sh — Generates Helm values files from Terraform outputs.
#
# Usage (from aws/):
#   make init-values  (or: ./helm/scripts/init-values.sh)
#
# Reads:
#   - aws/infra/terraform.tfvars    → name_prefix, environment, region, tls_certificate_source
#   - terraform output              → bucket_name, langsmith_irsa_role_arn, alb outputs
#
# Prompts for (on first run):
#   - Admin email
#   - Sizing profile (ha / light / none)
#   - Product tier (LangSmith only / +Deployments / +Agent Builder / +Insights)
#
# Creates:
#   - values/langsmith-values.yaml              (base — copied from examples/)
#   - values/langsmith-values-overrides.yaml    (auto-generated: hostname, IRSA, S3)
#   - values/langsmith-values-sizing-*.yaml     (based on sizing choice)
#   - values/langsmith-values-agent-*.yaml      (based on product tier)
#   - values/langsmith-values-insights.yaml     (if tier 4 chosen)
#
# Re-running is safe: Terraform outputs are refreshed; choices are preserved
# if the files already exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"
EXAMPLES_DIR="$VALUES_DIR/examples"
source "$INFRA_DIR/scripts/_common.sh"

# ── Parse terraform.tfvars ────────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  echo "ERROR: terraform.tfvars not found at $INFRA_DIR/terraform.tfvars" >&2
  echo "Run: cp $INFRA_DIR/terraform.tfvars.example $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-}"
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
_acm_arn=$(_parse_tfvar "acm_certificate_arn") || _acm_arn=""
_alb_scheme=$(_parse_tfvar "alb_scheme") || _alb_scheme="internet-facing"
_postgres_source=$(_parse_tfvar "postgres_source") || _postgres_source="external"
_redis_source=$(_parse_tfvar "redis_source") || _redis_source="external"
_clickhouse_source=$(_parse_tfvar "clickhouse_source") || _clickhouse_source="in-cluster"

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

OUT_FILE="$VALUES_DIR/langsmith-values-overrides.yaml"
_first_run="false"
[[ ! -f "$OUT_FILE" ]] && _first_run="true"

echo "Parsed terraform.tfvars:"
echo "  name_prefix            = ${_name_prefix:-(empty)}"
echo "  environment            = $_environment"
echo "  region                 = $_region"
echo "  tls_certificate_source = $_tls_source (protocol: $_protocol)"
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
EXISTING_HOSTNAME=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_HOSTNAME=$(grep -E '^\s*hostname:' "$OUT_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || EXISTING_HOSTNAME=""
fi
if [[ -n "$EXISTING_HOSTNAME" ]]; then
  HOSTNAME="$EXISTING_HOSTNAME"
elif [[ -n "$ALB_DNS_NAME" ]]; then
  HOSTNAME="$ALB_DNS_NAME"
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

# ── Sizing choice ────────────────────────────────────────────────────────────
_sizing_ha="$VALUES_DIR/langsmith-values-sizing-ha.yaml"
_sizing_light="$VALUES_DIR/langsmith-values-sizing-light.yaml"

if [[ -f "$_sizing_ha" || -f "$_sizing_light" ]]; then
  # Sizing already chosen — respect existing choice on re-runs
  if [[ -f "$_sizing_ha" ]]; then
    echo "Sizing: HA (existing langsmith-values-sizing-ha.yaml)"
  else
    echo "Sizing: light (existing langsmith-values-sizing-light.yaml)"
  fi
elif [[ "$_first_run" == "true" ]]; then
  echo "Sizing profile:"
  echo ""
  echo "  1) ha    — production (multi-replica, HPA autoscaling)"
  echo "  2) light — reduced resources for POC/test"
  echo "  3) none  — chart defaults (no sizing file)"
  echo ""
  printf "Choice [1]: "
  read -r _sizing_choice
  _sizing_choice="${_sizing_choice:-1}"

  case "$_sizing_choice" in
    1|ha)
      cp "$EXAMPLES_DIR/langsmith-values-sizing-ha.yaml" "$_sizing_ha"
      echo "  Created: langsmith-values-sizing-ha.yaml"
      ;;
    2|light)
      cp "$EXAMPLES_DIR/langsmith-values-sizing-light.yaml" "$_sizing_light"
      echo "  Created: langsmith-values-sizing-light.yaml"
      ;;
    3|none)
      echo "  No sizing file — using chart defaults."
      ;;
    *)
      echo "ERROR: Invalid choice '$_sizing_choice'. Expected 1, 2, or 3." >&2
      exit 1
      ;;
  esac
else
  echo "No sizing file found. To add one:"
  echo "  cp $EXAMPLES_DIR/langsmith-values-sizing-ha.yaml $VALUES_DIR/"
fi
echo ""

# ── Product addons (driven by enable_* flags in terraform.tfvars) ────────────
_deploys_file="$VALUES_DIR/langsmith-values-agent-deploys.yaml"
_builder_file="$VALUES_DIR/langsmith-values-agent-builder.yaml"
_insights_file="$VALUES_DIR/langsmith-values-insights.yaml"
_polly_file="$VALUES_DIR/langsmith-values-polly.yaml"

_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true
_tfvar_is_true "enable_insights"      && _enable_insights=true
_tfvar_is_true "enable_polly"         && _enable_polly=true

echo "Product addons (from terraform.tfvars):"

# Deployments
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

# Agent Builder
if [[ "$_enable_agent_builder" == "true" ]]; then
  if [[ "$_enable_deployments" != "true" ]]; then
    echo "ERROR: enable_agent_builder requires enable_deployments = true in terraform.tfvars." >&2
    exit 1
  fi
  if [[ ! -f "$_builder_file" ]]; then
    cp "$EXAMPLES_DIR/langsmith-values-agent-builder.yaml" "$_builder_file"
    echo "  ✔ Agent Builder (created langsmith-values-agent-builder.yaml)"
  else
    echo "  ✔ Agent Builder (existing)"
  fi
else
  echo "  ✗ Agent Builder (enable_agent_builder = false)"
fi

# Insights
if [[ "$_enable_insights" == "true" ]]; then
  if [[ ! -f "$_insights_file" ]]; then
    if [[ "$_clickhouse_source" == "in-cluster" ]]; then
      # In-cluster ClickHouse: the chart deploys it as a StatefulSet.
      # No external connection config needed — just enable insights.
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
      # External ClickHouse: prompt for connection details on first creation.
      cp "$EXAMPLES_DIR/langsmith-values-insights.yaml" "$_insights_file"
      echo "  ✔ Insights (created langsmith-values-insights.yaml)"
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

      # Write ClickHouse values using existingSecretName pattern.
      # The password is stored in a K8s Secret, not in the values file.
      cat > "$_insights_file" <<CHEOF
# Auto-generated by init-values.sh — external ClickHouse connection.
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
      echo "  Updated: langsmith-values-insights.yaml"
      echo ""
      echo "  Creating langsmith-clickhouse K8s Secret..."
      echo "  (deploy.sh will re-apply this if the namespace is recreated)"
      if ! kubectl create secret generic langsmith-clickhouse -n "${NAMESPACE:-langsmith}" \
        --from-literal=clickhouse_host="${_ch_host}" \
        --from-literal=clickhouse_port="${_ch_port}" \
        --from-literal=clickhouse_user="${_ch_user}" \
        --from-literal=clickhouse_password="${_ch_pass}" \
        --from-literal=clickhouse_db="${_ch_db}" \
        --from-literal=clickhouse_tls="${_ch_tls_val}" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        echo "  WARNING: Could not create langsmith-clickhouse K8s secret." >&2
        echo "           Ensure kubectl is configured and re-run, or create the secret manually." >&2
      else
        echo "  Secret langsmith-clickhouse created/updated."
      fi
    fi
  else
    echo "  ✔ Insights (existing)"
  fi
else
  echo "  ✗ Insights (enable_insights = false)"
fi

# Polly
if [[ "$_enable_polly" == "true" ]]; then
  if [[ "$_enable_deployments" != "true" ]]; then
    echo "ERROR: enable_polly requires enable_deployments = true in terraform.tfvars." >&2
    exit 1
  fi
  if [[ ! -f "$_polly_file" ]]; then
    cp "$EXAMPLES_DIR/langsmith-values-polly.yaml" "$_polly_file"
    echo "  ✔ Polly (created langsmith-values-polly.yaml)"
  else
    echo "  ✔ Polly (existing)"
  fi
else
  echo "  ✗ Polly (enable_polly = false)"
fi

# Patch tlsEnabled in agent-deploys if present — derive from tls_certificate_source.
# The example file defaults to false; fix it so deploys don't get stuck in DEPLOYING state.
if [[ -f "$_deploys_file" && "$_enable_deployments" == "true" ]]; then
  if [[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]]; then
    sed -i.bak 's/tlsEnabled: false/tlsEnabled: true/' "$_deploys_file" && rm -f "$_deploys_file.bak"
  fi
fi
echo ""

# ── Build optional ingress annotations ────────────────────────────────────────
_ingress_block=""
_ingress_annotations=()

# Always set scheme — the base values file no longer hardcodes it.
_ingress_annotations+=("    alb.ingress.kubernetes.io/scheme: \"${ALB_SCHEME}\"")

if [[ -n "$ALB_ARN" ]]; then
  _ingress_annotations+=("    alb.ingress.kubernetes.io/load-balancer-arn: \"${ALB_ARN}\"")
  # group.name tells the ALB controller to bind to the existing pre-provisioned ALB
  # instead of creating a new one on each ingress reconciliation. Without this,
  # ingress recreation provisions a new ALB with a different hostname.
  _ingress_annotations+=("    alb.ingress.kubernetes.io/group.name: \"${_name_prefix}-${_environment}\"")
fi

if [[ "$_tls_source" == "acm" || "$_tls_source" == "letsencrypt" ]]; then
  _ingress_annotations+=("    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}, {\"HTTPS\": 443}]'")
  _ingress_annotations+=("    alb.ingress.kubernetes.io/ssl-redirect: \"443\"")
  if [[ "$_tls_source" == "acm" && -n "$ACM_CERT_ARN" ]]; then
    _ingress_annotations+=("    alb.ingress.kubernetes.io/certificate-arn: \"${ACM_CERT_ARN}\"")
  fi
fi

if [[ ${#_ingress_annotations[@]} -gt 0 ]]; then
  _ingress_block="
ingress:
  annotations:"
  for _ann in "${_ingress_annotations[@]}"; do
    _ingress_block+=$'\n'"${_ann}"
  done
fi

# ── Copy base values if missing ───────────────────────────────────────────────
if [[ ! -f "$VALUES_DIR/langsmith-values.yaml" ]]; then
  cp "$EXAMPLES_DIR/langsmith-values.yaml" "$VALUES_DIR/langsmith-values.yaml"
  echo "Created: langsmith-values.yaml (base)"
fi

# ── In-cluster overrides for postgres/redis ──────────────────────────────────
# The base langsmith-values.yaml hardcodes postgres.external.enabled: true and
# redis.external.enabled: true. When using in-cluster sources, we must override
# those to false so the chart deploys its own pods instead of looking for the
# (non-existent) external connection secrets.
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

# ── Write langsmith-values-overrides.yaml ─────────────────────────────────────
# Secrets (license key, api key salt, jwt secret, admin password) are NOT written
# here. ESO pulls them from SSM and creates the 'langsmith-config' K8s Secret.
cat > "$OUT_FILE" << YAML
# Auto-generated by init-values.sh — do not edit auto-filled fields manually.
# Re-run init-values.sh to refresh Terraform outputs.
# Secrets are managed by External Secrets Operator (ESO) from SSM — see:
#   aws/infra/modules/k8s-bootstrap/main.tf

config:
  # ALB hostname — required for OAuth and Deployments features.
  # Find it with: kubectl get ingress -n langsmith langsmith-ingress \
  #     -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  # Or check: AWS Console → EC2 → Load Balancers → DNS name
  hostname: "${HOSTNAME}"
  initialOrgAdminEmail: "${ADMIN_EMAIL}"
  deployment:
    # URL used by the operator to build agent deployment endpoints.
    # Must match config.hostname with correct protocol — wrong value keeps
    # deployments stuck in DEPLOYING state.
    url: "${_protocol}://${HOSTNAME}"
  blobStorage:
    bucketName: "${BUCKET_NAME}"
    awsRegion: "${_region}"
    apiURL: "https://s3.${_region}.amazonaws.com"

commonEnv:
  - name: AWS_REGION
    value: "${_region}"
  - name: AWS_DEFAULT_REGION
    value: "${_region}"

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
# langsmith-ksa is used by operator-spawned agent deployment pods and must also
# carry the IRSA annotation. Apply it after Helm creates the service account:
#   kubectl annotate serviceaccount langsmith-ksa -n langsmith \
#     eks.amazonaws.com/role-arn=<irsa_role_arn> --overwrite
${_ingress_block}
${_external_services_block}
YAML

echo "Written: $OUT_FILE"
echo ""
echo "Next step: make deploy"
