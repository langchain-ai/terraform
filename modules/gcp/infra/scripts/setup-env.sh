#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# setup-env.sh — Configure Terraform variables for LangSmith on GCP
#
# Usage (from gcp/):
#   source infra/scripts/setup-env.sh
#
# Run with `source` so exported variables persist in your shell session.
# Do NOT commit terraform.tfvars with real passwords — use this script instead.
#
# Secret storage:
#   Secrets are stored in GCP Secret Manager under:
#     projects/{project_id}/secrets/langsmith-{name_prefix}-{environment}-{key}
#   On subsequent runs, this script reads secrets FROM Secret Manager — no
#   re-prompting needed. If Secret Manager is not yet enabled (first run),
#   secrets are exported for this session only and stored once the API is up.
#
# Prerequisites:
#   gcloud auth application-default login   (or a service account with secretmanager.admin)
#   Secret Manager API must be enabled (enabled automatically by terraform apply)
#
# NOTE: No `set -euo pipefail` — this script is intended to be sourced.

# Resolve infra directory so this script works regardless of where it's sourced from.
_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# ── Read project/env from terraform.tfvars ────────────────────────────────────
_tfvars_parse() {
  grep -E "^\s*${1}\s*=" "$_SETUP_DIR/terraform.tfvars" 2>/dev/null \
    | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]'
}

_project_id=$(_tfvars_parse "project_id")
_name_prefix=$(_tfvars_parse "name_prefix")
_environment=$(_tfvars_parse "environment")
_region=$(_tfvars_parse "region")
_region="${_region:-us-west2}"

if [[ -z "$_project_id" ]]; then
  echo "ERROR: project_id is not set in terraform.tfvars. Set it before sourcing setup-env.sh." >&2
  return 1
fi

if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: name_prefix is not set in terraform.tfvars. Set it before sourcing setup-env.sh." >&2
  return 1
fi

export TF_VAR_project_id="$_project_id"
export TF_VAR_name_prefix="$_name_prefix"
export TF_VAR_environment="${_environment:-dev}"
export TF_VAR_region="$_region"
export TF_VAR_owner="${LANGSMITH_OWNER:-}"
export TF_VAR_cost_center="${LANGSMITH_COST_CENTER:-}"

# ── Secret Manager path prefix ────────────────────────────────────────────────
# All secrets are stored under:
#   projects/{project_id}/secrets/langsmith-{name_prefix}-{environment}-{key}
_sm_prefix="langsmith-${_name_prefix}-${_environment}"

# ── Warn on pre-exported secrets ──────────────────────────────────────────────
for _precheck_var in TF_VAR_langsmith_license_key; do
  if [[ -n "$(printenv "$_precheck_var")" ]]; then
    echo "WARNING: $_precheck_var is already set in the environment."
    echo "         setup-env.sh will skip re-prompting and will NOT write to Secret Manager for this key."
    echo "         To rotate or re-store: unset $_precheck_var && source infra/scripts/setup-env.sh"
    echo ""
  fi
done

# ── Safe Secret Manager write ─────────────────────────────────────────────────
# Creates a new secret version (or the secret itself if it doesn't exist yet).
# Accepts value via stdin to avoid exposing it in the process list.
_sm_put() {
  local _name="$1" _val="$2"
  local _secret_id="${_sm_prefix}-${_name}"

  # Create the secret resource if it doesn't exist
  if ! gcloud secrets describe "$_secret_id" --project="$_project_id" &>/dev/null; then
    gcloud secrets create "$_secret_id" \
      --project="$_project_id" \
      --replication-policy="automatic" \
      --labels="managed-by=setup-env,langsmith-env=${_environment}" \
      --quiet &>/dev/null || return 1
  fi

  # Add a new version with the value
  printf '%s' "$_val" | gcloud secrets versions add "$_secret_id" \
    --project="$_project_id" \
    --data-file=- \
    --quiet &>/dev/null
}

# ── Secret Manager read ───────────────────────────────────────────────────────
_sm_get() {
  local _name="$1"
  local _secret_id="${_sm_prefix}-${_name}"
  gcloud secrets versions access latest \
    --secret="$_secret_id" \
    --project="$_project_id" \
    --quiet 2>/dev/null || true
}

