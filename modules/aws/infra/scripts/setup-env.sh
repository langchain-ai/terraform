#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

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
#   SSM is authoritative. Only a confirmed-missing parameter permits importing
#   a locally saved value, then an exported shell value, or creating a new one.
#   Each resolved secret refreshes its local file (mode 600) before shell export.
#   SSM errors, local file errors, or conflicting shell values stop setup.

# NOTE: No `set -euo pipefail` — this script is intended to be sourced.
export AWS_PAGER=""

# Resolve infra directory so this script works regardless of where it's sourced from.
# setup-env.sh lives in infra/scripts/ but terraform.tfvars lives in infra/.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# ── terraform.tfvars parser ───────────────────────────────────────────────────
# Keep identical to infra/scripts/_common.sh, apart from the tfvars path:
# apply-eso.sh and deploy.sh decide whether the sandbox secrets are expected by
# calling the _common.sh copy, so a gate that disagrees leaves the
# ExternalSecret pointing at an SSM parameter nothing created, which fails the
# whole langsmith-config sync. _common.sh is not sourced here because it also
# defines pass/info/fail and _aws, which this script must not leak into the
# caller's interactive shell.
_parse_tfvar() {
  local key="$1"
  local tfvars_file="$_SETUP_DIR/terraform.tfvars"
  local raw val
  raw=$(grep -E "^\s*${key}\s*=" "$tfvars_file" 2>/dev/null | head -1) || return 1
  [[ -n "$raw" ]] || return 1
  # Quoted string: key = "value"
  val=$(echo "$raw" | sed -n 's/.*=[[:space:]]*"\([^"]*\)".*/\1/p' | tr -d '[:space:]')
  if [[ -z "$val" ]]; then
    # Unquoted value: key = true / key = 42 / key = {} / key = ["m5.2xlarge"]
    # Strip any trailing `# comment` BEFORE collapsing whitespace, otherwise
    # `enable_fleet = true # note` parses to `true#note` and breaks _tfvar_is_true
    # (migration issue #1).
    val=$(echo "$raw" | sed 's/.*=[[:space:]]*//; s/#.*//' | tr -d '[:space:]"[]')
  fi
  [[ -n "$val" ]] || return 1
  echo "$val"
}

# Returns 0 if KEY = true or "true" in terraform.tfvars.
_tfvar_is_true() {
  local val
  val=$(_parse_tfvar "$1") || return 1
  [[ "$val" == "true" ]]
}

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
_enable_sandboxes=false
if _tfvar_is_true "enable_sandboxes"; then
  _enable_sandboxes=true
fi
if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: name_prefix is not set in terraform.tfvars. Set it before sourcing setup-env.sh." >&2
  return 1
fi
export TF_VAR_name_prefix="${_name_prefix}"

_ssm_prefix="/langsmith/${_name_prefix}-${_environment}"

# Collect secrets that still need interactive input so non-interactive runs
# report all missing inputs together, before printing a success summary.
_missing_vars=""
_ssm_failed=""

# ── Bounded AWS CLI calls ─────────────────────────────────────────────────────
# Bounded by timeout(1) when available so a sandbox with blocked egress fails
# fast instead of stalling on a full TCP timeout. timeout is not in the macOS
# base install, and gtimeout is the Homebrew coreutils name; run bare if neither.
_timeout_bin=""
for _t in timeout gtimeout; do
  if command -v "$_t" >/dev/null 2>&1; then _timeout_bin="$_t"; break; fi
done
# Named _aws_bounded, not _aws: this script is sourced, and _aws is the zsh
# completion function for the aws command — defining it here would replace the
# completion for the rest of the caller's shell session.
_aws_bounded() {
  if [[ -n "$_timeout_bin" ]]; then
    "$_timeout_bin" 30 aws "$@"
  else
    aws "$@"
  fi
}

