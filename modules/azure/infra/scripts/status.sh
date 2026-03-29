#!/usr/bin/env bash
# status.sh — Check the current state of the Azure LangSmith deployment
#             and tell you what to run next.
#
# Usage (from azure/):
#   ./infra/scripts/status.sh          # full check
#   ./infra/scripts/status.sh --quick  # skip slow checks (Key Vault, K8s)
#
# Also available as: make status
#
# No set -euo pipefail — this is a diagnostic script that must run every check
# regardless of individual failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

AZURE_DIR="$INFRA_DIR/.."
HELM_DIR="$AZURE_DIR/helm"
VALUES_DIR="$HELM_DIR/values"
APP_DIR="$AZURE_DIR/app"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

NEXT_ACTION=""
set_next() { [[ -z "$NEXT_ACTION" ]] && NEXT_ACTION="$1"; }

_read_tfvar() { _parse_tfvar "$1"; }

# ── 1. Configuration ─────────────────────────────────────────────────────────
header "1. Configuration (terraform.tfvars)"

if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  pass "terraform.tfvars exists"
  _identifier=$(_read_tfvar identifier)
  _environment=$(_read_tfvar environment)
  _location=$(_read_tfvar location)
  _subscription=$(_read_tfvar subscription_id)
  _tls=$(_read_tfvar tls_certificate_source)
  _pg_source=$(_read_tfvar postgres_source)
  _redis_source=$(_read_tfvar redis_source)
  _sizing=$(_read_tfvar sizing_profile)
  _kv_name="langsmith-kv${_identifier}"

  if [[ -n "$_subscription" ]]; then
    pass "Required fields: subscription_id set  identifier=${_identifier:-'(empty)'}  environment=${_environment:-dev}"
  else
    fail "Missing required field: subscription_id"
    action "Edit infra/terraform.tfvars — fill in subscription_id"
    set_next "Edit infra/terraform.tfvars — fill in subscription_id"
  fi
  [[ -n "$_tls" ]] && info "TLS: ${_tls}" || info "TLS: not set (defaults to none)"
  info "Services: postgres=${_pg_source:-external}  redis=${_redis_source:-external}"
  info "Location: ${_location:-eastus}"
  [[ -n "$_sizing" ]] && info "Sizing profile: ${_sizing}" || info "Sizing profile: default"
else
  fail "terraform.tfvars not found"
  action "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
  set_next "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
fi

# ── 2. Secrets File ───────────────────────────────────────────────────────────
header "2. Secrets (secrets.auto.tfvars)"

_secrets_file="$INFRA_DIR/secrets.auto.tfvars"
if [[ -f "$_secrets_file" ]]; then
  pass "secrets.auto.tfvars exists"
  _license=$(grep "langsmith_license_key" "$_secrets_file" 2>/dev/null | cut -d'"' -f2 || echo "")
  _pg_pw=$(grep "postgres_admin_password" "$_secrets_file" 2>/dev/null | cut -d'"' -f2 || echo "")
  [[ -n "$_license" ]] && pass "langsmith_license_key is set" || fail "langsmith_license_key is empty"
  [[ -n "$_pg_pw" ]] && pass "postgres_admin_password is set" || fail "postgres_admin_password is empty"
else
  fail "secrets.auto.tfvars not found"
  action "bash infra/setup-env.sh"
  set_next "bash infra/setup-env.sh"
fi

# ── 3. Azure Credentials ──────────────────────────────────────────────────────
header "3. Azure Credentials"

if az account show &>/dev/null; then
  _account=$(az account show --query user.name -o tsv 2>/dev/null) || _account=""
  _sub_name=$(az account show --query name -o tsv 2>/dev/null) || _sub_name=""
  _sub_id=$(az account show --query id -o tsv 2>/dev/null) || _sub_id=""
  if [[ -n "$_account" ]]; then
    pass "az credentials active — user: ${_account}"
    info "Subscription: ${_sub_name} (${_sub_id})"
    if [[ -n "${_subscription:-}" && "$_sub_id" != "$_subscription" ]]; then
      warn "Active subscription differs from terraform.tfvars subscription_id"
      action "az account set --subscription ${_subscription}"
    fi
  else
    fail "az credentials not found"
    action "az login"
    set_next "az login"
  fi
