#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# sso.sh — Turn on SSO (OIDC) login for an installed LangSmith.
#
# Checks the prerequisites, stores any missing OIDC settings in SSM, sets enable_sso_oidc = true in terraform.tfvars (that line only), syncs the settings into the cluster, and deploys.
# It never runs init-values.sh, so the generated overrides file is left as it is.
# One-way: LangSmith does not support moving a self-hosted install from SSO back to basic auth.
#
# Usage (from aws/):
#   make sso
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$SCRIPT_DIR/../../infra}"
source "$INFRA_DIR/scripts/_common.sh"

NAMESPACE="${NAMESPACE:-langsmith}"
RELEASE_NAME="${RELEASE_NAME:-langsmith}"
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"
VALUES_DIR="$HELM_DIR/values"
OVERRIDES_FILE="$VALUES_DIR/langsmith-values-overrides.yaml"
SSO_FILE="$VALUES_DIR/langsmith-values-sso.yaml"
OIDC_KEYS=(oauth-client-id oauth-client-secret oauth-issuer-url)

_confirm() {
  local _answer
  read -r -p "  $1 [y/N] " _answer
  [[ "$_answer" =~ ^[Yy] ]]
}

_ssm_exists() {
  aws ssm get-parameter --region "$_region" --name "$1" --query Parameter.Name --output text >/dev/null 2>&1
}

# Passes the value through a private temp file so it never appears in the process list or shell history.
_ssm_put() {
  local _path="$1" _value="$2" _tmp _rc=0
  _tmp="$(mktemp)"
  chmod 600 "$_tmp"
  printf '%s' "$_value" > "$_tmp"
  aws ssm put-parameter --region "$_region" --name "$_path" --type SecureString \
    --value "file://$_tmp" --overwrite --output text >/dev/null || _rc=$?
  rm -f "$_tmp"
  return $_rc
}

echo ""
printf "%s SSO is one-way. Once it is on, users log in only through your identity provider, and going back to password login is not supported.\n" "$(_yellow "WARNING:")"

header "1. Configuration"
if [[ ! -f "$TFVARS_FILE" ]]; then
  fail "terraform.tfvars not found at $TFVARS_FILE"
  exit 1
fi
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region=""
if [[ -z "$_name_prefix" || -z "$_environment" || -z "$_region" ]]; then
  fail "name_prefix, environment, and region must be set in terraform.tfvars"
  exit 1
fi
_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

