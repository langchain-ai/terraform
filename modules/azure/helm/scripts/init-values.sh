#!/usr/bin/env bash
# init-values.sh — Generate Helm values files from Terraform outputs.
#
# Usage (from azure/):
#   make init-values  (or: ./helm/scripts/init-values.sh)
#
# Reads:
#   - infra/terraform.tfvars    → identifier, environment, location, tls_certificate_source,
#                                 postgres_source, redis_source, sizing_profile
#   - terraform output          → storage_account_name, storage_container_name,
#                                 storage_account_k8s_managed_identity_client_id,
#                                 langsmith_admin_email, langsmith_namespace, aks_cluster_name
#
# Prompts for (on first run):
#   - Admin email (if not in terraform outputs)
#   - Sizing profile
#   - Product tier (LangSmith / +Deployments / +Agent Builder / +Insights)
#
# Creates:
#   - helm/values/values-overrides.yaml              (auto-generated)
#   - helm/values/langsmith-values-sizing-*.yaml     (based on sizing choice)
#   - helm/values/langsmith-values-agent-*.yaml      (based on product tier)
#   - helm/values/langsmith-values-insights.yaml     (if Insights chosen)
#
# Re-running is safe: terraform outputs are refreshed; choices preserved if files exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"
EXAMPLES_DIR="$VALUES_DIR/examples"

source "$INFRA_DIR/scripts/_common.sh"

# ── Parse terraform.tfvars ────────────────────────────────────────────────
if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  fail "terraform.tfvars not found at $INFRA_DIR/terraform.tfvars"
  action "cp $INFRA_DIR/terraform.tfvars.example $INFRA_DIR/terraform.tfvars"
  exit 1
fi

_identifier=$(_parse_tfvar "identifier") || _identifier=""
_environment=$(_parse_tfvar "environment") || _environment="dev"
_location=$(_parse_tfvar "location") || _location="eastus"
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source="none"
_postgres_source=$(_parse_tfvar "postgres_source") || _postgres_source="external"
_redis_source=$(_parse_tfvar "redis_source") || _redis_source="external"
_clickhouse_source=$(_parse_tfvar "clickhouse_source") || _clickhouse_source="in-cluster"
_sizing_profile=$(_parse_tfvar "sizing_profile") || _sizing_profile="default"
_langsmith_domain=$(_parse_tfvar "langsmith_domain") || _langsmith_domain=""
_create_frontdoor=$(_parse_tfvar "create_frontdoor") || _create_frontdoor="false"
_nginx_dns_label=$(_parse_tfvar "nginx_dns_label") || _nginx_dns_label=""

# Derive protocol from TLS source
if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" || "$_tls_source" == "existing" || "$_create_frontdoor" == "true" ]]; then
  _protocol="https"
else
  _protocol="http"
fi

OUT_FILE="$VALUES_DIR/values-overrides.yaml"
_first_run="false"
[[ ! -f "$OUT_FILE" ]] && _first_run="true"

echo ""
echo "Parsed terraform.tfvars:"
info "identifier             = ${_identifier:-(empty)}"
info "environment            = $_environment"
info "location               = $_location"
info "tls_certificate_source = $_tls_source (protocol: $_protocol)"
info "postgres_source        = $_postgres_source"
info "redis_source           = $_redis_source"
info "sizing_profile         = ${_sizing_profile}"
[[ -n "$_langsmith_domain" ]] && info "langsmith_domain       = $_langsmith_domain"
[[ "$_create_frontdoor" == "true" ]] && info "create_frontdoor       = true"
echo ""

# ── Read terraform outputs ─────────────────────────────────────────────────
echo "Reading terraform outputs..."

STORAGE_ACCOUNT=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_name 2>/dev/null) || {
  fail "Could not read storage_account_name. Is 'terraform apply' complete?"
  exit 1
}
STORAGE_CONTAINER=$(terraform -chdir="$INFRA_DIR" output -raw storage_container_name 2>/dev/null) || {
  fail "Could not read storage_container_name."
  exit 1
}
WI_CLIENT_ID=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_k8s_managed_identity_client_id 2>/dev/null) || {
  fail "Could not read storage_account_k8s_managed_identity_client_id."
  exit 1
}
NAMESPACE=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_namespace 2>/dev/null) || NAMESPACE="langsmith"
ADMIN_EMAIL=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_admin_email 2>/dev/null) || ADMIN_EMAIL=""
CLUSTER_NAME=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name 2>/dev/null) || CLUSTER_NAME=""
RG_NAME=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name 2>/dev/null) || RG_NAME=""