else
  fail "az CLI not found or not logged in"
  action "az login"
  set_next "az login"
fi

# ── 4. Key Vault Secrets ──────────────────────────────────────────────────────
header "4. Key Vault Secrets (${_kv_name:-?})"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_kv_name:-}" || "$_kv_name" == "langsmith-kv" ]]; then
  skip "Cannot check — identifier not set in terraform.tfvars"
elif ! az keyvault show --name "$_kv_name" --output none 2>/dev/null; then
  skip "Key Vault '${_kv_name}' not found (created by terraform apply)"
  action "terraform -chdir=infra apply"
  set_next "terraform -chdir=infra apply"
else
  _required_kv_secrets=(
    langsmith-license-key
    langsmith-api-key-salt
    langsmith-jwt-secret
    langsmith-admin-password
  )
  _optional_kv_secrets=(
    langsmith-deployments-encryption-key
    langsmith-agent-builder-encryption-key
    langsmith-insights-encryption-key
    langsmith-polly-encryption-key
  )

  _kv_ok=true
  for secret in "${_required_kv_secrets[@]}"; do
    if az keyvault secret show --vault-name "$_kv_name" --name "$secret" \
        --query value -o tsv &>/dev/null 2>&1; then
      pass "KV: ${secret}"
    else
      fail "KV: ${secret} — missing"
      _kv_ok=false
    fi
  done

  for secret in "${_optional_kv_secrets[@]}"; do
    if az keyvault secret show --vault-name "$_kv_name" --name "$secret" \
        --query value -o tsv &>/dev/null 2>&1; then
      pass "KV: ${secret} (optional)"
    else
      skip "KV: ${secret} (optional — needed for advanced features)"
    fi
  done

  if [[ "$_kv_ok" == "false" ]]; then
    action "bash infra/setup-env.sh  (re-run after terraform apply)"
    set_next "Resolve missing Key Vault secrets"
  fi
fi

# ── 5. Terraform Infrastructure ───────────────────────────────────────────────
header "5. Terraform Infrastructure (Pass 1)"

if [[ -d "$INFRA_DIR/.terraform" ]]; then
  pass "terraform init — done"
else
  fail "terraform init — not run"
  action "make init"
  set_next "make init"
fi

_tf_output=""
if [[ -d "$INFRA_DIR/.terraform" ]]; then
  _tf_output=$(terraform -chdir="$INFRA_DIR" output -json 2>/dev/null) || _tf_output=""
fi

if [[ -n "$_tf_output" ]] && echo "$_tf_output" | grep -q '"aks_cluster_name"'; then
  pass "terraform apply — infrastructure provisioned"

  _cluster_name=$(echo "$_tf_output"  | jq -r '.aks_cluster_name.value   // empty' 2>/dev/null) || _cluster_name=""
  _rg_name=$(echo "$_tf_output"       | jq -r '.resource_group_name.value // empty' 2>/dev/null) || _rg_name=""
  _kv_tf_name=$(echo "$_tf_output"    | jq -r '.keyvault_name.value       // empty' 2>/dev/null) || _kv_tf_name=""
  _storage_account=$(echo "$_tf_output" | jq -r '.storage_account_name.value // empty' 2>/dev/null) || _storage_account=""
  _langsmith_url=$(echo "$_tf_output" | jq -r '.langsmith_url.value       // empty' 2>/dev/null) || _langsmith_url=""

  [[ -n "$_cluster_name" ]]    && info "AKS cluster: ${_cluster_name}"      || warn "No aks_cluster_name output"
  [[ -n "$_rg_name" ]]         && info "Resource group: ${_rg_name}"
  [[ -n "$_kv_tf_name" ]]      && info "Key Vault: ${_kv_tf_name}"
  [[ -n "$_storage_account" ]] && info "Storage account: ${_storage_account}" || warn "No storage_account_name output"
  [[ -n "$_langsmith_url" ]]   && info "LangSmith URL: ${_langsmith_url}"
