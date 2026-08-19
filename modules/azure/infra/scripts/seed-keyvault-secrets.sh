#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# seed-keyvault-secrets.sh — Write LangSmith app secrets straight into Key Vault
#
# Usage:
#   cd terraform/azure/infra
#   ./scripts/seed-keyvault-secrets.sh
#
# Prerequisites:
#   - terraform apply complete (the Key Vault exists)
#   - az login with a principal holding "Key Vault Secrets Officer" on the vault
#     (terraform apply grants this to the deployer identity, unless
#     keyvault_manage_terraform_admin_assignment = false, where a tenant admin
#     granted it out of band instead)
#
# What this seeds:
#   postgres-admin-password                  — from secrets.auto.tfvars
#   langsmith-license-key                    — from secrets.auto.tfvars
#   langsmith-admin-password                 — prompted, or $LANGSMITH_ADMIN_PASSWORD
#   langsmith-api-key-salt                   — generated
#   langsmith-jwt-secret                     — generated
#   langsmith-deployments-encryption-key     — generated (Fernet)
#   langsmith-agent-builder-encryption-key   — generated (Fernet)
#   langsmith-insights-encryption-key        — generated (Fernet)
#   langsmith-polly-encryption-key           — generated (Fernet)
#
# The seven LangSmith secrets are deliberately NOT Terraform-managed: Terraform
# would persist their plaintext in state. This mirrors the AWS module (writes SSM)
# and the GCP module (writes Secret Manager). Terraform owns only the vault and
# its RBAC.
#
# The first two are Terraform's, and it writes them itself on the default path.
# They are seeded here for keyvault_manage_secrets = false, where the deployer
# holds no Key Vault data-plane access and apply left them out. Write-once means
# the default path just skips them, so both paths end with the same nine secrets
# in the vault.
#
# WRITE-ONCE: an existing secret is never overwritten. Rotating any of these
# breaks running deployments — a new API key salt invalidates every API key, a
# new JWT secret drops every session, a new Fernet key makes existing encrypted
# data unreadable. Rotate deliberately via `make keyvault` instead.
#
# Safe to re-run: it seeds only what is missing.

RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[0;90m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# _validate_admin_password lives here so `make keyvault set` enforces the same
# rules as this script.
source "$SCRIPT_DIR/_common.sh"

# ── Resolve Key Vault name ─────────────────────────────────────────────────────
# Priority: terraform output → derived from terraform.tfvars. The -n guard is not
# redundant: `terraform output -raw` exits 0 against an empty state and prints its
# "no outputs" warning to stdout, so an exit-code-only check assigns the warning
# text as the vault name.
if KV_NAME=$(cd "$INFRA_DIR" && terraform output -raw keyvault_name 2>/dev/null) && [[ -n "$KV_NAME" ]]; then
  : # got it from terraform output
else
  KV_NAME=$(_derive_kv_name)
  echo "  (terraform output unavailable — using derived KV name: $KV_NAME)"
fi

echo ""
echo "LangSmith — seed Key Vault secrets"
echo "  key_vault : $KV_NAME"
echo ""

if ! az keyvault show --name "$KV_NAME" --output none 2>/dev/null; then
  echo -e "  ${RED}Key Vault $KV_NAME not found.${NC}" >&2
  echo "  Run 'make apply' first — Terraform creates the vault and grants you" >&2
  echo "  the Key Vault Secrets Officer role on it." >&2
  exit 1
fi

# ── Secret helpers ─────────────────────────────────────────────────────────────

_kv_exists() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --output none 2>/dev/null
}

# Write a secret via --file rather than --value: --value puts the plaintext in
# the process argument list, where any user on the host can read it from `ps`.
# The temp file is created under a 077 umask and removed on exit. printf '%s'
# writes no trailing newline — az sends the file byte-for-byte, and a stray \n
# in a password or Fernet key breaks authentication in ways that are miserable
# to debug.
_kv_set() {
  local secret_name="$1" secret_value="$2" tags="$3" tmpfile
  tmpfile=$(umask 077 && mktemp "${TMPDIR:-/tmp}/langsmith-kv.XXXXXX")
  # shellcheck disable=SC2064 # expand tmpfile now, not at trap time
  trap "rm -f '$tmpfile'" EXIT INT TERM

  printf '%s' "$secret_value" > "$tmpfile"

  # shellcheck disable=SC2086 # tags is an intentional word-split list
  az keyvault secret set \
    --vault-name "$KV_NAME" \
    --name "$secret_name" \
    --file "$tmpfile" \
    --content-type "text/plain" \
    --tags $tags \
    --output none

  rm -f "$tmpfile"
  trap - EXIT INT TERM
}

