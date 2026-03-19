#!/usr/bin/env bash
# setup-env.sh — Configure Terraform variables for LangSmith on AWS
#
# Usage (from aws/):
#   source infra/scripts/setup-env.sh
#
# Run with `source` so exported variables persist in your shell session.
# Do NOT commit terraform.tfvars with real passwords — use this script instead.
#
# Secret storage:
#   Secrets are stored in AWS SSM Parameter Store under:
#     /langsmith/{name_prefix}-{environment}/
#   On subsequent runs, this script reads secrets FROM SSM — no re-prompting
#   needed. If SSM is not yet reachable (first run), secrets fall back to
#   local .secret files for that run only, then migrate on the next run.

# NOTE: No `set -euo pipefail` — this script is intended to be sourced.
export AWS_PAGER=""

# Resolve infra directory so this script works regardless of where it's sourced from.
# setup-env.sh lives in infra/scripts/ but terraform.tfvars lives in infra/.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# ── AWS ───────────────────────────────────────────────────────────────────────
# Ensure AWS_PROFILE or AWS credentials are set before sourcing.
# Region is read from terraform.tfvars if present; falls back to AWS_REGION env var.
_tfvars_region=$(grep -E '^\s*region\s*=' "$_SETUP_DIR/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _tfvars_region=""
export AWS_REGION="${_tfvars_region:-${AWS_REGION:-us-west-2}}"

# ── Environment & tagging ─────────────────────────────────────────────────────
# Read environment from terraform.tfvars first — only fall back to env var / default
# if not set there. This prevents silently overriding "prod" in tfvars with "dev".
_tfvars_env=$(grep -E '^\s*environment\s*=' "$_SETUP_DIR/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _tfvars_env=""
export TF_VAR_environment="${_tfvars_env:-${LANGSMITH_ENV:-dev}}"
export TF_VAR_owner="${LANGSMITH_OWNER:-}"
export TF_VAR_cost_center="${LANGSMITH_COST_CENTER:-}"
export TF_VAR_region="$AWS_REGION"

# ── SSM path prefix ───────────────────────────────────────────────────────────
# Reads name_prefix and environment from terraform.tfvars to build the SSM path.
# All secrets are stored under: /langsmith/{name_prefix}-{environment}/
_name_prefix=$(grep -E '^\s*name_prefix\s*=' "$_SETUP_DIR/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _name_prefix=""
_environment=$(grep -E '^\s*environment\s*=' "$_SETUP_DIR/terraform.tfvars" 2>/dev/null \
  | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]') || _environment="${LANGSMITH_ENV:-dev}"
if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: name_prefix is not set in terraform.tfvars. Set it before sourcing setup-env.sh." >&2
  return 1
fi
export TF_VAR_name_prefix="${_name_prefix}"

_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

# ── Warn on pre-exported secrets ──────────────────────────────────────────────
# _ssm_secret short-circuits (step 0) when a variable is already exported.
# If LANGSMITH_LICENSE_KEY or LANGSMITH_ADMIN_PASSWORD are set from a prior
# session, the script will NOT re-prompt and NOT write to SSM.
# Unset them first if you need to rotate or re-store those secrets.
for _precheck_var in LANGSMITH_LICENSE_KEY LANGSMITH_ADMIN_PASSWORD; do
  if [[ -n "$(printenv "$_precheck_var")" ]]; then
    echo "WARNING: $_precheck_var is already set in the environment."
    echo "         setup-env.sh will skip re-prompting and will NOT write to SSM for this key."
    echo "         To rotate or re-store: unset $_precheck_var && source infra/scripts/setup-env.sh"
    echo ""
  fi
done

# ── Safe SSM write ────────────────────────────────────────────────────────────
# Writes a value to SSM via a JSON file to avoid shell expansion issues with
# special characters in passwords ($, !, backticks, etc.) that break --value.
_ssm_put_safe() {
  local _path="$1" _val="$2"
  local _tmpval _tmpjson
  _tmpval="$(mktemp)"  || return 1
  _tmpjson="$(mktemp)" || { rm -f "$_tmpval"; return 1; }
  printf '%s' "$_val" > "$_tmpval"
  python3 -c "
import json, sys
v = open(sys.argv[1]).read()
json.dump({'Name':sys.argv[2],'Value':v,'Type':'SecureString','Overwrite':True}, open(sys.argv[3],'w'))
" "$_tmpval" "$_path" "$_tmpjson"
  local _rc=0
  aws ssm put-parameter \
    --region "$AWS_REGION" \
    --cli-input-json "file://${_tmpjson}" \
    --output text >/dev/null 2>&1 || _rc=$?
  rm -f "$_tmpval" "$_tmpjson"
  return $_rc
}

# ── SSM-backed secret helper ──────────────────────────────────────────────────
# _ssm_secret: reads a secret from SSM if available; falls back to a local
# .secret file (migration path from first Pass 1). Prompts or generates a new
# value if neither source exists, and stores it in SSM (if reachable) or a
# local file (first Pass 1 only, migrates on next run).
#
# Args:
#   $1  ssm_name     — SSM parameter leaf name (e.g. "postgres-password")
#   $2  file_name    — Legacy local .secret file (empty = no file fallback)
#   $3  varname      — TF_VAR_* variable name to export
#   $4  generator    — Shell command that outputs a new value (empty = prompt)
#   $5  prompt_text  — Prompt string for interactive input
#   $6  silent       — "true" to hide input (passwords); "false" for plaintext
_ssm_secret() {
  local ssm_name="$1"
  local file_name="$2"
  local varname="$3"
  local generator="$4"
  local prompt_text="$5"
  local silent="${6:-true}"

  local val=""
  local _path="${_ssm_prefix}/${ssm_name}"

  # 0. Already exported in the environment — use as-is, but backfill SSM if missing.
  #    Without this backfill, pre-exported vars silently skip the SSM write, leaving
  #    ESO unable to sync the secret into the K8s langsmith-config secret.
  if [[ -n "$(printenv "$varname")" ]]; then
    if ! aws ssm get-parameter --region "$AWS_REGION" --name "$_path" \
        --query Parameter.Name --output text &>/dev/null; then
      echo "  $varname is set in env but missing from SSM — backfilling → $_path"
      if ! _ssm_put_safe "$_path" "$(printenv "$varname")"; then
        echo "  WARNING: SSM backfill failed for $_path"
        echo "           Try manually: ./infra/scripts/manage-ssm.sh set $(basename "$_path") '<value>'"
      fi
    fi
    return
  fi

  # 1. Try SSM Parameter Store
  val=$(aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$_path" \
    --with-decryption \
    --query Parameter.Value \
    --output text 2>/dev/null) || val=""

  # 2. Fall back to local file (migration from pre-SSM runs)
  if [[ -z "$val" && -n "$file_name" && -f "$file_name" ]]; then
    val=$(cat "$file_name")
    echo "  Migrating $varname from $file_name → SSM"
    if _ssm_put_safe "$_path" "$val"; then
      echo "  Migration complete. You may delete: $file_name"
    fi
  fi

  # 3. Prompt or generate if still empty
  if [[ -z "$val" ]]; then
    if [[ -n "$generator" ]]; then
      val=$(eval "$generator") || {
        echo "ERROR: Secret generator failed for $varname." >&2
        echo "       Command: $generator" >&2
        echo "       Ensure required tools are installed (e.g. python3, openssl, cryptography)." >&2
        return 1
      }
      if [[ -z "$val" ]]; then
        echo "ERROR: Secret generator for $varname produced empty output." >&2
        return 1
      fi
    elif [[ -t 0 ]]; then
      # Interactive terminal — prompt the user
      if [[ "$silent" == "true" ]]; then
        printf "%s: " "$prompt_text"
        read -rs val
        echo
      else
        printf "%s: " "$prompt_text"
        read -r val
      fi
      if [[ -z "$val" ]]; then
        echo "  ERROR: No value provided for $varname." >&2
        return 1
      fi
    else
      # Non-interactive (CI, piped stdin, redirected) — cannot prompt
      echo "  ERROR: $varname is required but not set and no interactive terminal available." >&2
      echo "         Pre-export it before sourcing this script:" >&2
      echo "           export $varname='<value>'" >&2
      echo "         Or populate SSM directly:" >&2
      echo "           ./infra/scripts/manage-ssm.sh set $ssm_name '<value>'" >&2
      return 1
    fi

    # Store in SSM; fall back to local file if SSM is not yet reachable
    if _ssm_put_safe "$_path" "$val"; then
      echo "  Stored $varname → SSM: $_path"
    elif [[ -n "$file_name" ]]; then
      printf '%s' "$val" > "$file_name"
      chmod 600 "$file_name"
      echo "  SSM unavailable — stored in $file_name (will migrate after Pass 1)"
    else
      echo "  WARNING: SSM unavailable and no local file fallback for $varname"
      echo "           Value is exported for this session only and will be lost on shell exit."
    fi
  fi

  export "$varname"="$val"
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
export TF_VAR_postgres_username="${LANGSMITH_PG_USER:-langsmith}"

_ssm_secret "postgres-password" "$_SETUP_DIR/.pg_password" "TF_VAR_postgres_password" \
  "" "PostgreSQL admin password" "true"

# ── Redis auth token (auto-generated, stable after first deployment) ──────────
# ElastiCache auth tokens must be printable ASCII — use hex, not base64.
_ssm_secret "redis-auth-token" "" "TF_VAR_redis_auth_token" \
  "openssl rand -hex 32" "" "true"

# ── Stable auto-generated secrets (must never change after first deployment) ──
# Changing api_key_salt invalidates ALL existing API keys.
# Changing jwt_secret invalidates ALL active user sessions.
_ssm_secret "langsmith-api-key-salt" "$_SETUP_DIR/.api_key_salt" "TF_VAR_langsmith_api_key_salt" \
  "openssl rand -base64 32" "" "true"

_ssm_secret "langsmith-jwt-secret" "$_SETUP_DIR/.jwt_secret" "TF_VAR_langsmith_jwt_secret" \
  "openssl rand -base64 32" "" "true"

# ── LangSmith app secrets (consumed by ESO → K8s Secret → Helm chart) ────────
_ssm_secret "langsmith-license-key" "$_SETUP_DIR/.license_key" "LANGSMITH_LICENSE_KEY" \
  "" "LangSmith license key" "true"

_ssm_secret "langsmith-admin-password" "$_SETUP_DIR/.admin_password" "LANGSMITH_ADMIN_PASSWORD" \
  "" "Admin password (must contain a symbol: \!#\$%()+,-./:?@[\\]^_{~})" "true"

# Validate admin password contains a required symbol. Helm chart enforces this at deploy time;
# catching it here prevents storing an invalid password in SSM and discovering the error
# 10 minutes later when the Helm release times out.
if [[ -n "$LANGSMITH_ADMIN_PASSWORD" ]]; then
  if ! printf '%s' "$LANGSMITH_ADMIN_PASSWORD" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
    echo "ERROR: Admin password does not contain a required symbol: !#\$%()+,-./:?@[\\]^_{~}" >&2
    echo "       The Helm chart will reject this password. Unset LANGSMITH_ADMIN_PASSWORD," >&2
    echo "       delete the SSM parameter at ${_ssm_prefix}/langsmith-admin-password," >&2
    echo "       and re-source this script with a valid password." >&2
    return 1
  fi
fi

# ── LangGraph Platform Encryption Keys (optional) ────────────────────────────
# Fernet keys for Deployments, Agent Builder, and Insights addons.
# Auto-generated and stored in SSM on first run. Only created when the user
# opts in — ESO's apply-eso.sh dynamically includes whichever keys exist in SSM.
# Fernet key = 32 random bytes, URL-safe base64-encoded (openssl, no Python needed).
_fernet_gen='openssl rand -base64 32 | tr -d "\n"'

_ssm_secret "deployments-encryption-key" "" "TF_VAR_langsmith_deployments_encryption_key" \
  "$_fernet_gen" "" "true"

_ssm_secret "agent-builder-encryption-key" "" "TF_VAR_langsmith_agent_builder_encryption_key" \
  "$_fernet_gen" "" "true"

_ssm_secret "insights-encryption-key" "" "TF_VAR_langsmith_insights_encryption_key" \
  "$_fernet_gen" "" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Terraform environment variables set."
echo ""
echo "  name_prefix       = ${_name_prefix:-(empty)}"
echo "  environment       = $_environment"
echo "  region            = $AWS_REGION"
echo "  postgres_username = $TF_VAR_postgres_username"
echo "  postgres_password = (hidden — SSM: ${_ssm_prefix}/postgres-password)"
echo "  redis_auth_token  = (hidden — SSM: ${_ssm_prefix}/redis-auth-token)"
echo "  api_key_salt      = (hidden — SSM: ${_ssm_prefix}/langsmith-api-key-salt)"
echo "  jwt_secret        = (hidden — SSM: ${_ssm_prefix}/langsmith-jwt-secret)"
echo "  license_key       = (hidden — SSM: ${_ssm_prefix}/langsmith-license-key)"
echo "  admin_password    = (hidden — SSM: ${_ssm_prefix}/langsmith-admin-password)"
echo "  deploy_key        = (hidden — SSM: ${_ssm_prefix}/deployments-encryption-key)"
echo "  ab_key            = (hidden — SSM: ${_ssm_prefix}/agent-builder-encryption-key)"
echo "  insights_key      = (hidden — SSM: ${_ssm_prefix}/insights-encryption-key)"
echo "  ssm_prefix        = $_ssm_prefix"
echo ""
echo "Next:  terraform -chdir=infra apply"
echo "       aws eks update-kubeconfig --region $AWS_REGION --name ${_name_prefix}-${_environment}-eks"
echo "       make init-values  (or: ./helm/scripts/init-values.sh)"
echo "       ./helm/scripts/deploy.sh"
