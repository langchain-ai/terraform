#!/usr/bin/env bash

# MIT License - Copyright (c) 2024 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# status.sh — Check the current state of the GCP LangSmith deployment
#             and tell you what to run next.
#
# Usage (from gcp/):
#   ./infra/scripts/status.sh          # full check
#   ./infra/scripts/status.sh --quick  # skip slow checks (Secret Manager, K8s)
#
# Also available as: make status
#
# No set -euo pipefail — this is a diagnostic script that must run every check
# regardless of individual failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

GCP_DIR="$INFRA_DIR/.."
HELM_DIR="$GCP_DIR/helm"
VALUES_DIR="$HELM_DIR/values"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

NEXT_ACTION=""
set_next() { [[ -z "$NEXT_ACTION" ]] && NEXT_ACTION="$1"; }

# Alias for readability
_read_tfvar() { _parse_tfvar "$1"; }

# ── 1. Configuration ─────────────────────────────────────────────────────────
header "1. Configuration (terraform.tfvars)"

if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  pass "terraform.tfvars exists"
  _project_id=$(_read_tfvar project_id)
  _name_prefix=$(_read_tfvar name_prefix)
  _environment=$(_read_tfvar environment)
  _region=$(_read_tfvar region)
  _region="${_region:-us-west2}"
  _tls=$(_read_tfvar tls_certificate_source)
  _pg_source=$(_read_tfvar postgres_source)
  _redis_source=$(_read_tfvar redis_source)
  _ch_source=$(_read_tfvar clickhouse_source)

  if [[ -n "$_project_id" && -n "$_name_prefix" && -n "$_environment" ]]; then
    pass "Required fields: project_id=${_project_id}  name_prefix=${_name_prefix}  environment=${_environment}"
    _base_name="${_name_prefix}-${_environment}"
    _sm_prefix="langsmith-${_base_name}"
  else
    fail "Missing required fields (project_id, name_prefix, or environment)"
    action "Edit infra/terraform.tfvars — fill in project_id, name_prefix, environment"
    set_next "Edit infra/terraform.tfvars — fill in project_id, name_prefix, environment"
  fi
  [[ -n "$_tls" ]] && info "TLS: ${_tls}" || info "TLS: not set (defaults to none)"
  info "Services: postgres=${_pg_source:-external}  redis=${_redis_source:-external}  clickhouse=${_ch_source:-in-cluster}"
  info "Region: ${_region}"
else
  fail "terraform.tfvars not found"
  action "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
  set_next "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
fi

# ── 2. Environment Variables ──────────────────────────────────────────────────
header "2. Environment Variables (setup-env.sh)"

_check_var() {
  if [[ -n "$(printenv "$1" 2>/dev/null)" ]]; then
    pass "$1"
    return 0
  else
    fail "$1"
    return 1
  fi
}

_env_ok=true
for var in TF_VAR_project_id TF_VAR_name_prefix TF_VAR_postgres_password \
           TF_VAR_langsmith_license_key; do
  _check_var "$var" || _env_ok=false
done

# Encryption keys are optional — warn if feature flag is set but key is missing
for addon in deployments agent_builder insights; do
  _flag_name="enable_${addon}"
  _var_name="TF_VAR_langsmith_${addon}_encryption_key"
  if _tfvar_is_true "$_flag_name"; then
    _check_var "$_var_name" || {
      _env_ok=false
      warn "  enable_${addon}=true but ${_var_name} is not set"
    }
  else
    if [[ -n "$(printenv "$_var_name" 2>/dev/null)" ]]; then
      pass "${_var_name} (optional)"
    else
      skip "${_var_name} (optional — needed when enable_${addon}=true)"
    fi
  fi
done

if [[ "$_env_ok" == "false" ]]; then
  action "source infra/scripts/setup-env.sh"
  set_next "source infra/scripts/setup-env.sh"
fi

# ── 3. GCP Credentials ────────────────────────────────────────────────────────
header "3. GCP Credentials"

if gcloud auth list --filter="status=ACTIVE" --format="value(account)" &>/dev/null; then
  _account=$(gcloud auth list --filter="status=ACTIVE" --format="value(account)" 2>/dev/null | head -1)
  _proj=$(gcloud config get-value project 2>/dev/null) || _proj=""
  if [[ -n "$_account" ]]; then
    pass "gcloud credentials active — account: ${_account}"
    [[ -n "$_proj" ]] && info "Active project: ${_proj}" || info "No active project set (uses TF_VAR_project_id)"
  else
    fail "gcloud credentials not configured"
    action "gcloud auth login  OR  gcloud auth application-default login"
    set_next "Configure GCP credentials (gcloud auth login)"
  fi
