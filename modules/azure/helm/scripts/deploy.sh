#!/usr/bin/env bash
# deploy.sh — Deploy or upgrade LangSmith via Helm on Azure.
#
# Values files loaded (in order, last wins):
#   1. values.yaml                               — base Azure config (always)
#   2. values-overrides.yaml                     — env-specific: hostname, WI, blob (required)
#   3. langsmith-values-sizing-{profile}.yaml    — sizing profile (from sizing_profile in terraform.tfvars)
#   4. langsmith-values-agent-deploys.yaml       — Deployments feature (if enable_deployments = true)
#   5. langsmith-values-agent-builder.yaml       — Agent Builder (if enable_agent_builder = true)
#   6. langsmith-values-insights.yaml            — Insights/Clio (if enable_insights = true)
#   7. langsmith-values-polly.yaml               — Polly (if enable_polly = true)
#
# Generate values files first: make init-values (or: ./helm/scripts/init-values.sh)
# Templates live in helm/values/examples/ — init-values.sh copies them based on your choices.
#
# Usage (from azure/):
#   ./helm/scripts/deploy.sh
#   CHART_VERSION=0.13.29 ./helm/scripts/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/.."
INFRA_DIR="$HELM_DIR/../infra"
VALUES_DIR="$HELM_DIR/values"

source "$INFRA_DIR/scripts/_common.sh"

RELEASE_NAME="${RELEASE_NAME:-langsmith}"
NAMESPACE="${NAMESPACE:-langsmith}"
CHART_VERSION="${CHART_VERSION:-}"

BASE_VALUES_FILE="$VALUES_DIR/values.yaml"
OVERRIDES_FILE="$VALUES_DIR/values-overrides.yaml"

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith Azure — Helm Deploy"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Validate required values files ────────────────────────────────────────
if [[ ! -f "$OVERRIDES_FILE" ]]; then
  fail "values-overrides.yaml not found"
  action "make init-values  (generates it from terraform outputs)"
  exit 1
fi

# ── Point kubeconfig at the right cluster ─────────────────────────────────
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw aks_cluster_name 2>/dev/null) || {
  fail "Could not read aks_cluster_name. Is 'terraform apply' complete?"
  exit 1
}
_rg_name=$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name 2>/dev/null) || _rg_name=""

info "Cluster: ${_cluster_name}"
az aks get-credentials --name "$_cluster_name" --resource-group "$_rg_name" \
  --overwrite-existing &>/dev/null
info "Active context: $(kubectl config current-context)"
echo ""

# ── Set NGINX DNS label annotation ───────────────────────────────────────
# Azure assigns <nginx_dns_label>.<region>.cloudapp.azure.com to the public IP
# only when this annotation is present on the LoadBalancer service.
# cert-manager's HTTP-01 challenge depends on DNS resolving — must be set before deploy.
_nginx_dns_label=$(_parse_tfvar "nginx_dns_label") || _nginx_dns_label=""
_location=$(_parse_tfvar "location") || _location="eastus"
if [[ -n "$_nginx_dns_label" ]]; then
  if kubectl get svc ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
      "service.beta.kubernetes.io/azure-dns-label-name=${_nginx_dns_label}" \
      --overwrite &>/dev/null
    pass "NGINX DNS label set: ${_nginx_dns_label}.${_location}.cloudapp.azure.com"
  else
    warn "ingress-nginx-controller service not found — DNS label not set (run make apply first)"
  fi
fi

# ── Apply letsencrypt-prod ClusterIssuer ──────────────────────────────────
# kubernetes_manifest in Terraform can't create this on fresh deploy (no cluster
# exists during plan). Applied here instead — idempotent, safe to re-run.
_tls_source=$(_parse_tfvar "tls_certificate_source") || _tls_source=""
if [[ "$_tls_source" == "letsencrypt" ]]; then
  _le_email=$(_parse_tfvar "letsencrypt_email") || _le_email=""
  if kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
    pass "ClusterIssuer letsencrypt-prod already exists"
  else
    kubectl apply -f - &>/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${_le_email}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
    pass "ClusterIssuer letsencrypt-prod created"
  fi
fi

# ── Preflight checks ──────────────────────────────────────────────────────
"$SCRIPT_DIR/preflight-check.sh"

