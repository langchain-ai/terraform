#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# setup-env.sh — Create or complete the LangSmith app secrets for bare metal.
#
# Usage (from baremetal/):
#   make setup-env            or   infra/scripts/setup-env.sh
#
# Reads/writes: infra/.secrets.env (KEY=value, mode 600, gitignored) via the
# file backend in _common.sh. deploy.sh copies it into the langsmith-config
# Kubernetes Secret.
#
# Unlike the cloud modules, this is executed, not sourced: Terraform here never
# consumes the app secrets, so nothing needs exporting into your shell.
#
# Order for each key: value already in the store → keep it (never rotated);
# else environment variable of the same name → else prompt (or generate).
# Rotating API_KEY_SALT or JWT_SECRET invalidates every API key and session,
# so this script never replaces an existing value. Values are never printed.
#
# Non-interactive use: export LANGSMITH_LICENSE_KEY, INITIAL_ORG_ADMIN_EMAIL and
# INITIAL_ORG_ADMIN_PASSWORD before running.

# Refuse to be sourced: set -e would leak into the caller's shell.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "ERROR: run this script, do not source it: ${BASH_SOURCE[0]}" >&2
  return 1
fi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

command -v openssl >/dev/null || { fail "openssl is required to generate secrets"; exit 1; }

# _ensure_secret KEY PROMPT SILENT VALIDATOR GENERATOR
#   PROMPT     text shown when asking; empty = never prompt
#   SILENT     true = hide input (passwords, keys)
#   VALIDATOR  function name or empty; prints a reason and returns 1 on reject
#   GENERATOR  function name or empty; used instead of prompting
_ensure_secret() {
  local key="$1" prompt="$2" silent="$3" validator="$4" generator="$5"
  local val reason attempt=0

  val="$(_secret_get "$key")"
  if [[ -n "$val" ]]; then
    if [[ -n "$validator" ]] && ! reason="$("$validator" "$val")"; then
      fail "$key in $SECRETS_FILE is invalid: $reason"
      fail "Fix or delete that line in the file, then rerun."
      return 1
    fi
    skip "$key already set (kept)"
    return 0
  fi

  val="${!key:-}"
  if [[ -n "$val" ]]; then
    if [[ -n "$validator" ]] && ! reason="$("$validator" "$val")"; then
      fail "$key from the environment is invalid: $reason"
      return 1
    fi
    _secret_put "$key" "$val"
    pass "$key stored (from environment)"
    return 0
  fi

  if [[ -n "$generator" ]]; then
    val="$("$generator")"
    [[ -n "$val" ]] || { fail "generator for $key produced nothing"; return 1; }
    _secret_put "$key" "$val"
    pass "$key generated and stored"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    fail "$key is not set and stdin is not a terminal; export $key and rerun."
    return 1
  fi
  while true; do
    attempt=$((attempt + 1))
    printf '  %s: ' "$prompt"
    if [[ "$silent" == "true" ]]; then
      read -rs val
      echo
    else
      read -r val
    fi
    if [[ -z "$val" ]]; then
      fail "no value entered for $key"
      return 1
    fi
    if [[ -z "$validator" ]] || reason="$("$validator" "$val")"; then
      break
    fi
    warn "Rejected: $reason"
    if (( attempt >= 3 )); then
      fail "$key still invalid after $attempt attempts; nothing stored."
      return 1
    fi
  done
  _secret_put "$key" "$val"
  pass "$key stored"
}

header "LangSmith app secrets → $SECRETS_FILE"
_secrets_file_check

# Prompts use single quotes: the symbol list holds $ and !.
_ensure_secret LANGSMITH_LICENSE_KEY "LangSmith license key (input hidden)" true _validate_license_key ""
# The email is configuration, as on the cloud modules (#429): asked only when terraform.tfvars has none.
[[ -n "$(_parse_tfvar langsmith_admin_email)" ]] \
  || _ensure_secret INITIAL_ORG_ADMIN_EMAIL "Initial org admin email" false _validate_email ""
_ensure_secret INITIAL_ORG_ADMIN_PASSWORD 'Initial org admin password (input hidden; >= 12 bytes, lower, upper, one of !#$%()+,-./:?@[]^_{~})' true _validate_admin_password ""
_ensure_secret API_KEY_SALT "" false "" _secret_gen_b64
_ensure_secret JWT_SECRET "" false "" _secret_gen_b64

# Fernet keys, only for the features that need them. Fleet's key keeps the
# legacy name: chart 0.17.6 stores fleet.encryptionKey in the Secret key
# agent_builder_encryption_key (Agent Builder itself is gone; Fleet replaced it).
if _tfvar_is_true enable_fleet; then
  _ensure_secret AGENT_BUILDER_ENCRYPTION_KEY "" false "" _secret_gen_fernet
fi
# Engine runs on the Insights deployment, which reads this key whichever of the two turned it on.
if _tfvar_is_true enable_standalone_insights || _tfvar_is_true enable_engine; then
  _ensure_secret INSIGHTS_ENCRYPTION_KEY "" false "" _secret_gen_fernet
fi
if _tfvar_is_true enable_standalone_polly; then
  _ensure_secret POLLY_ENCRYPTION_KEY "" false "" _secret_gen_fernet
fi
if _tfvar_is_true enable_sandboxes; then
  _ensure_secret SANDBOX_CALLBACK_SIGNING_JWK "" false "" _ed25519_private_jwk_gen
fi
# Engine's own two keys: the 0.17 chart rejects Engine without the usage signing secret.
if _tfvar_is_true enable_engine; then
  _ensure_secret ENGINE_ENCRYPTION_KEY "" false "" _secret_gen_fernet
  _ensure_secret ENGINE_USAGE_SIGNING_SECRET "" false "" _secret_gen_hex32
fi

# SSO: the identity provider's OIDC client, read by the chart from langsmith-config.
if _tfvar_is_true enable_sso_oidc; then
  _ensure_secret OAUTH_CLIENT_ID "OIDC client ID" false "" ""
  _ensure_secret OAUTH_CLIENT_SECRET "OIDC client secret (input hidden)" true "" ""
  _ensure_secret OAUTH_ISSUER_URL "OIDC issuer URL (https://...)" false _validate_https_url ""
fi

_secrets_file_check
header "Done"
info "Values are stored, never printed. Back up $SECRETS_FILE with terraform.tfstate."
action "Next: make init-values"
