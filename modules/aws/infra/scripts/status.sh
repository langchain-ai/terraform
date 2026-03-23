#!/usr/bin/env bash
# status.sh — Check the current state of the AWS LangSmith deployment
#              and tell you what to run next.
#
# Usage (from aws/):
#   ./infra/scripts/status.sh          # full check
#   ./infra/scripts/status.sh --quick  # skip slow checks (SSM, K8s)
#
# Also available as: make status
# No set -euo pipefail — this is a diagnostic script that must run every check
# regardless of individual failures.
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

AWS_DIR="$INFRA_DIR/.."
HELM_DIR="$AWS_DIR/helm"
VALUES_DIR="$HELM_DIR/values"
APP_DIR="$AWS_DIR/app"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

NEXT_ACTION=""
set_next() { [[ -z "$NEXT_ACTION" ]] && NEXT_ACTION="$1"; }

# Alias for readability — _parse_tfvar comes from _common.sh
_read_tfvar() { _parse_tfvar "$1"; }

header "1. Configuration (terraform.tfvars)"

if [[ -f "$INFRA_DIR/terraform.tfvars" ]]; then
  pass "terraform.tfvars exists"
  _name_prefix=$(_read_tfvar name_prefix)
  _environment=$(_read_tfvar environment)
  _region=$(_read_tfvar region)
  _tls=$(_read_tfvar tls_certificate_source)
  _pg_source=$(_read_tfvar postgres_source)
  _redis_source=$(_read_tfvar redis_source)
  _ch_source=$(_read_tfvar clickhouse_source)

  if [[ -n "$_name_prefix" && -n "$_environment" && -n "$_region" ]]; then
    pass "Required fields: name_prefix=${_name_prefix}  environment=${_environment}  region=${_region}"
    _base_name="${_name_prefix}-${_environment}"
    _ssm_prefix="/langsmith/${_base_name}"
  else
    fail "Missing required fields (name_prefix, environment, or region)"
    action "Edit infra/terraform.tfvars — fill in name_prefix, environment, region"
    set_next "Edit infra/terraform.tfvars — fill in name_prefix, environment, region"
  fi
  [[ -n "$_tls" ]] && info "TLS: ${_tls}" || info "TLS: not set (defaults to none)"
  info "Services: postgres=${_pg_source:-external}  redis=${_redis_source:-external}  clickhouse=${_ch_source:-in-cluster}"
else
  fail "terraform.tfvars not found"
  action "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
  set_next "cp infra/terraform.tfvars.example infra/terraform.tfvars && edit it"
fi

# ── Check environment variables ─────────────────────────────────────────────
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
for var in TF_VAR_name_prefix TF_VAR_environment TF_VAR_region \
           TF_VAR_postgres_password TF_VAR_redis_auth_token \
           TF_VAR_langsmith_api_key_salt TF_VAR_langsmith_jwt_secret \
           LANGSMITH_LICENSE_KEY LANGSMITH_ADMIN_PASSWORD; do
  _check_var "$var" || _env_ok=false
done

if [[ "$_env_ok" == "false" ]]; then
  action "source infra/scripts/setup-env.sh"
  set_next "source infra/scripts/setup-env.sh"
fi

# ── Check AWS credentials ──────────────────────────────────────────────────
header "3. AWS Credentials"

if aws sts get-caller-identity --output text &>/dev/null; then
  _account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  _arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
  pass "AWS credentials valid — account: ${_account}"
  info "Identity: ${_arn}"
else
  fail "AWS credentials not configured or expired"
  action "aws sso login  OR  export AWS_PROFILE=..."
  set_next "Configure AWS credentials (aws sso login / export AWS_PROFILE=...)"
fi

# ── Check SSM parameters ───────────────────────────────────────────────────
header "4. SSM Parameter Store (${_ssm_prefix:-?})"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ -z "${_ssm_prefix:-}" ]]; then
  skip "Cannot check — terraform.tfvars missing name_prefix/environment"