else
  fail "gcloud not found or credentials not configured"
  action "gcloud auth application-default login"
  set_next "Configure GCP credentials (gcloud auth application-default login)"
fi

# ── 4. Secret Manager ─────────────────────────────────────────────────────────
header "4. Secret Manager (${_sm_prefix:-?})"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_sm_prefix:-}" ]]; then
  skip "Cannot check — terraform.tfvars missing project_id/name_prefix/environment"
elif ! gcloud services list --project="$_project_id" --filter="NAME=secretmanager.googleapis.com" \
    --format="value(NAME)" 2>/dev/null | grep -q secretmanager; then
  skip "Secret Manager API not enabled yet (enabled by terraform apply)"
else
  _required_secrets=(
    postgres-password
    langsmith-license-key
  )
  _optional_secrets=(
    deployments-encryption-key
    agent-builder-encryption-key
    insights-encryption-key
  )

  _sm_ok=true
  for secret in "${_required_secrets[@]}"; do
    _sid="${_sm_prefix}-${secret}"
    if gcloud secrets versions access latest --secret="$_sid" \
        --project="$_project_id" --quiet &>/dev/null; then
      pass "SM: ${secret}"
    else
      fail "SM: ${secret} — missing"
      _sm_ok=false
    fi
  done

  for secret in "${_optional_secrets[@]}"; do
    _sid="${_sm_prefix}-${secret}"
    if gcloud secrets versions access latest --secret="$_sid" \
        --project="$_project_id" --quiet &>/dev/null; then
      pass "SM: ${secret} (optional)"
    else
      skip "SM: ${secret} (optional)"
    fi
  done

  if [[ "$_sm_ok" == "false" ]]; then
    echo ""
    info "Missing secrets must be resolved before Secret Manager ESO sync works."
    action "source infra/scripts/setup-env.sh  (backfills SM from env vars, or prompts)"
    set_next "Resolve missing Secret Manager secrets (see section 4 above)"
  fi
fi

# ── 5. Terraform Infrastructure ───────────────────────────────────────────────
header "5. Terraform Infrastructure (Pass 1)"

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

