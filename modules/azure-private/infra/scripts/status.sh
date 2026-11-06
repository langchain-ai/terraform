#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# status.sh — Check the current state of the azure-private LangSmith deployment
#             and tell you what to run next. Tailored to this module's two-root
#             (infra/ + bootstrap/) no-make flow — see DEPLOYMENT.md.
#
# Usage (from infra/):
#   bash scripts/status.sh           # full check
#   bash scripts/status.sh --quick   # skip slow checks (Key Vault, Kubernetes)
#
# No set -euo pipefail — this is a diagnostic that must run every check
# regardless of individual failures. The AKS API server is private, so the
# Kubernetes checks only work from a host with VNet connectivity (the jumpbox).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

NEXT_ACTION=""
set_next() { [[ -z "$NEXT_ACTION" ]] && NEXT_ACTION="$1"; }

_read_tfvar() { _parse_tfvar "$1"; }

# ── 1. Configuration ─────────────────────────────────────────────────────────
header "1. Configuration (infra/terraform.tfvars)"

if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  pass "terraform.tfvars exists"
  _identifier=$(_read_tfvar identifier)
  _subscription=$(_read_tfvar subscription_id)
  _pg_source=$(_read_tfvar postgres_source)
  _redis_source=$(_read_tfvar redis_source)
  _kv_name="langsmith-kv${_identifier}"

  if [[ -n "$_subscription" ]]; then
    pass "Required fields: subscription_id set  identifier=${_identifier:-'(empty)'}"
  else
    fail "Missing required field: subscription_id"
    action "Edit infra/terraform.tfvars — fill in subscription_id"
    set_next "Edit infra/terraform.tfvars — fill in subscription_id"
  fi
  info "Services: postgres=${_pg_source:-external}  redis=${_redis_source:-external}"
else
  fail "terraform.tfvars not found"
  action "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
  set_next "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
fi

# ── 2. Secrets File ───────────────────────────────────────────────────────────
header "2. Secrets (infra/secrets.auto.tfvars)"

_secrets_file="$INFRA_DIR/secrets.auto.tfvars"
if [[ -f "$_secrets_file" ]]; then
  pass "secrets.auto.tfvars exists"
  _license=$(grep "langsmith_license_key" "$_secrets_file" 2>/dev/null | cut -d'"' -f2 || echo "")
  _pg_pw=$(grep "postgres_admin_password" "$_secrets_file" 2>/dev/null | cut -d'"' -f2 || echo "")
  [[ -n "$_license" ]] && pass "langsmith_license_key is set" || warn "langsmith_license_key is empty"
  [[ -n "$_pg_pw" ]] && pass "postgres_admin_password is set" || warn "postgres_admin_password is empty"
else
  skip "secrets.auto.tfvars not found (fine if you export TF_VAR_* directly)"
  action "bash scripts/setup-env.sh"
  set_next "bash scripts/setup-env.sh"
fi

# ── 3. Azure Credentials ──────────────────────────────────────────────────────
header "3. Azure Credentials"

if az account show &>/dev/null; then
  _account=$(az account show --query user.name -o tsv 2>/dev/null) || _account=""
  _sub_name=$(az account show --query name -o tsv 2>/dev/null) || _sub_name=""
  _sub_id=$(az account show --query id -o tsv 2>/dev/null) || _sub_id=""
  pass "az credentials active — user: ${_account:-unknown}"
  info "Subscription: ${_sub_name} (${_sub_id})"
  if [[ -n "${_subscription:-}" && "$_sub_id" != "$_subscription" ]]; then
    warn "Active subscription differs from terraform.tfvars subscription_id"
    action "az account set --subscription ${_subscription}"
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
    if az keyvault secret show --vault-name "$_kv_name" --name "$secret" --query value -o tsv &>/dev/null 2>&1; then
      pass "KV: ${secret}"
    else
      fail "KV: ${secret} — missing"
      _kv_ok=false
    fi
  done
  for secret in "${_optional_kv_secrets[@]}"; do
    if az keyvault secret show --vault-name "$_kv_name" --name "$secret" --query value -o tsv &>/dev/null 2>&1; then
      pass "KV: ${secret} (optional)"
    else
      skip "KV: ${secret} (optional — needed for advanced features)"
    fi
  done

  if [[ "$_kv_ok" == "false" ]]; then
    action "bash scripts/setup-env.sh  (re-run after terraform apply)"
    set_next "Resolve missing Key Vault secrets"
  fi