# The deploy uses this hostname, so it is where HTTPS must be set, and it is where the identity provider redirects back to.
_hostname=""
if [[ -f "$OVERRIDES_FILE" ]]; then
  _hostname=$(grep -E '^[[:space:]]*hostname:' "$OVERRIDES_FILE" | head -1 \
    | sed 's/.*:[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _hostname=""
fi
if [[ -z "$_hostname" ]]; then
  fail "No hostname in $OVERRIDES_FILE"
  action "Install LangSmith first: make init-values, then make deploy"
  exit 1
fi
if [[ "$_hostname" != https://* ]]; then
  fail "SSO only works over HTTPS, and the deployed hostname is $_hostname"
  action "Set tls_certificate_source = \"acm\" or \"letsencrypt\", run make apply and make init-values, then rerun make sso"
  exit 1
fi
_host="${_hostname#https://}"
pass "HTTPS host: $_host"

if _tfvar_is_true "enable_sso_oidc"; then
  info "enable_sso_oidc is already true. Rechecking everything and redeploying."
fi

header "2. AWS access and cluster"
if ! aws sts get-caller-identity --region "$_region" >/dev/null 2>&1; then
  fail "AWS credentials are missing or expired"
  exit 1
fi
pass "AWS credentials work"

# Point kubectl and helm at this deployment's cluster, as deploy.sh does, so nothing below touches another cluster.
_cluster_name=$(terraform -chdir="$INFRA_DIR" output -raw cluster_name 2>/dev/null) || _cluster_name=""
if [[ -z "$_cluster_name" ]]; then
  fail "Could not read cluster_name from Terraform outputs. Is terraform apply complete?"
  exit 1
fi
aws eks update-kubeconfig --name "$_cluster_name" --region "$_region" >/dev/null
pass "Cluster: $_cluster_name"

header "3. LangSmith install"
if ! helm status "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null | grep -q '^STATUS: deployed'; then
  fail "Helm release $RELEASE_NAME in namespace $NAMESPACE is not deployed"
  action "Install LangSmith with password login first (make deploy), then rerun make sso"
  exit 1
fi
pass "Release $RELEASE_NAME is deployed"

header "4. Admin login"
_admin_email=$(aws ssm get-parameter --region "$_region" --name "${_ssm_prefix}/langsmith-admin-email" \
  --query Parameter.Value --output text --with-decryption 2>/dev/null) || _admin_email=""
echo "  After the switch, an existing user must log in through your identity provider with the same email they used for password login."
echo "  Otherwise nobody can get into the existing org."
[[ -n "$_admin_email" ]] && echo "  Org admin email: $_admin_email"
if ! _confirm "Can the org admin log in with a password now, and does that email exist in your identity provider?"; then
  fail "Stopped. Nothing was changed."
  exit 1
fi

header "5. Identity provider settings (SSM)"
info "Register this redirect URI in your identity provider: https://${_host}/api/v1/oauth/custom-oidc/callback"
for _key in "${OIDC_KEYS[@]}"; do
  _path="${_ssm_prefix}/${_key}"
  if _ssm_exists "$_path"; then
    pass "$_key: found in SSM"
    continue
  fi
  if [[ ! -t 0 ]]; then
    fail "$_key is missing from SSM and there is no terminal to ask for it"
    action "Set it first: ./infra/scripts/manage-ssm.sh set $_key '<value>'"
    exit 1
  fi
  _value=""
  case "$_key" in
    oauth-client-secret)
      read -r -s -p "  OIDC client secret (hidden): " _value
      echo ""
      ;;
    oauth-client-id)
      read -r -p "  OIDC client ID: " _value
      ;;
    oauth-issuer-url)
      read -r -p "  OIDC issuer URL (https://...): " _value
      if [[ "$_value" != https://* ]]; then
        fail "The issuer URL must start with https://"
        exit 1
      fi
      ;;
  esac
  if [[ -z "$_value" ]]; then
    fail "No value entered for $_key. Nothing was changed in terraform.tfvars."
    exit 1
  fi
  if ! _ssm_put "$_path" "$_value"; then
    fail "Could not store $_key in SSM at $_path"
    exit 1
  fi
  pass "$_key: stored in SSM"
done
unset _value

header "6. Issuer URL"
_issuer=$(aws ssm get-parameter --region "$_region" --name "${_ssm_prefix}/oauth-issuer-url" \
  --query Parameter.Value --output text --with-decryption)
_discovery="${_issuer%/}/.well-known/openid-configuration"
if ! curl -fsS --max-time 10 "$_discovery" 2>/dev/null | grep -q '"issuer"'; then
  fail "No OIDC discovery document at $_discovery"
  action "Check the issuer URL: ./infra/scripts/manage-ssm.sh set oauth-issuer-url '<value>'"
  exit 1
fi
pass "Issuer answers: $_issuer"

header "7. Sync settings into the cluster"
NAMESPACE="$NAMESPACE" INFRA_DIR="$INFRA_DIR" "$SCRIPT_DIR/apply-eso.sh"
# Lists key names only, never values.
_missing_keys=""
for _attempt in 1 2 3 4 5 6; do
  _keys=$(kubectl get secret langsmith-config -n "$NAMESPACE" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null) || _keys=""
  _missing_keys=""
  for _k in oauth_client_id oauth_client_secret oauth_issuer_url; do
    grep -qx "$_k" <<<"$_keys" || _missing_keys="$_missing_keys $_k"
  done
  [[ -z "$_missing_keys" ]] && break
  sleep 5
done
if [[ -n "$_missing_keys" ]]; then
  fail "langsmith-config is missing:$_missing_keys"
  action "Check: kubectl describe externalsecret langsmith-config -n $NAMESPACE"
  exit 1
fi
pass "langsmith-config has the 3 OIDC keys"

header "8. terraform.tfvars"
# Edit only the enable_sso_oidc line (or add it), so every other setting stays exactly as written.
_tmp_tfvars="$(mktemp)"
if grep -qE '^[[:space:]]*enable_sso_oidc[[:space:]]*=' "$TFVARS_FILE"; then
  sed -E 's/^([[:space:]]*enable_sso_oidc[[:space:]]*=).*/\1 true/' "$TFVARS_FILE" > "$_tmp_tfvars"
else
  cat "$TFVARS_FILE" > "$_tmp_tfvars"
  printf '\nenable_sso_oidc = true\n' >> "$_tmp_tfvars"
fi
cat "$_tmp_tfvars" > "$TFVARS_FILE"
rm -f "$_tmp_tfvars"
pass "enable_sso_oidc = true"

header "9. SSO values file"
if [[ -f "$SSO_FILE" ]]; then
  pass "Existing: helm/values/langsmith-values-sso.yaml (kept as is)"
else
  cp "$VALUES_DIR/examples/langsmith-values-sso.yaml" "$SSO_FILE"
  pass "Created: helm/values/langsmith-values-sso.yaml"
fi

header "10. Deploy"
if ! _confirm "Deploy now? Password login stops working once this finishes."; then
  action "SSO is set up but not deployed. Run make deploy when ready."
  exit 0
fi
"$SCRIPT_DIR/deploy.sh"

echo ""
pass "SSO is on. Log in at https://${_host}"