echo ""
pass "Terraform outputs read"
info "storage_account = $STORAGE_ACCOUNT"
info "storage_container = $STORAGE_CONTAINER"
info "wi_client_id = $WI_CLIENT_ID"
info "namespace = $NAMESPACE"
[[ -n "$CLUSTER_NAME" ]] && info "cluster = $CLUSTER_NAME"
echo ""

# ── Determine hostname ─────────────────────────────────────────────────────
# Priority order:
#   1. langsmith_domain from terraform.tfvars (custom domain — DNS-01 or CNAME target)
#   2. nginx_dns_label from terraform.tfvars → <label>.<region>.cloudapp.azure.com
#   3. frontdoor_endpoint_hostname terraform output (*.azurefd.net — Front Door default FQDN)
#   4. Existing value in values-overrides.yaml (keep on re-run)
#   5. Interactive prompt
HOSTNAME=""

if [[ -n "$_langsmith_domain" ]]; then
  HOSTNAME="$_langsmith_domain"
  info "Hostname from langsmith_domain: $HOSTNAME"
  echo ""
fi

# Azure Public IP DNS label — free, no extra resource
if [[ -z "$HOSTNAME" && -n "$_nginx_dns_label" ]]; then
  HOSTNAME="${_nginx_dns_label}.${_location}.cloudapp.azure.com"
  info "Hostname from nginx_dns_label: $HOSTNAME"
  echo ""
fi

# If Front Door is enabled and no custom domain, try the *.azurefd.net endpoint
if [[ -z "$HOSTNAME" && "$_create_frontdoor" == "true" ]]; then
  _fd_hostname=$(terraform -chdir="$INFRA_DIR" output -raw frontdoor_endpoint_hostname 2>/dev/null) || _fd_hostname=""
  if [[ -n "$_fd_hostname" ]]; then
    HOSTNAME="$_fd_hostname"
    info "Front Door endpoint hostname: $HOSTNAME"
    info "(Add a CNAME from your custom domain to this FQDN — see terraform output)"
    echo ""
  fi
fi

# Keep existing hostname on re-run
if [[ -z "$HOSTNAME" && -f "$OUT_FILE" ]]; then
  _existing_hostname=$(grep -E '^\s*hostname:' "$OUT_FILE" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _existing_hostname=""
  if [[ -n "$_existing_hostname" && "$_existing_hostname" != *"<"* ]]; then
    HOSTNAME="$_existing_hostname"
    info "Keeping existing hostname: $HOSTNAME"
    echo ""
  fi
fi

if [[ -z "$HOSTNAME" ]]; then
  warn "No hostname found — set nginx_dns_label, langsmith_domain, or create_frontdoor in terraform.tfvars"
  echo ""
  printf "  Enter hostname (e.g. langsmith.example.com): "
  read -r HOSTNAME
  if [[ -z "$HOSTNAME" ]]; then
    fail "Hostname is required"
    exit 1
  fi
fi

# ── Admin email ────────────────────────────────────────────────────────────
if [[ -z "$ADMIN_EMAIL" ]]; then
  if [[ -f "$OUT_FILE" ]]; then
    _existing_email=$(grep -E '^\s*initialOrgAdminEmail:' "$OUT_FILE" 2>/dev/null \
      | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _existing_email=""
    if [[ -n "$_existing_email" && "$_existing_email" != *"<"* ]]; then
      ADMIN_EMAIL="$_existing_email"
      info "Keeping existing admin email: $ADMIN_EMAIL"
    fi
  fi
fi

if [[ -z "$ADMIN_EMAIL" ]]; then
  printf "  Initial org admin email: "
  read -r ADMIN_EMAIL
  if [[ -z "$ADMIN_EMAIL" ]]; then
    fail "Admin email is required"
    exit 1
  fi
fi

# ── Sizing profile ─────────────────────────────────────────────────────────
echo ""
if [[ "$_sizing_profile" == "default" ]]; then
  echo "  Sizing profile:"
  echo "    1) default  — chart defaults (start here)"
  echo "    2) minimum  — absolute floor, dev/POC/CI (may OOM under load)"
  echo "    3) dev      — light dev profile"
  echo "    4) production — HA production (3+ replicas, higher CPU/mem)"
  echo ""
  printf "  Sizing choice [1]: "
  read -r _sizing_choice
  case "${_sizing_choice:-1}" in
    2) _sizing_profile="minimum" ;;
    3) _sizing_profile="dev" ;;
    4) _sizing_profile="production" ;;
    *) _sizing_profile="default" ;;
  esac