# ── Ensure langsmith-config-secret exists ─────────────────────────────────
info "Verifying langsmith-config-secret..."
if ! kubectl get secret langsmith-config-secret -n "$NAMESPACE" &>/dev/null; then
  warn "langsmith-config-secret not found — creating from Key Vault..."
  bash "$INFRA_DIR/scripts/create-k8s-secrets.sh"
else
  pass "langsmith-config-secret exists"
fi

# Note: langsmith-clickhouse secret not checked here — in-cluster ClickHouse
# is managed by the chart. External ClickHouse requires a separate secret;
# see langsmith-values-insights.yaml for instructions.

# ── Pre-deploy hostname check ─────────────────────────────────────────────
_configured_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _configured_hostname=""
if [[ -n "$_configured_hostname" && "$_configured_hostname" == *"<"* ]]; then
  warn "config.hostname still contains a placeholder — run: make init-values"
fi

# ── Read feature flags from terraform.tfvars ──────────────────────────────
_sizing_profile=$(_parse_tfvar "sizing_profile") || _sizing_profile="default"
_enable_deployments=false
_enable_agent_builder=false
_enable_insights=false
_enable_polly=false
_tfvar_is_true "enable_deployments"   && _enable_deployments=true  || true
_tfvar_is_true "enable_agent_builder" && _enable_agent_builder=true || true
_tfvar_is_true "enable_insights"      && _enable_insights=true     || true
_tfvar_is_true "enable_polly"         && _enable_polly=true        || true

# Validate addon dependencies
if [[ "$_enable_agent_builder" == "true" && "$_enable_deployments" != "true" ]]; then
  fail "enable_agent_builder = true requires enable_deployments = true in terraform.tfvars"
  exit 1
fi

# ── Build values args ─────────────────────────────────────────────────────
VALUES_ARGS=()

# Base values (optional — provides Azure defaults + production sizing)
if [[ -f "$BASE_VALUES_FILE" ]]; then
  VALUES_ARGS+=(-f "$BASE_VALUES_FILE")
  echo "Values chain:"
  echo "  ✔ values.yaml (base)"
else
  echo "Values chain:"
  echo "  ○ values.yaml (not found — using overrides only)"
fi

VALUES_ARGS+=(-f "$OVERRIDES_FILE")
echo "  ✔ values-overrides.yaml"

# Sizing profile
if [[ "$_sizing_profile" != "default" ]]; then
  _sizing_file="$VALUES_DIR/langsmith-values-sizing-${_sizing_profile}.yaml"
  if [[ -f "$_sizing_file" ]]; then
    VALUES_ARGS+=(-f "$_sizing_file")
    echo "  ✔ langsmith-values-sizing-${_sizing_profile}.yaml (sizing_profile = ${_sizing_profile})"
    if [[ "$_sizing_profile" == "minimum" ]]; then
      echo ""
      echo "  ⚠️  WARNING: sizing_profile = minimum — NOT for production."
      echo "     Use sizing_profile = production for production deployments."
      echo ""
    fi
  else
    echo "  ✗ langsmith-values-sizing-${_sizing_profile}.yaml (not found — run: make init-values)"
  fi
else
  echo "  ○ sizing: base values defaults (sizing_profile = default)"
fi

# Addon overlays
_addon_gate=(
  "agent-deploys:deployments:$_enable_deployments"
  "agent-builder:agent_builder:$_enable_agent_builder"
  "insights:insights:$_enable_insights"
  "polly:polly:$_enable_polly"
)
for entry in "${_addon_gate[@]}"; do
  addon="${entry%%:*}"
  rest="${entry#*:}"
  flag_name="${rest%%:*}"
  enabled="${rest##*:}"
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ "$enabled" == "true" ]]; then
    if [[ -f "$f" ]]; then
      VALUES_ARGS+=(-f "$f")
      echo "  ✔ langsmith-values-${addon}.yaml (enable_${flag_name} = true)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (enable_${flag_name} = true but file not found — run: make init-values)"
    fi
  else
    if [[ -f "$f" ]]; then
      echo "  ○ langsmith-values-${addon}.yaml (file exists but enable_${flag_name} = false — skipped)"
    else
      echo "  ✗ langsmith-values-${addon}.yaml (not enabled)"
    fi
  fi
done
echo ""

# ── Chart version ─────────────────────────────────────────────────────────
# Read from terraform.tfvars first, then env var, then prompt (interactive only)
if [[ -z "$CHART_VERSION" ]]; then
  CHART_VERSION=$(_parse_tfvar "langsmith_helm_chart_version") || CHART_VERSION=""