if [[ -n "$_tf_output" ]] && echo "$_tf_output" | grep -q '"cluster_name"'; then
  pass "terraform apply — infrastructure provisioned"

  _cluster_name=$(echo "$_tf_output" | grep -A2 '"cluster_name"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _cluster_name=""
  _bucket_name=$(echo "$_tf_output" | grep -A2 '"bucket_name"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _bucket_name=""
  _wi_annotation=$(echo "$_tf_output" | grep -A2 '"workload_identity_annotation"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _wi_annotation=""
  _langsmith_url=$(echo "$_tf_output" | grep -A2 '"langsmith_url"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _langsmith_url=""

  [[ -n "$_cluster_name" ]] && info "GKE cluster: ${_cluster_name}"         || warn "No cluster_name output"
  [[ -n "$_bucket_name" ]]  && info "GCS bucket: ${_bucket_name}"           || warn "No bucket_name output"
  [[ -n "$_wi_annotation" ]] && info "Workload Identity GSA: ${_wi_annotation}"
  [[ -n "$_langsmith_url" ]] && info "LangSmith URL: ${_langsmith_url}"
  info "Services: postgres=${_pg_source:-?}  redis=${_redis_source:-?}  tls=${_tls:-?}"
else
  fail "terraform output — empty (no state file or infra not yet applied)"
  info "If infra was applied from another machine, configure a GCS remote backend."
  action "terraform -chdir=infra init  (if using a remote backend)"
  action "terraform -chdir=infra apply  (if starting fresh)"
  set_next "Resolve terraform state — see section 5"
fi

# ── 6. Kubeconfig ─────────────────────────────────────────────────────────────
header "6. Kubeconfig"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_cluster_name:-}" ]]; then
  skip "Cannot check — no cluster_name from terraform output"
else
  _current_ctx=$(kubectl config current-context 2>/dev/null) || _current_ctx=""
  if [[ "$_current_ctx" == *"${_cluster_name}"* ]]; then
    pass "kubectl context points to ${_cluster_name}"
  elif [[ -n "$_current_ctx" ]]; then
    warn "kubectl context is '${_current_ctx}' — expected *${_cluster_name}*"
    action "gcloud container clusters get-credentials ${_cluster_name} --region ${_region} --project ${_project_id}"
    set_next "gcloud container clusters get-credentials ${_cluster_name} --region ${_region} --project ${_project_id}"
  else
    fail "No kubectl context set"
    action "gcloud container clusters get-credentials ${_cluster_name} --region ${_region} --project ${_project_id}"
    set_next "gcloud container clusters get-credentials ${_cluster_name} --region ${_region} --project ${_project_id}"
  fi

  if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    pass "kubectl can reach the cluster"
  else
    fail "kubectl cannot reach the cluster"
    info "If the cluster endpoint is private, verify VPC access or authorized networks"
    action "Check network access to the GKE control plane"
  fi
fi

# ── 7. Helm Values ────────────────────────────────────────────────────────────
header "7. Helm Values"

_base_values="$VALUES_DIR/values.yaml"
_overrides="$VALUES_DIR/values-overrides.yaml"

if [[ -f "$_base_values" ]]; then
  pass "values.yaml (base)"
else
  fail "values.yaml (base) — missing"
fi

if [[ -f "$_overrides" ]]; then
  pass "values-overrides.yaml exists"
  _hostname=$(grep -E '^\s*hostname:' "$_overrides" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
  if [[ -n "$_hostname" ]]; then
    info "hostname: ${_hostname}"
  else
    warn "hostname is blank in values-overrides.yaml"
    action "Edit values/values-overrides.yaml — set config.hostname"
    set_next "Edit values/values-overrides.yaml — set config.hostname"
  fi
else
  fail "values-overrides.yaml — not generated"
  action "make init-values  (or: ./helm/scripts/init-values.sh)"
  set_next "make init-values"
fi

# Addon files
for addon in sizing-ha sizing-light agent-deploys agent-builder insights; do
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ -f "$f" ]]; then
    pass "langsmith-values-${addon}.yaml (addon)"
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

  # Namespace
  if kubectl get namespace "$_NAMESPACE" &>/dev/null; then
    pass "Namespace: ${_NAMESPACE}"
  else
    warn "Namespace '${_NAMESPACE}' does not exist (created by terraform or helm)"
  fi

  # Workload Identity annotation on langsmith-ksa
  _ksa_annotation=$(kubectl get serviceaccount langsmith-ksa -n "$_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null) || _ksa_annotation=""
  if [[ -n "$_ksa_annotation" ]]; then
    pass "langsmith-ksa Workload Identity annotation: ${_ksa_annotation}"
  else
    skip "langsmith-ksa WI annotation not set (set by deploy.sh post-deploy)"
  fi

  # K8s secrets created by k8s-bootstrap
  for secret in langsmith-postgres langsmith-redis; do
    if kubectl get secret "$secret" -n "$_NAMESPACE" &>/dev/null; then
      pass "Secret: ${secret}"
    else
      skip "Secret: ${secret} — not created yet"
    fi
  done
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
      fail "Helm release: langsmith — stuck in pending-install (interrupted install)"
      action "helm uninstall langsmith -n ${_NAMESPACE}  then re-run ./helm/scripts/deploy.sh"
    elif [[ "$_helm_status" == "failed" ]]; then
      warn "Helm release: langsmith — status 'failed' (likely a prior --wait timeout)"
      info "Pods may still be running — Helm marks failed if --wait times out"
      [[ -n "$_helm_version" ]] && info "Chart: ${_helm_version}"
      action "Re-run ./helm/scripts/deploy.sh  (upgrades over the failed release)"
    else
      warn "Helm release: langsmith — status: ${_helm_status}"
      action "./helm/scripts/deploy.sh"
    fi
  else
    skip "Helm release: langsmith — not installed"
    action "./helm/scripts/deploy.sh"
    set_next "./helm/scripts/deploy.sh"
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

  # Gateway IP (Envoy Gateway)
  _gateway_ip=$(kubectl get gateway -n "$_NAMESPACE" \
    -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null) || _gateway_ip=""
  if [[ -n "$_gateway_ip" ]]; then
    pass "Gateway IP: ${_gateway_ip}"
    if [[ -n "${_hostname:-}" && "$_hostname" != "$_gateway_ip" ]]; then
      info "(Point your DNS A record for ${_hostname} to ${_gateway_ip})"
    fi
  else
    _gateway_exists=$(kubectl get gateway -n "$_NAMESPACE" &>/dev/null && echo "yes" || echo "no")
    if [[ "$_gateway_exists" == "yes" ]]; then
      warn "Gateway exists but IP not yet assigned (~2 min to provision)"
    else
      skip "No gateway found in ${_NAMESPACE}"
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Next Step"

if [[ -n "$NEXT_ACTION" ]]; then
  printf "\n  $(_yellow "▶")  $(_bold "%s")\n\n" "$NEXT_ACTION"
else
  printf "\n  $(_green "✔")  $(_bold "All checks passed — deployment looks healthy")\n\n"
fi