else
  fail "terraform output — empty (no state file or infra not yet applied)"
  action "make apply  (if starting fresh)"
  set_next "make apply"
fi

# ── 6. Kubeconfig ─────────────────────────────────────────────────────────────
header "6. Kubeconfig"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_cluster_name:-}" ]]; then
  skip "Cannot check — no aks_cluster_name from terraform output"
else
  _current_ctx=$(kubectl config current-context 2>/dev/null) || _current_ctx=""
  if [[ "$_current_ctx" == *"${_cluster_name}"* ]]; then
    pass "kubectl context points to ${_cluster_name}"
  elif [[ -n "$_current_ctx" ]]; then
    warn "kubectl context is '${_current_ctx}' — expected *${_cluster_name}*"
    action "make kubeconfig"
    set_next "make kubeconfig"
  else
    fail "No kubectl context set"
    action "make kubeconfig"
    set_next "make kubeconfig"
  fi

  if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    pass "kubectl can reach the cluster"

    # Node readiness
    if NODES=$(kubectl get nodes --no-headers 2>/dev/null); then
      READY=$(echo "$NODES" | grep -c " Ready " || true)
      TOTAL=$(echo "$NODES" | wc -l | tr -d ' ')
      if [[ "$READY" == "$TOTAL" ]]; then
        pass "$READY/$TOTAL nodes Ready"
      else
        warn "$READY/$TOTAL nodes Ready"
        echo "$NODES"
      fi
    fi

    # Bootstrap components
    for ns in cert-manager keda ingress-nginx; do
      if kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Running\|Completed" | grep -q .; then
        warn "$ns: some pods not Running"
      else
        _running_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c Running || echo 0)
        pass "$ns: ${_running_count} pod(s) Running"
      fi
    done
  else
    fail "kubectl cannot reach the cluster"
    action "make kubeconfig"
  fi
fi

# ── 7. Helm Values ────────────────────────────────────────────────────────────
header "7. Helm Values"

_base_values="$VALUES_DIR/values.yaml"
_overrides="$VALUES_DIR/values-overrides.yaml"

if [[ -f "$_base_values" ]]; then
  pass "values.yaml (base)"
else
  warn "values.yaml (base) — not found (will use overrides only)"
fi

if [[ -f "$_overrides" ]]; then
  pass "values-overrides.yaml exists"
  _hostname=$(grep -E '^\s*hostname:' "$_overrides" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
  if [[ -n "$_hostname" && "$_hostname" != *"placeholder"* && "$_hostname" != *"<"* ]]; then
    info "hostname: ${_hostname}"
  else
    warn "hostname is blank or placeholder in values-overrides.yaml"
    action "make init-values  (generates values-overrides.yaml from terraform outputs)"
    set_next "make init-values"
  fi
else
  fail "values-overrides.yaml — not generated"
  action "make init-values  (or: ./helm/scripts/init-values.sh)"
  set_next "make init-values"
fi

# Addon files
for addon in sizing-ha sizing-dev sizing-minimum agent-deploys agent-builder insights polly; do
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ -f "$f" ]]; then
    pass "langsmith-values-${addon}.yaml (addon active)"
  else
    skip "langsmith-values-${addon}.yaml — not enabled"
  fi
done

# ── 8. Kubernetes Resources ───────────────────────────────────────────────────
header "8. Kubernetes Resources"

_NAMESPACE="${NAMESPACE:-langsmith}"
_k8s_reachable=false

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
  skip "Cannot check — cluster unreachable"