else
  _ssm_ok=true
  _ssm_missing=()
  _required_params=(
    postgres-password
    redis-auth-token
    langsmith-api-key-salt
    langsmith-jwt-secret
    langsmith-license-key
    langsmith-admin-password
  )
  _optional_params=(
    agent-builder-encryption-key
    insights-encryption-key
    deployments-encryption-key
  )

  for param in "${_required_params[@]}"; do
    if aws ssm get-parameter --name "${_ssm_prefix}/${param}" \
        --query Parameter.Name --output text &>/dev/null; then
      pass "SSM: ${param}"
    else
      fail "SSM: ${param} — missing"
      _ssm_ok=false
      _ssm_missing+=("$param")
    fi
  done

  for param in "${_optional_params[@]}"; do
    if aws ssm get-parameter --name "${_ssm_prefix}/${param}" \
        --query Parameter.Name --output text &>/dev/null; then
      pass "SSM: ${param} (optional)"
    else
      skip "SSM: ${param} (optional)"
    fi
  done

  if [[ "$_ssm_ok" == "false" ]]; then
    echo ""
    info "Missing SSM params must be resolved before ESO can sync secrets to K8s."
    info "Options:"
    action "source infra/scripts/setup-env.sh  (backfills SSM from env vars, or prompts for new values)"
    action "./infra/scripts/manage-ssm.sh set <key> <value>  (write a specific param directly)"
    action "./infra/scripts/manage-ssm.sh validate  (check all required params)"
    echo ""
    for _mp in "${_ssm_missing[@]}"; do
      info "  ${_ssm_prefix}/${_mp}"
    done
    set_next "Resolve missing SSM parameters (see section 4 above)"
  fi
fi

# ── Terraform state ─────────────────────────────────────────────────────────
header "5. Terraform Infrastructure (Pass 1)"

if [[ -d "$INFRA_DIR/.terraform" ]]; then
  pass "terraform init — done"
else
  fail "terraform init — not run"
  action "terraform -chdir=infra init"
  set_next "terraform -chdir=infra init"
fi

# Use terraform output (fast, no state lock) instead of state list (slow, locks)
_tf_output=""
if [[ -d "$INFRA_DIR/.terraform" ]]; then
  _tf_output=$(terraform -chdir="$INFRA_DIR" output -json 2>/dev/null) || _tf_output=""
fi