# ── Safe SSM write ────────────────────────────────────────────────────────────
# Writes a value to SSM via a JSON file to avoid shell expansion issues with
# special characters in passwords ($, !, backticks, etc.) that break --value.
# Create only: a concurrent setup must not replace a stored secret.
# Use manage-ssm.sh for explicit rotation.
_ssm_put_safe() {
  local _path="$1" _val="$2"
  local _tmpjson
  _tmpjson="$(mktemp)" || { _ssm_failed=1; return 1; }
  chmod 600 "$_tmpjson"
  # shellcheck disable=SC2064
  trap "rm -f '$_tmpjson'" RETURN

  if command -v jq &>/dev/null; then
    jq -n --arg name "$_path" --arg val "$_val" \
      '{Name: $name, Value: $val, Type: "SecureString", Overwrite: false}' > "$_tmpjson"
  else
    # Pure bash fallback — escape JSON special characters in the value.
    local _escaped_val
    _escaped_val=$(printf '%s' "$_val" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g')
    printf '{"Name":"%s","Value":"%s","Type":"SecureString","Overwrite":false}\n' \
      "$_path" "$_escaped_val" > "$_tmpjson"
  fi

  local _rc=0 _error
  _error=$(_aws_bounded ssm put-parameter \
    --region "$AWS_REGION" \
    --cli-input-json "file://${_tmpjson}" \
    --output text 2>&1 >/dev/null) || _rc=$?
  rm -f "$_tmpjson"
  if [[ $_rc -ne 0 ]]; then
    if [[ "$_error" == *"(ParameterAlreadyExists)"* ]]; then
      echo "ERROR: $_path was created concurrently; rerun setup to read it from SSM."
    else
      echo "ERROR: Could not save $_path to SSM. Fix AWS access and rerun setup."
    fi
    _ssm_failed=1
  fi
  return $_rc
}

# ── SSM-backed secret helper ──────────────────────────────────────────────────
# Source priority: SSM, locally saved value, shell, then generate or prompt.
#
# Args:
#   $1  ssm_name     — SSM parameter leaf name (e.g. "postgres-password")
#   $2  file_name    — Local secret file
#   $3  varname      — Shell variable to export (TF_VAR_* or LANGSMITH_*)
#   $4  generator    — Shell command that outputs a new value (empty = prompt)
#   $5  prompt_text  — Prompt string for interactive input
#   $6  silent       — "true" to hide input (passwords); "false" for plaintext
_ssm_secret() {
  # A failed secret must not cause later secrets to be created.
  [[ -z "$_ssm_failed" ]] || return 1
  local ssm_name="$1"
  local file_name="$2"
  local varname="$3"
  local generator="$4"
  local prompt_text="$5"
  local silent="${6:-true}"

  local val="" shell_val missing=false source="SSM"
  shell_val=$(printenv "$varname") || shell_val=""
  local _path="${_ssm_prefix}/${ssm_name}"

  local _errfile
  _errfile=$(mktemp) || { _ssm_failed=1; return 1; }
  if ! val=$(_aws_bounded ssm get-parameter --region "$AWS_REGION" --name "$_path" \
      --with-decryption --query Parameter.Value --output text 2>"$_errfile"); then
    # Only ParameterNotFound permits generating or migrating a value.
    if ! grep -Fq "(ParameterNotFound)" "$_errfile"; then
      echo "ERROR: SSM read failed for $_path (region: $AWS_REGION)."
      cat "$_errfile" >&2
      rm -f "$_errfile"
      _ssm_failed=1
      return 1
    fi
    val=""
    missing=true
  fi
  rm -f "$_errfile"

  if [[ "$missing" == true ]]; then
    source="the locally saved value in $file_name"
    if [[ -f "$file_name" ]]; then
      val=$(cat "$file_name") || {
        echo "ERROR: Could not read $file_name." >&2
        _ssm_failed=1
        return 1
      }
    fi
    val="${val:-$shell_val}"
  fi

  # A shell override must not silently change what Terraform will apply.
  if [[ -n "$shell_val" && "$shell_val" != "$val" ]]; then
    echo "ERROR: $varname in the shell differs from $source. Investigate before rerunning setup." >&2
    _ssm_failed=1
    return 1
  fi

  if [[ -z "$val" ]]; then
    if [[ -n "$generator" ]]; then
      val=$(eval "$generator") || {
        echo "ERROR: Secret generator failed for $varname." >&2
        echo "       Command: $generator" >&2
        echo "       Ensure required tools are installed (e.g. python3, openssl, cryptography)." >&2
        _ssm_failed=1
        return 1
      }
      if [[ -z "$val" ]]; then
        echo "ERROR: Secret generator for $varname produced empty output." >&2
        _ssm_failed=1
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
        _ssm_failed=1
        return 1
      fi
    else
      # Non-interactive (CI, piped stdin, redirected) — cannot prompt.
      # Reported on stdout, not stderr: a sandboxed shell that surfaces only
      # stdout (Cursor's agent shell) shows nothing at all otherwise, so the
      # script looks like it exited without a reason.
      echo "  ERROR: $varname is required but not set and no interactive terminal available."
      echo "         Pre-export it before sourcing this script:"
      echo "           export $varname='<value>'"
      echo "         Or populate SSM directly:"
      echo "           ./infra/scripts/manage-ssm.sh set $ssm_name '<value>'"
      _missing_vars="$_missing_vars $varname"
      return 1
    fi
  fi

  if [[ "$missing" == true ]]; then
    _ssm_put_safe "$_path" "$val" || return 1
  fi
  # Retain legacy filenames and refresh stale local copies from SSM.
  (umask 077; touch "$file_name" && chmod 600 "$file_name" && printf '%s' "$val" > "$file_name") || {
    echo "ERROR: Could not save $varname locally in $file_name." >&2
    _ssm_failed=1
    return 1
  }
  export "$varname"="$val"
}

_b64url_nopad() {
  base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

_ed25519_private_jwk_gen() {
  local _tmpdir _key _priv_der _pub_der _d _x _kid
  _tmpdir="$(mktemp -d)" || return 1
  _key="${_tmpdir}/ed25519.pem"
  _priv_der="${_tmpdir}/private.der"
  _pub_der="${_tmpdir}/public.der"

  if ! openssl genpkey -algorithm ED25519 -out "$_key" >/dev/null 2>&1; then
    rm -rf "$_tmpdir"
    return 1
  fi
  chmod 600 "$_key"

  if ! openssl pkey -in "$_key" -outform DER -out "$_priv_der" >/dev/null 2>&1; then
    rm -rf "$_tmpdir"
    return 1
  fi
  if ! openssl pkey -in "$_key" -pubout -outform DER -out "$_pub_der" >/dev/null 2>&1; then
    rm -rf "$_tmpdir"
    return 1
  fi

  _d="$(tail -c 32 "$_priv_der" | _b64url_nopad)" || {
    rm -rf "$_tmpdir"
    return 1
  }
  _x="$(tail -c 32 "$_pub_der" | _b64url_nopad)" || {
    rm -rf "$_tmpdir"
    return 1
  }
  rm -rf "$_tmpdir"

  if [[ -z "$_d" || -z "$_x" ]]; then
    return 1
  fi

  _kid="sandbox-callback-$(openssl rand -hex 8)"
  printf '{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"%s","x":"%s","d":"%s"}\n' \
    "$_kid" "$_x" "$_d"
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
export TF_VAR_postgres_username="${LANGSMITH_PG_USER:-langsmith}"

# Hex is RDS-safe (no / @ " ' space) and URI-safe. Terraform still urlencodes
# the password in connection URLs for env/SSM overrides that use other symbols.
_ssm_secret "postgres-password" "$_SETUP_DIR/.pg_password" "TF_VAR_postgres_password" \
  "openssl rand -hex 32" "" "true"

# Reject passwords RDS cannot accept before Terraform validates them.
if [[ -n "${TF_VAR_postgres_password:-}" ]]; then
  _pg_error=""
  if [[ ${#TF_VAR_postgres_password} -lt 8 || ${#TF_VAR_postgres_password} -gt 128 ]]; then
    _pg_error="must be 8-128 characters (RDS master password limit)"
  elif ! printf '%s' "$TF_VAR_postgres_password" | grep -qE "^[^/@\"' ]+$"; then
    _pg_error="must not contain '/', '@', double quote, single quote, or space"
  fi
  if [[ -n "$_pg_error" ]]; then
    echo "ERROR: PostgreSQL admin password is invalid — ${_pg_error}." >&2
    echo "       Unset TF_VAR_postgres_password," >&2
    echo "       delete the SSM parameter at ${_ssm_prefix}/postgres-password," >&2
    echo "       and re-source this script." >&2
    return 1
  fi
fi

# ── Redis auth token (auto-generated, stable after first deployment) ──────────
# ElastiCache auth tokens must be printable ASCII — use hex, not base64.
_ssm_secret "redis-auth-token" "$_SETUP_DIR/.redis_auth_token" "TF_VAR_redis_auth_token" \
  "openssl rand -hex 32" "" "true"

# ── Sandbox JuiceFS Redis auth token ──────────────────────────────────────────
# ElastiCache auth tokens must be printable ASCII — use hex, not base64.
if [[ "$_enable_sandboxes" == "true" ]]; then
  _ssm_secret "sandbox-juicefs-redis-auth-token" "$_SETUP_DIR/.sandbox_juicefs_redis_auth_token" "TF_VAR_sandbox_juicefs_redis_auth_token" \
    "openssl rand -hex 32" "" "true"
fi

# ── Stable auto-generated secrets (must never change after first deployment) ──
# Changing api_key_salt invalidates ALL existing API keys.
# Changing jwt_secret invalidates ALL active user sessions.
_ssm_secret "langsmith-api-key-salt" "$_SETUP_DIR/.api_key_salt" "TF_VAR_langsmith_api_key_salt" \
  "openssl rand -base64 32" "" "true"

_ssm_secret "langsmith-jwt-secret" "$_SETUP_DIR/.jwt_secret" "TF_VAR_langsmith_jwt_secret" \
  "openssl rand -base64 32" "" "true"

if [[ "$_enable_sandboxes" == "true" ]]; then
  _ssm_secret "sandbox-callback-signing-jwk" "$_SETUP_DIR/.sandbox_callback_signing_jwk" "TF_VAR_sandbox_callback_signing_jwk" \
    "_ed25519_private_jwk_gen" "" "true"
fi

# ── LangSmith app secrets (consumed by ESO → K8s Secret → Helm chart) ────────
_ssm_secret "langsmith-license-key" "$_SETUP_DIR/.license_key" "LANGSMITH_LICENSE_KEY" \
  "" "LangSmith license key" "true"

_ssm_secret "langsmith-admin-password" "$_SETUP_DIR/.admin_password" "LANGSMITH_ADMIN_PASSWORD" \
  "" "Admin password (min 12 chars, must contain lowercase, uppercase, and a symbol: \!#\$%()+,-./:?@[\\]^_{~})" "true"

_ssm_secret "langsmith-admin-email" "$_SETUP_DIR/.admin_email" "LANGSMITH_ADMIN_EMAIL" \
  "" "Admin email" "false"

# Check chart password requirements before the later Helm deployment.
if [[ -n "$LANGSMITH_ADMIN_PASSWORD" ]]; then
  _pw_error=""
  if [[ ${#LANGSMITH_ADMIN_PASSWORD} -lt 12 ]]; then
    _pw_error="must be at least 12 characters long"
  elif ! printf '%s' "$LANGSMITH_ADMIN_PASSWORD" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
    _pw_error="must contain at least one symbol: !#\$%()+,-./:?@[\\]^_{~}"
  elif ! printf '%s' "$LANGSMITH_ADMIN_PASSWORD" | grep -q '[a-z]'; then
    _pw_error="must contain at least one lowercase letter"
  elif ! printf '%s' "$LANGSMITH_ADMIN_PASSWORD" | grep -q '[A-Z]'; then
    _pw_error="must contain at least one uppercase letter"
  fi
  if [[ -n "$_pw_error" ]]; then
    echo "ERROR: Admin password is invalid — ${_pw_error}." >&2
    echo "       Unset LANGSMITH_ADMIN_PASSWORD," >&2
    echo "       delete the SSM parameter at ${_ssm_prefix}/langsmith-admin-password," >&2
    echo "       and re-source this script with a valid password." >&2
    return 1
  fi
fi

# ── Feature encryption keys ──────────────────────────────────────────────────
# Fernet keys for Deployments, Fleet, Insights, and LangSmith Chat (formerly Polly).
# Created on first setup even for disabled features. apply-eso.sh dynamically
# includes whichever keys exist in SSM.
# Fernet key = 32 random bytes, URL-safe base64-encoded (openssl, no Python needed).
_fernet_gen='openssl rand -base64 32 | tr "+/" "-_" | tr -d "\n"'

_ssm_secret "deployments-encryption-key" "$_SETUP_DIR/.deployments_encryption_key" "TF_VAR_langsmith_deployments_encryption_key" \
  "$_fernet_gen" "" "true"

_ssm_secret "agent-builder-encryption-key" "$_SETUP_DIR/.agent_builder_encryption_key" "TF_VAR_langsmith_agent_builder_encryption_key" \
  "$_fernet_gen" "" "true"

_ssm_secret "insights-encryption-key" "$_SETUP_DIR/.insights_encryption_key" "TF_VAR_langsmith_insights_encryption_key" \
  "$_fernet_gen" "" "true"

_ssm_secret "polly-encryption-key" "$_SETUP_DIR/.polly_encryption_key" "TF_VAR_langsmith_polly_encryption_key" \
  "$_fernet_gen" "" "true"

# ── Non-interactive failure ───────────────────────────────────────────────────
# Report values that were absent from SSM, local files, and the shell and
# require interactive input; no success summary is printed for a failed setup.
if [[ -n "$_missing_vars" ]]; then
  echo ""
  echo "ERROR: stdin is not a tty, so setup-env.sh cannot prompt for secrets."
  echo "       Missing:$_missing_vars"
  echo ""
  echo "       Run it from a real terminal, or pre-set the values:"
  # Split on spaces with tr rather than an unquoted expansion: this script is
  # sourced, and zsh does not word-split, so `for _v in $_missing_vars` would
  # print every name on a single bogus export line.
  echo "$_missing_vars" | tr ' ' '\n' | while read -r _v; do
    if [[ -n "$_v" ]]; then echo "         export $_v='<value>'"; fi
  done
  echo ""
  echo "       Then re-run: source infra/scripts/setup-env.sh"
  return 1
fi

if [[ -n "$_ssm_failed" ]]; then
  echo "ERROR: Secret setup failed. Resolve the errors above before applying."
  return 1
fi

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
if [[ "$_enable_sandboxes" == "true" ]]; then
  echo "  juicefs_redis     = (hidden — SSM: ${_ssm_prefix}/sandbox-juicefs-redis-auth-token)"
fi
echo "  api_key_salt      = (hidden — SSM: ${_ssm_prefix}/langsmith-api-key-salt)"
echo "  jwt_secret        = (hidden — SSM: ${_ssm_prefix}/langsmith-jwt-secret)"
if [[ "$_enable_sandboxes" == "true" ]]; then
  echo "  sandbox_cb_jwk    = (hidden — SSM: ${_ssm_prefix}/sandbox-callback-signing-jwk)"
fi
echo "  license_key       = (hidden — SSM: ${_ssm_prefix}/langsmith-license-key)"
echo "  admin_password    = (hidden — SSM: ${_ssm_prefix}/langsmith-admin-password)"
echo "  admin_email       = (stored — SSM: ${_ssm_prefix}/langsmith-admin-email)"
echo "  deploy_key        = (hidden — SSM: ${_ssm_prefix}/deployments-encryption-key)"
echo "  fleet_key         = (hidden — SSM: ${_ssm_prefix}/agent-builder-encryption-key; historical name)"
echo "  insights_key      = (hidden — SSM: ${_ssm_prefix}/insights-encryption-key)"
echo "  ssm_prefix        = $_ssm_prefix"
echo ""
echo "Next:  terraform -chdir=infra apply"
echo "       aws eks update-kubeconfig --region $AWS_REGION --name ${_name_prefix}-${_environment}-eks"
echo "       make init-values  (or: ./helm/scripts/init-values.sh)"
echo "       ./helm/scripts/deploy.sh"
