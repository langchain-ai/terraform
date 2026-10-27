#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# seed-keyvault-secrets.sh — Write LangSmith app secrets straight into Key Vault
#
# Usage:
#   cd terraform/modules/azure/infra
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
#   postgres-admin-password                  — from secrets.auto.tfvars or the env
#   langsmith-license-key                    — same, and skipped when unset
#   langsmith-admin-password                 — prompted, or $LANGSMITH_ADMIN_PASSWORD
#   langsmith-api-key-salt                   — generated
#   langsmith-jwt-secret                     — generated
#   langsmith-deployments-encryption-key     — generated (Fernet)
#   langsmith-agent-builder-encryption-key   — generated (Fernet)
#   langsmith-insights-encryption-key        — generated (Fernet)
#   langsmith-polly-encryption-key           — generated (Fernet)
#   smithdb-taskdb-password                  — generated (hex)
#   langsmith-sandbox-callback-signing-jwk   — generated (Ed25519 JWK), enable_sandboxes only
#   langsmith-sandbox-service-auth-secret    — generated (hex), sandbox_deployment_mode = separate_cluster only
#
# The LangSmith secrets are deliberately NOT Terraform-managed: Terraform
# would persist their plaintext in state. This mirrors the AWS module (writes SSM)
# and the GCP module (writes Secret Manager). Terraform owns only the vault and
# its RBAC.
#
# postgres-admin-password and langsmith-license-key are Terraform's on the
# default path, and seeded here for keyvault_manage_secrets = false, where apply
# left them out. Write-once means both paths end with the same ten. They go
# last, so a value this script cannot resolve never costs the eight above.
#
# WRITE-ONCE: an existing secret is never overwritten. Rotating any of these
# breaks running deployments — a new API key salt invalidates every API key, a
# new JWT secret drops every session, a new Fernet key makes existing encrypted
# data unreadable, and a new taskdb password locks the migration Job out of a
# taskdb that already initialized with the old one. Rotate deliberately via `make keyvault` instead.
#
# Safe to re-run: it seeds only what is missing.

RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[0;90m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _validate_admin_password lives here so `make keyvault set` enforces the same
# rules as this script.
source "$SCRIPT_DIR/_common.sh"

# ── Resolve Key Vault name ─────────────────────────────────────────────────────
# Priority: terraform output → derived from terraform.tfvars.
if KV_NAME=$(_tf_out keyvault_name); then
  : # got it from terraform output
else
  KV_NAME=$(_require_kv_name) || exit 1
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

# ── SmithDB taskdb password ───────────────────────────────────────────────────
# The chart refuses to render the backfill without a taskdb credential.
# create-k8s-secrets.sh copies it into the smithdb-taskdb secret. Seeded
# unconditionally, like the Fernet keys, so the backfill phase needs no extra
# step. Hex, because it carries no character a connection string would need
# escaped.

_seed "smithdb-taskdb-password" "$(openssl rand -hex 32)" \
  "component=smithdb stability=critical module=seed-script"

# ── Sandbox callback signing key ──────────────────────────────────────────────
# An Ed25519 private JWK. platform-backend signs sandbox callbacks with it and
# sandbox-host verifies them; create-k8s-secrets.sh copies it into
# langsmith-config-secret as sandbox_callback_signing_jwk. Seeded only with
# enable_sandboxes = true, because it needs OpenSSL 3: the LibreSSL that macOS
# ships has no Ed25519. Rotating it drops the callbacks of running sandboxes.

_b64url_nopad() {
  base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

# The last 32 bytes of the PKCS#8 private key are the seed (d) and of the SPKI
# public key the point (x). Same generator as the GCP module's setup-env.sh.
_gen_ed25519_jwk() {
  local tmpdir d x
  tmpdir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/langsmith-jwk.XXXXXX") || return 1
  if openssl genpkey -algorithm ED25519 -out "$tmpdir/key.pem" >/dev/null 2>&1 \
    && openssl pkey -in "$tmpdir/key.pem" -outform DER -out "$tmpdir/private.der" >/dev/null 2>&1 \
    && openssl pkey -in "$tmpdir/key.pem" -pubout -outform DER -out "$tmpdir/public.der" >/dev/null 2>&1; then
    d=$(tail -c 32 "$tmpdir/private.der" | _b64url_nopad)
    x=$(tail -c 32 "$tmpdir/public.der" | _b64url_nopad)
  fi
  rm -rf "$tmpdir"
  [[ -n "${d:-}" && -n "${x:-}" ]] || return 1
  printf '{"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"sandbox-callback-%s","x":"%s","d":"%s"}' \
    "$(openssl rand -hex 8)" "$x" "$d"
}

if _tfvar_is_true "enable_sandboxes"; then
  _seed "langsmith-sandbox-callback-signing-jwk" "$(_gen_ed25519_jwk || true)" \
    "component=sandboxes stability=critical module=seed-script" \
    "Generating it needs OpenSSL 3 with Ed25519 (openssl version; on macOS: brew install openssl@3)."
fi

# ── Sandbox service-auth secret ───────────────────────────────────────────────
# separate_cluster only. It signs the calls between LangSmith and the sandbox
# hosts, so the sandbox cluster, which runs untrusted code, never holds
# langsmith-api-key-salt. The langsmith chart refuses separateCluster without
# it. create-k8s-secrets.sh copies it into langsmith-config-secret and into the
# sandbox cluster's runtime Secret. Hex, like the taskdb password, so it is never
# mistaken for the base64 salt. Rotating it drops calls to the hosts until both
# copies match again.

if _separate_cluster_sandboxes; then
  _seed "langsmith-sandbox-service-auth-secret" "$(openssl rand -hex 32)" \
    "component=sandboxes stability=critical module=seed-script"
fi

# ── Terraform's two secrets ───────────────────────────────────────────────────
# Skips on the default path; written here when keyvault_manage_secrets = false
# left them out. create-k8s-secrets.sh needs langsmith-license-key to build
# langsmith-config-secret.
#
# Last on purpose: resolving either value can fail (secrets.auto.tfvars is
# gitignored), and nothing else writes the eight above.

_pg_password="${LANGSMITH_PG_PASSWORD:-${TF_VAR_postgres_admin_password:-}}"
if [[ -z "$_pg_password" ]]; then
  _pg_password=$(_parse_tfvar_quoted postgres_admin_password "secrets.auto.tfvars") || _pg_password=""
fi

_license_key="${LANGSMITH_LICENSE_KEY:-${TF_VAR_langsmith_license_key:-}}"
if [[ -z "$_license_key" ]]; then
  _license_key=$(_parse_tfvar_quoted langsmith_license_key "secrets.auto.tfvars") || _license_key=""
fi

# No license key is supported: the Terraform resource and k8s-bootstrap carry the
# same guard. Skip rather than fail.
if _kv_exists "langsmith-license-key"; then
  echo -e "  ${DIM}skip${NC}  langsmith-license-key ${DIM}(already set)${NC}"
elif [[ -n "$_license_key" ]]; then
  _seed "langsmith-license-key" "$_license_key" \
    "component=langsmith module=seed-script"
else
  echo -e "  ${DIM}skip${NC}  langsmith-license-key ${DIM}(no value configured)${NC}"
fi

_seed "postgres-admin-password" "$_pg_password" \
  "component=postgres module=seed-script" \
  "Set LANGSMITH_PG_PASSWORD, or re-run ./setup-env.sh to write secrets.auto.tfvars."

unset _pg_password _license_key

echo ""
echo "  Done."
echo ""
echo "Next:"
echo "  make k8s-secrets   # sync Key Vault → langsmith-config-secret"
echo ""