fi

# ── Product tier — read from terraform.tfvars (enable_* flags) ─────────────
_enable_deployments=$(_parse_tfvar "enable_deployments") || _enable_deployments="false"
_enable_agent_builder=$(_parse_tfvar "enable_agent_builder") || _enable_agent_builder="false"
_enable_insights=$(_parse_tfvar "enable_insights") || _enable_insights="false"

echo ""
echo "  Product tier (from terraform.tfvars enable_* flags):"
info "enable_deployments   = $_enable_deployments"
info "enable_agent_builder = $_enable_agent_builder"
info "enable_insights      = $_enable_insights"
echo ""
echo "  To change: set enable_deployments / enable_agent_builder / enable_insights in terraform.tfvars → make init-values"

# ── Generate values-overrides.yaml ────────────────────────────────────────
echo ""
info "Generating values-overrides.yaml..."

# Build ingress/TLS block
# Front Door terminates TLS at the edge — no cert-manager annotation needed on the ingress.
# DNS-01 and HTTP-01 (letsencrypt) use cert-manager to issue certs on the cluster.
if [[ "$_create_frontdoor" == "true" ]]; then
  _ingress_block='ingress:
  enabled: true
  ingressClassName: "nginx"
  # Front Door terminates TLS — no cert-manager annotation needed.
  # Front Door → NGINX LB (HTTP) → LangSmith pods.'
elif [[ "$_tls_source" == "dns01" ]]; then
  _ingress_block='ingress:
  enabled: true
  ingressClassName: "nginx"
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  tls:
    - secretName: langsmith-tls
      hosts:
        - "'"${HOSTNAME}"'"'
elif [[ "$_tls_source" == "letsencrypt" ]]; then
  _ingress_block='ingress:
  enabled: true
  ingressClassName: "nginx"
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  tls:
    - secretName: langsmith-tls
      hosts:
        - "'"${HOSTNAME}"'"'
else
  _ingress_block='ingress:
  enabled: true
  ingressClassName: "nginx"'
fi

# Build postgres block
if [[ "$_postgres_source" == "external" ]]; then
  _postgres_block='postgres:
  external:
    enabled: true
    existingSecretName: "langsmith-postgres-secret"
    connectionUrlSecretKey: "connection_url"'
else
  _postgres_block='# postgres: in-cluster (managed by Helm chart)'
fi

# Build redis block
if [[ "$_redis_source" == "external" ]]; then
  _redis_block='redis:
  external:
    enabled: true
    existingSecretName: "langsmith-redis-secret"
    connectionUrlSecretKey: "connection_url"'
else
  _redis_block='# redis: in-cluster (managed by Helm chart)'
fi

cat > "$OUT_FILE" << EOF
# LangSmith Azure — Helm values overrides
# Auto-generated by init-values.sh — edit to customize, re-run to refresh from terraform outputs.
# values-overrides.yaml is gitignored — never commit it.
#
# Values chain: values.yaml (base) → this file → sizing overlay → addon overlays

config:
  hostname: "${HOSTNAME}"
  authType: "mixed"
  initialOrgAdminEmail: "${ADMIN_EMAIL}"
  existingSecretName: "langsmith-config-secret"
  basicAuth:
    enabled: true
  blobStorage:
    enabled: true
    engine: "Azure"
    azureStorageAccountName: "${STORAGE_ACCOUNT}"
    azureStorageContainerName: "${STORAGE_CONTAINER}"
  telemetry:
    usageReporting: true
  deployment:
    # Full URL used by the operator to build agent deployment endpoints.
    # Must include protocol — wrong value keeps deployments stuck in DEPLOYING state.
    url: "${_protocol}://${HOSTNAME}"

${_postgres_block}

${_redis_block}

# ── Workload Identity — pods that access Azure Blob Storage ───────────────────
# These service accounts are federated to the managed identity via AKS OIDC.
# The client-id annotation is set by Terraform (k8s-bootstrap module).
backend:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

platformBackend:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

queue:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

ingestQueue:
  enabled: true
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

hostBackend:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

listener:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

agentBuilderToolServer:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