fi

# ── 5. Terraform Infrastructure (infra/) ──────────────────────────────────────
header "5. Terraform Infrastructure (infra/)"

if [[ -d "$INFRA_DIR/.terraform" ]]; then
  pass "terraform init — done"
else
  fail "terraform init — not run"
  action "terraform -chdir=infra init"
  set_next "terraform -chdir=infra init"
fi

_tf_output=""
if [[ -d "$INFRA_DIR/.terraform" ]]; then
  _tf_output=$(terraform -chdir="$INFRA_DIR" output -json 2>/dev/null) || _tf_output=""
fi

if [[ -n "$_tf_output" ]] && echo "$_tf_output" | grep -q '"aks_cluster_name"'; then
  pass "terraform apply — infrastructure provisioned"
  _cluster_name=$(echo "$_tf_output"    | jq -r '.aks_cluster_name.value     // empty' 2>/dev/null) || _cluster_name=""
  _rg_name=$(echo "$_tf_output"         | jq -r '.resource_group_name.value  // empty' 2>/dev/null) || _rg_name=""
  _kv_tf_name=$(echo "$_tf_output"      | jq -r '.keyvault_name.value        // empty' 2>/dev/null) || _kv_tf_name=""
  _storage_account=$(echo "$_tf_output" | jq -r '.storage_account_name.value // empty' 2>/dev/null) || _storage_account=""
  [[ -n "$_cluster_name" ]]    && info "AKS cluster: ${_cluster_name}"       || warn "No aks_cluster_name output"
  [[ -n "$_rg_name" ]]         && info "Resource group: ${_rg_name}"
  [[ -n "$_kv_tf_name" ]]      && info "Key Vault: ${_kv_tf_name}"
  [[ -n "$_storage_account" ]] && info "Storage account: ${_storage_account}"
else
  fail "terraform output — empty (no state, or infra not yet applied)"
  action "terraform -chdir=infra apply"
  set_next "terraform -chdir=infra apply"
fi

# ── 6. Kubeconfig + cluster ───────────────────────────────────────────────────
header "6. Kubeconfig + cluster"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_cluster_name:-}" ]]; then
  skip "Cannot check — no aks_cluster_name from terraform output"
else
  _get_creds="az aks get-credentials -g ${_rg_name:-<rg>} -n ${_cluster_name} --overwrite-existing"
  _current_ctx=$(kubectl config current-context 2>/dev/null) || _current_ctx=""
  if [[ "$_current_ctx" == *"${_cluster_name}"* ]]; then
    pass "kubectl context points to ${_cluster_name}"
  elif [[ -n "$_current_ctx" ]]; then
    warn "kubectl context is '${_current_ctx}' — expected *${_cluster_name}*"
    action "$_get_creds"
  else
    fail "No kubectl context set"
    action "$_get_creds"
    set_next "$_get_creds"
  fi

  if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    pass "kubectl can reach the cluster"
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
    # In-cluster bootstrap components (installed by bootstrap/ apply)
    for ns in keda ingress-nginx; do
      if kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -v "Running\|Completed" | grep -q .; then
        warn "$ns: some pods not Running"
      else
        _running_count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c Running || echo 0)
        pass "$ns: ${_running_count} pod(s) Running"
      fi
    done
  else
    skip "kubectl cannot reach the cluster — the API server is private; run from the jumpbox (inside the VNet)"
  fi
fi

# ── 7. Kubernetes resources ───────────────────────────────────────────────────
header "7. Kubernetes resources (namespace + secrets)"

_NAMESPACE="${NAMESPACE:-langsmith}"
_k8s_reachable=false

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
  skip "Cannot check — cluster unreachable (run from the jumpbox)"