# ── sm_secret helper ──────────────────────────────────────────────────────────
# Reads a secret from Secret Manager; prompts or auto-generates if missing;
# exports as a TF_VAR_* environment variable.
#
# Args:
#   $1  sm_name      — Secret Manager leaf name (e.g. "postgres-password")
#   $2  varname      — environment variable name to export
#   $3  generator    — Shell command that outputs a new value (empty = prompt)
#   $4  prompt_text  — Prompt string for interactive input
#   $5  silent       — "true" to hide input (passwords); "false" for plaintext
_sm_secret() {
  local sm_name="$1"
  local varname="$2"
  local generator="$3"
  local prompt_text="$4"
  local silent="${5:-true}"

  local val=""
  local _secret_id="${_sm_prefix}-${sm_name}"

  # 0. Already exported in the environment — use as-is, backfill SM if missing.
  if [[ -n "$(printenv "$varname")" ]]; then
    if ! gcloud secrets describe "$_secret_id" --project="$_project_id" &>/dev/null; then
      echo "  $varname is set in env but missing from Secret Manager — backfilling → ${_secret_id}"
      if ! _sm_put "$sm_name" "$(printenv "$varname")"; then
        echo "  WARNING: Secret Manager write failed for ${_secret_id}"
        echo "           Ensure secretmanager.googleapis.com is enabled and you have secretmanager.admin."
      fi
    fi
    return
  fi

  # 1. Try Secret Manager
  val=$(_sm_get "$sm_name") || val=""

  # 2. Prompt or generate if still empty
  if [[ -z "$val" ]]; then
    if [[ -n "$generator" ]]; then
      val=$(eval "$generator") || {
        echo "ERROR: Secret generator failed for $varname." >&2
        echo "       Command: $generator" >&2
        echo "       Ensure required tools are installed (e.g. openssl)." >&2
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
      echo "         Or populate Secret Manager directly:" >&2
      echo "           printf '%s' '<value>' | gcloud secrets versions add ${_secret_id} \\" >&2
      echo "             --project=${_project_id} --data-file=-" >&2
      return 1
    fi

    # Store in Secret Manager
    if _sm_put "$sm_name" "$val"; then
      echo "  Stored $varname → Secret Manager: ${_secret_id}"
    else
      echo "  WARNING: Secret Manager unavailable — value exported for this session only."
      echo "           Re-run setup-env.sh after 'terraform apply' to persist to Secret Manager."
    fi
  fi

  export "$varname"="$val"
}

# ── Fernet key generator ──────────────────────────────────────────────────────
# Fernet key = 32 random bytes, URL-safe base64-encoded.
_fernet_gen='openssl rand -base64 32 | tr "+/" "-_" | tr -d "\n"'

# ── PostgreSQL ────────────────────────────────────────────────────────────────
_sm_secret "postgres-password" "TF_VAR_postgres_password" \
  "" "PostgreSQL admin password" "true"

# ── LangSmith license key ─────────────────────────────────────────────────────
_sm_secret "langsmith-license-key" "TF_VAR_langsmith_license_key" \
  "" "LangSmith license key" "true"

# ── Core LangSmith secrets (must stay stable after first deploy) ─────────────
_sm_secret "api-key-salt" "TF_VAR_langsmith_api_key_salt" \
  "openssl rand -base64 32 | tr -d '\n'" "" "true"

_sm_secret "jwt-secret" "TF_VAR_langsmith_jwt_secret" \
  "openssl rand -base64 32 | tr -d '\n'" "" "true"

_sm_secret "admin-password" "TF_VAR_langsmith_admin_password" \
  "" "Initial LangSmith admin password" "true"

# ── LangGraph Platform Encryption Keys (optional) ────────────────────────────
# Auto-generated and stored in Secret Manager on first run.
# Only used when the corresponding feature flag is set to true in terraform.tfvars.
# WARNING: Never change these after the first deployment — existing data will
# become unreadable. Rotation requires a coordinated migration procedure.
_sm_secret "deployments-encryption-key" "TF_VAR_langsmith_deployments_encryption_key" \
  "$_fernet_gen" "" "true"

_sm_secret "agent-builder-encryption-key" "TF_VAR_langsmith_agent_builder_encryption_key" \
  "$_fernet_gen" "" "true"

_sm_secret "insights-encryption-key" "TF_VAR_langsmith_insights_encryption_key" \
  "$_fernet_gen" "" "true"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Terraform environment variables set."
echo ""
echo "  project_id        = $_project_id"
echo "  name_prefix       = $_name_prefix"
echo "  environment       = $_environment"
echo "  region            = $_region"
echo "  postgres_password = (hidden — SM: ${_sm_prefix}-postgres-password)"
echo "  license_key       = (hidden — SM: ${_sm_prefix}-langsmith-license-key)"
echo "  api_key_salt      = (hidden — SM: ${_sm_prefix}-api-key-salt)"
echo "  jwt_secret        = (hidden — SM: ${_sm_prefix}-jwt-secret)"
echo "  admin_password    = (hidden — SM: ${_sm_prefix}-admin-password)"
echo "  deploy_key        = (hidden — SM: ${_sm_prefix}-deployments-encryption-key)"
echo "  ab_key            = (hidden — SM: ${_sm_prefix}-agent-builder-encryption-key)"
echo "  insights_key      = (hidden — SM: ${_sm_prefix}-insights-encryption-key)"
echo "  sm_prefix         = ${_sm_prefix}"
echo ""
echo "Next:  terraform -chdir=infra init"
echo "       terraform -chdir=infra apply"
echo "       make init-values  (or: ./helm/scripts/init-values.sh)"
echo "       ./helm/scripts/deploy.sh"