fi

if [[ -z "$CHART_VERSION" ]]; then
  helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
  helm repo update langchain &>/dev/null
  echo "Available chart versions:"
  helm search repo langchain/langsmith --versions | head -6
  echo ""
  if [[ -t 0 ]]; then
    # Interactive terminal — prompt for version
    printf "  Chart version to deploy (e.g. 0.13.29, or press Enter for latest): "
    read -r CHART_VERSION
  else
    # Non-interactive — default to latest
    info "Non-interactive mode: deploying latest chart version"
  fi
fi

# ── Pending-upgrade guard ─────────────────────────────────────────────────
_release_status=$(helm list -n "$NAMESPACE" --filter "^${RELEASE_NAME}$" --output json 2>/dev/null \
  | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//' || true)
if [[ "$_release_status" == "pending-upgrade" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'pending-upgrade' state (interrupted upgrade)."
  info "Rolling back to clear the lock..."
  helm rollback "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m
  echo ""
elif [[ "$_release_status" == "failed" ]]; then
  warn "Helm release '${RELEASE_NAME}' is in 'failed' state."
  info "This is usually caused by a hook timeout — proceeding with upgrade."
  echo ""
fi

# ── Deploy ────────────────────────────────────────────────────────────────
info "Deploying LangSmith (sizing: ${_sizing_profile})..."
info "(waiting for pods — 5-15 min on a cold cluster)"
echo ""

helm repo add langchain https://langchain-ai.github.io/helm 2>/dev/null || true
helm repo update langchain &>/dev/null

helm upgrade --install "$RELEASE_NAME" langchain/langsmith \
  --namespace "$NAMESPACE" \
  --create-namespace \
  ${CHART_VERSION:+--version "$CHART_VERSION"} \
  "${VALUES_ARGS[@]}" \
  ${EXTRA_HELM_ARGS:+$EXTRA_HELM_ARGS} \
  --server-side=false \
  --timeout 20m

echo ""
pass "LangSmith deployed. Waiting for core pods..."
echo ""

# ── Wait for core components ──────────────────────────────────────────────
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

_all_ready=true
for dep in "${_core_deployments[@]}"; do
  if ! kubectl rollout status "deployment/$dep" -n "$NAMESPACE" --timeout=5m 2>/dev/null; then
    warn "$dep not ready within 5m (may still be starting)"
    _all_ready=false
  fi
done

if [[ "$_all_ready" == "true" ]]; then
  pass "All core deployments ready"
else
  warn "Some deployments are still rolling out — check with: kubectl get pods -n $NAMESPACE"
fi
echo ""

# ── Ensure langsmith-ksa carries the WI annotation ───────────────────────
# langsmith-ksa is used by operator-spawned agent deployment pods.
# It is created by the operator on first use (not part of Helm release).
_wi_client_id=$(terraform -chdir="$INFRA_DIR" output -raw storage_account_k8s_managed_identity_client_id 2>/dev/null || true)
if [[ -n "$_wi_client_id" ]]; then
  kubectl create serviceaccount langsmith-ksa -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  kubectl annotate serviceaccount langsmith-ksa -n "$NAMESPACE" \
    azure.workload.identity/client-id="$_wi_client_id" --overwrite &>/dev/null
  pass "langsmith-ksa WI annotation: ${_wi_client_id}"
fi

# ── Post-deploy access info ───────────────────────────────────────────────
_hostname=$(grep -E '^\s*hostname:' "$OVERRIDES_FILE" 2>/dev/null \
  | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
_kv_name=$(terraform -chdir="$INFRA_DIR" output -raw keyvault_name 2>/dev/null || true)
_admin_email=$(terraform -chdir="$INFRA_DIR" output -raw langsmith_admin_email 2>/dev/null || true)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith deployed"
echo "══════════════════════════════════════════════════════"
echo ""
[[ -n "$_hostname" ]] && echo "  URL      : https://${_hostname}"
[[ -n "$_admin_email" ]] && echo "  Login    : ${_admin_email}"
[[ -n "$_kv_name" ]] && echo "  Password : az keyvault secret show --vault-name ${_kv_name} --name langsmith-admin-password --query value -o tsv"
echo ""
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get ingress -n ${NAMESPACE}"
echo "  kubectl get certificate -n ${NAMESPACE}"
echo ""
echo "  make status   # for a full health check"
echo ""