else
  _k8s_reachable=true

  if kubectl get namespace "$_NAMESPACE" &>/dev/null; then
    pass "Namespace: ${_NAMESPACE}"
  else
    warn "Namespace '${_NAMESPACE}' does not exist (created by terraform apply)"
  fi

  # K8s secrets created by k8s-bootstrap
  for secret in langsmith-postgres-secret langsmith-redis-secret langsmith-config-secret; do
    if kubectl get secret "$secret" -n "$_NAMESPACE" &>/dev/null; then
      pass "Secret: ${secret}"
    else
      if [[ "$secret" == "langsmith-config-secret" ]]; then
        skip "Secret: ${secret} — not created yet (run: make k8s-secrets)"
      else
        skip "Secret: ${secret} — not created yet"
      fi
    fi
  done

  # Workload Identity annotation on langsmith-ksa
  _ksa_annotation=$(kubectl get serviceaccount langsmith-ksa -n "$_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null) || _ksa_annotation=""
  if [[ -n "$_ksa_annotation" ]]; then
    pass "langsmith-ksa Workload Identity annotation: ${_ksa_annotation}"
  else
    skip "langsmith-ksa WI annotation not set (set by Terraform k8s-bootstrap)"
  fi
fi

# ── 9. Helm Release ───────────────────────────────────────────────────────────
header "9. Helm Release"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ "$_k8s_reachable" != "true" ]]; then
  skip "Cannot check — cluster unreachable"