else
  _k8s_reachable=true

  if kubectl get namespace "$_NAMESPACE" &>/dev/null; then
    pass "Namespace: ${_NAMESPACE}"
  else
    warn "Namespace '${_NAMESPACE}' does not exist (created by bootstrap/ apply)"
    action "terraform -chdir=bootstrap apply  (from the jumpbox)"
    set_next "terraform -chdir=bootstrap apply"
  fi

  # Connection secrets (bootstrap/ apply)
  for secret in langsmith-postgres-secret langsmith-redis-secret; do
    if kubectl get secret "$secret" -n "$_NAMESPACE" &>/dev/null; then
      pass "Secret: ${secret}"
    else
      skip "Secret: ${secret} — not created yet (bootstrap/ apply)"
    fi
  done

  # App-config secret (scripts/create-k8s-secrets.sh — Phase 3.5)
  if kubectl get secret langsmith-config-secret -n "$_NAMESPACE" &>/dev/null; then
    _cfg_keys=$(kubectl get secret langsmith-config-secret -n "$_NAMESPACE" -o json 2>/dev/null \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)['data']))" 2>/dev/null) || _cfg_keys=0
    pass "Secret: langsmith-config-secret (${_cfg_keys} keys)"
  else
    skip "Secret: langsmith-config-secret — not created yet"
    action "bash scripts/create-k8s-secrets.sh  (Phase 3.5)"
    set_next "bash scripts/create-k8s-secrets.sh"
  fi

  # TLS secret (scripts/create-tls-secret.sh — Phase 3.5)
  if kubectl get secret langsmith-tls -n "$_NAMESPACE" &>/dev/null; then
    pass "Secret: langsmith-tls (ingress TLS)"
  else
    skip "Secret: langsmith-tls — not created yet"
    action "bash scripts/create-tls-secret.sh --hostname <host>  (Phase 3.5)"
  fi
fi

# ── 8. Helm release ───────────────────────────────────────────────────────────
header "8. Helm release (langsmith)"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ "$_k8s_reachable" != "true" ]]; then
  skip "Cannot check — cluster unreachable"
else
  _helm_json=$(helm status langsmith -n "$_NAMESPACE" -o json 2>/dev/null) || _helm_json=""
  if [[ -n "$_helm_json" ]]; then
    _helm_status=$(echo "$_helm_json" | grep -o '"status":"[^"]*"' | head -1 | sed 's/"status":"//;s/"//') || _helm_status=""
    case "$_helm_status" in
      deployed)        pass "Helm release: langsmith — deployed" ;;
      pending-upgrade) fail "Helm release: langsmith — stuck pending-upgrade"; action "helm rollback langsmith -n ${_NAMESPACE}" ;;
      pending-install) fail "Helm release: langsmith — stuck pending-install"; action "helm uninstall langsmith -n ${_NAMESPACE}, then reinstall" ;;
      failed)          warn "Helm release: langsmith — 'failed' (likely a prior --wait timeout); pods may still be running" ;;
      *)               warn "Helm release: langsmith — status: ${_helm_status:-unknown}" ;;
    esac
  else
    skip "Helm release: langsmith — not installed"
    action "helm upgrade --install langsmith ...  (Phase 4 — see DEPLOYMENT.md)"
    set_next "Install LangSmith (DEPLOYMENT.md Phase 4)"
  fi

  # Pod health
  if kubectl get namespace "$_NAMESPACE" &>/dev/null; then
    _total=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    _running=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -c "Running" || true)
    _not_running=$(kubectl get pods -n "$_NAMESPACE" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print $1 " (" $3 ")"}' || true)
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

  # Internal NGINX ingress load-balancer IP (private)
  _ingress_ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || _ingress_ip=""
  if [[ -n "$_ingress_ip" ]]; then
    pass "Ingress private IP: ${_ingress_ip}"
    info "(Point your internal DNS for the LangSmith hostname at ${_ingress_ip})"
  else
    skip "Ingress IP not yet assigned (internal LB provisions once nginx is up)"
  fi
fi

# ── Next Step ─────────────────────────────────────────────────────────────────
header "Next Step"

if [[ -n "$NEXT_ACTION" ]]; then
  printf "\n  $(_yellow "▶")  $(_bold "%s")\n\n" "$NEXT_ACTION"
else
  printf "\n  $(_green "✔")  $(_bold "All checks passed — deployment looks healthy")\n\n"
fi