agentBuilderTriggerServer:
  deployment:
    labels:
      azure.workload.identity/use: "true"
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: "${WI_CLIENT_ID}"

# ── Ingress / TLS ─────────────────────────────────────────────────────────────
${_ingress_block}
istioGateway:
  enabled: false
EOF

pass "Generated: ${OUT_FILE}"

# ── Generate sizing file ──────────────────────────────────────────────────
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_src="$EXAMPLES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  _sizing_dst="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_src" ]]; then
    cp "$_sizing_src" "$_sizing_dst"
    pass "Generated: langsmith-values-sizing-${_sizing_profile}.yaml"
  else
    warn "No example found for sizing_profile '${_sizing_profile}' in examples/ — skipping"
  fi
fi

# ── Generate addon files ──────────────────────────────────────────────────
_copy_addon() {
  local addon_file="$1"
  local _src="$EXAMPLES_DIR/langsmith-values-${addon_file}.yaml"
  local _dst="$VALUES_DIR/langsmith-values-${addon_file}.yaml"
  if [[ -f "$_src" ]]; then
    cp "$_src" "$_dst"
    # Inject deployment URL and tlsEnabled into agent-deploys after copy
    if [[ "$addon_file" == "agent-deploys" ]]; then
      local _tls_enabled="false"
      [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "dns01" || "$_tls_source" == "existing" ]] && _tls_enabled="true"
      # macOS-safe sed: use python3 for in-place substitution
      python3 -c "
import sys
content = open('${_dst}').read()
content = content.replace('url: \"\"        # populated by init-values.sh → https://<nginx_dns_label>.<region>.cloudapp.azure.com',
                          'url: \"${_protocol}://${HOSTNAME}\"')
content = content.replace('tlsEnabled: false  # populated by init-values.sh',
                          'tlsEnabled: ${_tls_enabled}')
open('${_dst}', 'w').write(content)
"
    fi
    pass "Generated: langsmith-values-${addon_file}.yaml"
  else
    warn "Example file not found: $EXAMPLES_DIR/langsmith-values-${addon_file}.yaml"
  fi
}

[[ "$_enable_deployments"   == "true" ]] && _copy_addon "agent-deploys"
[[ "$_enable_agent_builder" == "true" ]] && _copy_addon "agent-builder"

# Insights: generate file based on clickhouse_source
# For in-cluster ClickHouse, just enable insights — no external connection block needed.
# For external ClickHouse, copy the full example (requires manual ClickHouse config).
if [[ "$_enable_insights" == "true" ]]; then
  _clickhouse_source=$(_parse_tfvar "clickhouse_source") || _clickhouse_source="in-cluster"
  if [[ "$_clickhouse_source" == "in-cluster" ]]; then
    cat > "$VALUES_DIR/langsmith-values-insights.yaml" << 'INSIGHTS_EOF'
# Insights — ClickHouse-backed analytics (in-cluster ClickHouse).
# clickhouse_source = "in-cluster" — the Helm chart manages ClickHouse.
# No external ClickHouse configuration needed.
config:
  insights:
    enabled: true
INSIGHTS_EOF
    pass "Generated: langsmith-values-insights.yaml (in-cluster ClickHouse mode)"
  else
    _copy_addon "insights"
    warn "External ClickHouse: edit langsmith-values-insights.yaml and set host/credentials before deploying."
  fi
fi

_enable_polly=$(_parse_tfvar "enable_polly") || _enable_polly="false"
[[ "$_enable_polly"         == "true" ]] && _copy_addon "polly"

# Patch tlsEnabled in agent-deploys — derive from tls_certificate_source.
# Example file defaults to false; patch so operator builds https:// agent URLs.
_deploys_file="$VALUES_DIR/langsmith-values-agent-deploys.yaml"
if [[ -f "$_deploys_file" && "$_enable_deployments" == "true" ]]; then
  if [[ "$_tls_source" == "letsencrypt" || "$_tls_source" == "acm" ]]; then
    sed -i.bak 's/tlsEnabled: false/tlsEnabled: true/' "$_deploys_file" && rm -f "$_deploys_file.bak"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  init-values complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  hostname       = $HOSTNAME"
echo "  admin email    = $ADMIN_EMAIL"
echo "  sizing profile = $_sizing_profile"
echo "  protocol       = $_protocol"
echo ""
echo "Next:"
echo "  Review: ${OUT_FILE}"
echo "  Deploy: make deploy"
echo ""