else
  _helm_json=$(helm status langsmith -n "$_NAMESPACE" -o json 2>/dev/null) || _helm_json=""

  if [[ -n "$_helm_json" ]]; then
    _helm_status=$(echo "$_helm_json" | grep -o '"status":"[^"]*"' | head -1 \
      | sed 's/"status":"//;s/"//') || _helm_status=""
    _helm_version=$(echo "$_helm_json" | grep -o '"chart":"[^"]*"' \
      | sed 's/"chart":"//;s/"//') || _helm_version=""
    _helm_app_version=$(echo "$_helm_json" | grep -o '"app_version":"[^"]*"' \
      | sed 's/"app_version":"//;s/"//') || _helm_app_version=""

    if [[ "$_helm_status" == "deployed" ]]; then
      pass "Helm release: langsmith — deployed"
      [[ -n "$_helm_version" ]]     && info "Chart: ${_helm_version}"
      [[ -n "$_helm_app_version" ]] && info "App version: ${_helm_app_version}"
    elif [[ "$_helm_status" == "pending-upgrade" ]]; then
      fail "Helm release: langsmith — stuck in pending-upgrade (interrupted upgrade)"
      action "helm rollback langsmith -n ${_NAMESPACE}"
    elif [[ "$_helm_status" == "pending-install" ]]; then
      fail "Helm release: langsmith — stuck in pending-install"
      action "helm uninstall langsmith -n ${_NAMESPACE}  then re-run make deploy"
    elif [[ "$_helm_status" == "failed" ]]; then
      warn "Helm release: langsmith — status 'failed' (likely a prior --wait timeout)"
      info "Pods may still be running — re-run make deploy"
      [[ -n "$_helm_version" ]] && info "Chart: ${_helm_version}"
    else
      warn "Helm release: langsmith — status: ${_helm_status}"
    fi
  else
    skip "Helm release: langsmith — not installed"
    action "make deploy"
    set_next "make deploy"
  fi

  # Pod health
  if kubectl get namespace "$_NAMESPACE" &>/dev/null; then
    _total=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    _running=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null \
      | awk '{print $3}' | grep -c "Running" || true)
    _not_running=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" {print $1 " (" $3 ")"}' || true)

    if (( _total == 0 )); then
      skip "No pods in ${_NAMESPACE} namespace"
    elif [[ -z "$_not_running" ]]; then
      pass "Pods: ${_running}/${_total} running"
    else
      warn "Pods: ${_running}/${_total} running"
      while IFS= read -r line; do
        [[ -n "$line" ]] && fail "  $line"
      done <<< "$_not_running"
      action "kubectl describe pod <name> -n ${_NAMESPACE}  (check events)"
    fi
  fi

  # Ingress LoadBalancer IP — check the right service per ingress_controller
  _ingress_controller=$(_read_tfvar ingress_controller 2>/dev/null) || _ingress_controller="nginx"
  case "${_ingress_controller:-nginx}" in
    nginx)
      _lb_svc="ingress-nginx-controller"; _lb_ns="ingress-nginx" ;;
    istio-addon)
      _lb_svc="aks-istio-ingressgateway-external"; _lb_ns="aks-istio-ingress" ;;
    istio)
      _lb_svc="istio-ingressgateway"; _lb_ns="istio-system" ;;
    envoy-gateway)
      _lb_svc="envoy-langsmith-langsmith-gateway"; _lb_ns="langsmith" ;;
    *)
      _lb_svc=""; _lb_ns="" ;;
  esac

  if [[ -n "$_lb_svc" ]]; then
    _ingress_ip=$(kubectl get svc "$_lb_svc" -n "$_lb_ns" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || _ingress_ip=""
    if [[ -n "$_ingress_ip" ]]; then
      pass "Ingress IP (${_ingress_controller}): ${_ingress_ip}"
      if [[ -n "${_hostname:-}" && "$_hostname" != "$_ingress_ip" ]]; then
        info "(Point your DNS A record for ${_hostname} to ${_ingress_ip})"
      fi
    else
      skip "Ingress IP (${_ingress_controller}) not yet assigned"
    fi
  fi

  # Ingress and TLS certificate
  kubectl get ingress -n "$_NAMESPACE" 2>/dev/null || true
  CERT_STATUS=$(kubectl get certificate -n "$_NAMESPACE" --no-headers 2>/dev/null) || CERT_STATUS=""
  if [[ -n "$CERT_STATUS" ]]; then
    echo "$CERT_STATUS" | while read -r line; do
      if echo "$line" | grep -q "True"; then
        pass "cert: $line"
      else
        warn "cert: $line"
      fi
    done
  else
    info "No certificate resources (TLS not configured or using existing secret)"
  fi

  # langsmith-config-secret key count
  if [[ "$QUICK" == "false" ]]; then
    ACTUAL_KEYS=$(kubectl get secret langsmith-config-secret -n "$_NAMESPACE" \
      -o json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']))" 2>/dev/null) || ACTUAL_KEYS=0
    if [[ "$ACTUAL_KEYS" -ge 8 ]]; then
      pass "langsmith-config-secret: $ACTUAL_KEYS keys present"
    else
      warn "langsmith-config-secret: $ACTUAL_KEYS key(s) — expected 8. Run: make k8s-secrets"
      set_next "make k8s-secrets"
    fi
  fi
fi

# ── 10. Terraform Helm App (alternative Pass 2 path) ─────────────────────────
header "10. Terraform Helm App (alternative path)"

if [[ -d "$APP_DIR" ]]; then
  if [[ -f "$APP_DIR/infra.auto.tfvars.json" ]]; then
    pass "infra.auto.tfvars.json exists (make init-app was run)"
  else
    skip "infra.auto.tfvars.json — not generated"
    action "make init-app  (if using Terraform Helm path instead of scripts)"
  fi

  _app_output=""
  if [[ -d "$APP_DIR/.terraform" ]]; then
    _app_output=$(terraform -chdir="$APP_DIR" output -json 2>/dev/null) || _app_output=""
  fi

  if [[ -n "$_app_output" ]] && echo "$_app_output" | grep -q '"value"'; then
    pass "app/ terraform — applied"
    _app_chart=$(echo "$_app_output" | grep -A2 '"helm_chart_version"' \
      | grep '"value"' | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _app_chart=""
    [[ -n "$_app_chart" ]] && info "Chart version: ${_app_chart}"
  elif [[ -d "$APP_DIR/.terraform" ]]; then
    skip "app/ terraform — initialized but not applied"
    action "make apply-app"
  else
    skip "app/ terraform — not initialized (using shell deploy path, or not started)"
  fi
else
  skip "app/ directory not present"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Next Step"

if [[ -n "$NEXT_ACTION" ]]; then
  printf "\n  $(_yellow "▶")  $(_bold "%s")\n\n" "$NEXT_ACTION"
else
  printf "\n  $(_green "✔")  $(_bold "All checks passed — deployment looks healthy")\n\n"
fi