# _seed <secret-name> <value> <tags> [hint]
# Skips if the secret already exists. Never overwrites. <hint> is printed when
# the value is empty, for the secrets this script does not generate itself.
_seed() {
  local secret_name="$1" secret_value="$2" tags="$3" hint="${4:-}"

  if _kv_exists "$secret_name"; then
    echo -e "  ${DIM}skip${NC}  $secret_name ${DIM}(already set)${NC}"
    return 0
  fi

  if [[ -z "$secret_value" ]]; then
    echo -e "  ${RED}fail${NC}  $secret_name (empty value)" >&2
    if [[ -n "$hint" ]]; then
      echo "        $hint" >&2
    fi
    return 1
  fi

  _kv_set "$secret_name" "$secret_value" "$tags"
  echo -e "  ${GREEN}set${NC}   $secret_name"
}

# Fernet key: 32 random bytes, URL-safe base64. Matches the AWS module's
# generator — openssl only, no python3 dependency.
_gen_fernet() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n'
}

_gen_b64() {
  openssl rand -base64 32 | tr -d '\n'
}

# ── Seed ───────────────────────────────────────────────────────────────────────

echo "  Seeding..."

# ── Terraform's two secrets ───────────────────────────────────────────────────
# Present already on the default path, so these are skips. On the
# keyvault_manage_secrets = false path they are missing and get written here from
# the same secrets.auto.tfvars that fed terraform apply, so the vault ends up
# with identical contents either way. langsmith-license-key matters most:
# create-k8s-secrets.sh reads it out of the vault to build
# langsmith-config-secret.

_pg_password="${LANGSMITH_PG_PASSWORD:-}"
if [[ -z "$_pg_password" ]]; then
  _pg_password=$(_parse_tfvar_quoted postgres_admin_password "secrets.auto.tfvars") || _pg_password=""
fi

_license_key="${LANGSMITH_LICENSE_KEY:-}"
if [[ -z "$_license_key" ]]; then
  _license_key=$(_parse_tfvar_quoted langsmith_license_key "secrets.auto.tfvars") || _license_key=""
fi

_seed "postgres-admin-password" "$_pg_password" \
  "component=postgres module=seed-script" \
  "Set LANGSMITH_PG_PASSWORD, or re-run ./setup-env.sh to write secrets.auto.tfvars."
_seed "langsmith-license-key" "$_license_key" \
  "component=langsmith module=seed-script" \
  "Set LANGSMITH_LICENSE_KEY, or re-run ./setup-env.sh to write secrets.auto.tfvars."

unset _pg_password _license_key

# ── LangSmith admin password ──────────────────────────────────────────────────

if _kv_exists "langsmith-admin-password"; then
  echo -e "  ${DIM}skip${NC}  langsmith-admin-password ${DIM}(already set)${NC}"
else
  admin_password="${LANGSMITH_ADMIN_PASSWORD:-}"

  if [[ -z "$admin_password" ]]; then
    if [[ ! -t 0 ]]; then
      echo -e "  ${RED}langsmith-admin-password is not set and stdin is not a tty.${NC}" >&2
      echo "  Set it to run non-interactively:" >&2
      echo "    export LANGSMITH_ADMIN_PASSWORD=..." >&2
      exit 1
    fi
    echo ""
    echo "  Initial LangSmith admin password"
    echo "    min 12 chars, with a lowercase letter, an uppercase letter,"
    echo "    and a symbol from: !#\$%()+,-./:?@[\\]^_{~}"
    printf "    password: "
    read -rs admin_password
    echo ""
  fi

  if ! _pw_err=$(_validate_admin_password "$admin_password"); then
    echo -e "  ${RED}${_pw_err}${NC}" >&2
    exit 1
  fi

  _seed "langsmith-admin-password" "$admin_password" "component=langsmith module=seed-script"
  unset admin_password
fi

# ── Stable app secrets ─────────────────────────────────────────────────────────

_seed "langsmith-api-key-salt" "$(_gen_b64)" \
  "component=langsmith stability=critical module=seed-script"
_seed "langsmith-jwt-secret" "$(_gen_b64)" \
  "component=langsmith stability=critical module=seed-script"

# ── LangGraph Platform Fernet keys ─────────────────────────────────────────────
# Seeded unconditionally so enabling a feature later never requires a rotation.

_seed "langsmith-deployments-encryption-key" "$(_gen_fernet)" \
  "component=deployments stability=critical module=seed-script"
_seed "langsmith-agent-builder-encryption-key" "$(_gen_fernet)" \
  "component=agent-builder stability=critical module=seed-script"
_seed "langsmith-insights-encryption-key" "$(_gen_fernet)" \
  "component=insights stability=critical module=seed-script"
_seed "langsmith-polly-encryption-key" "$(_gen_fernet)" \
  "component=polly stability=critical module=seed-script"

echo ""
echo "  Done."
echo ""
echo "Next:"
echo "  make k8s-secrets   # sync Key Vault → langsmith-config-secret"
echo ""