if [[ -n "$_tf_output" ]] && echo "$_tf_output" | grep -q '"cluster_name"'; then
  pass "terraform apply — infrastructure provisioned"

  # Extract key outputs
  _cluster_name=$(echo "$_tf_output" | grep -A1 '"cluster_name"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _cluster_name=""
  _bucket_name=$(echo "$_tf_output" | grep -A1 '"bucket_name"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _bucket_name=""
  _irsa_arn=$(echo "$_tf_output" | grep -A1 '"langsmith_irsa_role_arn"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _irsa_arn=""
  _alb_dns=$(echo "$_tf_output" | grep -A1 '"alb_dns_name"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _alb_dns=""
  _langsmith_url=$(echo "$_tf_output" | grep -A1 '"langsmith_url"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _langsmith_url=""
  _pg_source=$(echo "$_tf_output" | grep -A1 '"postgres_source"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _pg_source=""
  _redis_source=$(echo "$_tf_output" | grep -A1 '"redis_source"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _redis_source=""
  _tls_source=$(echo "$_tf_output" | grep -A1 '"tls_certificate_source"' | grep '"value"' \
    | sed 's/.*"value":[[:space:]]*"\(.*\)".*/\1/') || _tls_source=""

  [[ -n "$_cluster_name" ]] && info "EKS cluster: ${_cluster_name}"     || warn "No cluster_name output"
  [[ -n "$_bucket_name" ]]  && info "S3 bucket: ${_bucket_name}"        || warn "No bucket_name output"
  [[ -n "$_irsa_arn" ]]     && info "IRSA role: ${_irsa_arn}"           || warn "No IRSA role output"
  [[ -n "$_alb_dns" ]]      && info "ALB DNS: ${_alb_dns}"             || warn "No alb_dns_name output"
  [[ -n "$_langsmith_url" ]] && info "LangSmith URL: ${_langsmith_url}"
  info "Services: postgres=${_pg_source:-?}  redis=${_redis_source:-?}  tls=${_tls_source:-?}"
else
  fail "terraform output — empty (no state file or state is elsewhere)"
  info "If infra was applied from another machine, you need to configure the backend"
  info "or run 'terraform -chdir=infra init' to reconnect to remote state."
  action "terraform -chdir=infra init  (if using a remote backend)"
  action "terraform -chdir=infra apply  (if starting fresh)"
  set_next "Resolve terraform state — see section 5"
fi

# ── Kubeconfig ──────────────────────────────────────────────────────────────
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
    action "aws eks update-kubeconfig --name ${_cluster_name} --region ${_region:-us-east-2}"
    set_next "aws eks update-kubeconfig --name ${_cluster_name} --region ${_region:-us-east-2}"
  else
    fail "No kubectl context set"
    action "aws eks update-kubeconfig --name ${_cluster_name} --region ${_region:-us-east-2}"
    set_next "aws eks update-kubeconfig --name ${_cluster_name} --region ${_region:-us-east-2}"
  fi

  if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    pass "kubectl can reach the cluster"
  else
    fail "kubectl cannot reach the cluster"
    info "If the cluster is private, you may need a bastion or VPN"
    action "Check network access — bastion, VPN, or enable public endpoint"
  fi
fi

# ── Helm overrides ──────────────────────────────────────────────────────────
header "7. Helm Values"

_overrides="$VALUES_DIR/langsmith-values-overrides.yaml"
_base_values="$VALUES_DIR/langsmith-values.yaml"

if [[ -f "$_base_values" ]]; then
  pass "langsmith-values.yaml (base)"
else
  fail "langsmith-values.yaml (base) — missing"
fi

if [[ -f "$_overrides" ]]; then
  pass "langsmith-values-overrides.yaml exists"
  # Check if hostname is populated
  _hostname=$(grep -E '^\s*hostname:' "$_overrides" 2>/dev/null \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
  if [[ -n "$_hostname" ]]; then
    info "hostname: ${_hostname}"
  else
    warn "hostname is blank (normal on first deploy — deploy.sh auto-fills it)"
  fi
else
  fail "langsmith-values-overrides.yaml — not generated"
  action "make init-values  (or: ./helm/scripts/init-values.sh)"
  set_next "make init-values"
fi

# Report addon files
for addon in sizing-production sizing-production-large sizing-dev agent-deploys agent-builder insights; do
  f="$VALUES_DIR/langsmith-values-${addon}.yaml"
  if [[ -f "$f" ]]; then
    pass "langsmith-values-${addon}.yaml (addon)"
  else
    skip "langsmith-values-${addon}.yaml — not enabled"
  fi
done

# ── Kubernetes resources ────────────────────────────────────────────────────
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

  # ESO ClusterSecretStore
  if kubectl get clustersecretstore langsmith-ssm &>/dev/null; then
    pass "ClusterSecretStore: langsmith-ssm"
  else
    warn "ClusterSecretStore langsmith-ssm not found (created by deploy.sh)"
  fi

  # ExternalSecret
  _eso_status=$(kubectl get externalsecret langsmith-config -n "$_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || _eso_status=""
  if [[ "$_eso_status" == "True" ]]; then
    pass "ExternalSecret: langsmith-config — synced"
  elif [[ -n "$_eso_status" ]]; then
    _eso_msg=$(kubectl get externalsecret langsmith-config -n "$_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null) || _eso_msg=""
    fail "ExternalSecret: langsmith-config — not ready: ${_eso_msg}"
    action "kubectl describe externalsecret langsmith-config -n ${_NAMESPACE}"
  else
    skip "ExternalSecret: langsmith-config — not created yet (created by deploy.sh)"
  fi

  # K8s secret
  if kubectl get secret langsmith-config -n "$_NAMESPACE" &>/dev/null; then
    pass "Secret: langsmith-config"
  else
    warn "Secret langsmith-config not found (created by ESO after deploy.sh)"
  fi
fi

# ── Helm release ────────────────────────────────────────────────────────────
header "9. Helm Release"

if [[ "$QUICK" == "true" ]]; then
  skip "Skipped (--quick mode)"
elif [[ "$_k8s_reachable" != "true" ]]; then
  skip "Cannot check — cluster unreachable"
else
  # Use helm status for authoritative release info (not helm list + grep parsing)
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
      info "Pods may still be running — Helm marks the release failed if --wait times out"
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

  # Ingress / ALB
  _alb_host=$(kubectl get ingress -n "$_NAMESPACE" langsmith-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null) || _alb_host=""
  if [[ -n "$_alb_host" ]]; then
    pass "Ingress ALB: ${_alb_host}"
  else
    _ingress_exists=$(kubectl get ingress -n "$_NAMESPACE" langsmith-ingress &>/dev/null && echo "yes" || echo "no")
    if [[ "$_ingress_exists" == "yes" ]]; then
      warn "Ingress exists but ALB hostname not yet assigned (~2 min to provision)"
      action "Wait 2 min, then re-run ./helm/scripts/deploy.sh to pick up the hostname"
    else
      skip "No ingress found"
    fi
  fi
fi

# ── Alternative: Terraform Helm (app/) ──────────────────────────────────────
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
  elif [[ -d "$APP_DIR/.terraform" ]]; then
    skip "app/ terraform — initialized but not applied"
  else
    skip "app/ terraform — not initialized"
  fi
else
  skip "app/ directory not present"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
header "Next Step"

if [[ -n "$NEXT_ACTION" ]]; then
  printf "\n  $(_yellow "▶")  $(_bold "%s")\n\n" "$NEXT_ACTION"
else
  printf "\n  $(_green "✔")  $(_bold "All checks passed — deployment looks healthy")\n\n"
fi
