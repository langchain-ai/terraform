#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# setup-env.sh — Bootstrap Terraform inputs for LangSmith (Pass 1)
#
# Usage:
#   ./setup-env.sh
#
# Writes the values Terraform itself needs to secrets.auto.tfvars (gitignored).
# Terraform picks this file up automatically — no shell session coupling needed.
#
# Only two secrets reach Terraform, because Terraform needs them to build
# something and would hold them in state either way:
#   postgres_admin_password — Terraform creates the Postgres flexible server
#   langsmith_license_key   — the k8s_bootstrap module creates the
#                             langsmith-license K8s secret from it
#
# The LangSmith app secrets (admin password, API key salt, JWT secret, Fernet
# encryption keys) are NOT handled here. Terraform would persist their plaintext
# in state, so scripts/seed-keyvault-secrets.sh writes them directly to Key Vault
# after apply. Run `make seed-secrets` between `make apply` and `make k8s-secrets`.
#
# setup-env.sh is READ-ONLY against Key Vault — it never writes to KV directly.

SECRETS_FILE="secrets.auto.tfvars"

# ── Resolve the Key Vault name ────────────────────────────────────────────────
# _derive_kv_name mirrors local.keyvault_name, including the name_prefix suffix,
# an explicit keyvault_name, and the unique_resource_names hash. Deriving it here
# by hand is how this script and three others drifted apart.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

_name_prefix=$(_parse_tfvar name_prefix || _parse_tfvar identifier || true)
_kv_name=$(_derive_kv_name)

# LANGSMITH_PG_PASSWORD is not listed — it is generated when left blank.
_REQUIRED_VARS="LANGSMITH_LICENSE_KEY LANGSMITH_ADMIN_EMAIL"

# ── Prompt helper (skips if env var already set) ──────────────────────────────
# Prompt text goes to stderr: stdout is the return channel for the value, so
# anything printed there is swallowed by the caller's command substitution.
_prompt() {
  local env_var="$1"
  local prompt_text="$2"
  local mode="${3:-}"   # "" = required secret | optional = may be left blank | visible = echo input
  local val="${!env_var:-}"
  if [[ -z "$val" && -t 0 ]]; then
    printf "%s: " "$prompt_text" >&2
    if [[ "$mode" == "visible" ]]; then
      read -r val || val=""   # Ctrl-D / EOF — handled by the empty check below
    else
      read -rs val || val=""
      echo >&2                # -s also swallows the newline the user typed
    fi
  fi
  if [[ -z "$val" && "$mode" != "optional" ]]; then
    echo "ERROR: No value provided for $env_var." >&2
    return 1
  fi
  echo "$val"
}

# ── Non-interactive guard ─────────────────────────────────────────────────────
# A sandboxed shell (Cursor, CI, `make` under a pipe) has no tty, so prompting
# is impossible. Checked here at top level, and reported on stdout: _prompt
# cannot report anything itself because its stdout is captured by the caller,
# and a harness that shows only stdout would otherwise display nothing at all.
if [[ ! -t 0 ]]; then
  _missing=""
  for _v in $_REQUIRED_VARS; do
    [[ -n "${!_v:-}" ]] || _missing="$_missing $_v"
  done
  if [[ -n "$_missing" ]]; then
    echo "ERROR: stdin is not a tty, so setup-env.sh cannot prompt for secrets."
    echo "       Missing:$_missing"
    echo ""
    echo "       Run it from a real terminal, or pre-set the values:"
    for _v in $_missing; do
      echo "         export $_v='<value>'"
    done
    echo ""
    echo "       Then re-run: make setup-env"
    exit 1
  fi
fi

# ── Key Vault reachability (probed once, not per secret) ──────────────────────
# Bounded by timeout(1) when available so a sandbox with blocked egress fails
# fast instead of stalling on a TCP timeout. timeout is not in the macOS base
# install, and gtimeout is the Homebrew coreutils name; run bare if neither.
_timeout_bin=""
for _t in timeout gtimeout; do
  if command -v "$_t" >/dev/null 2>&1; then _timeout_bin="$_t"; break; fi
done
_az() {
  if [[ -n "$_timeout_bin" ]]; then
    "$_timeout_bin" 30 az "$@"
  else
    az "$@"
  fi
}

# Probed at top level (see below), never first from inside _kv_secret: that runs
# in a command-substitution subshell, so a result cached there would be lost and
# every secret would re-probe.
_kv_reachable=""   # "" until probed, then "yes" or "no"
_kv_probe() {
  if [[ -z "$_kv_reachable" ]]; then
    if _az keyvault show --name "$_kv_name" --output none 2>/dev/null; then
      _kv_reachable="yes"
      echo "  Key Vault $_kv_name is reachable — reading existing secrets." >&2
    else
      _kv_reachable="no"
      echo "  Key Vault $_kv_name not reachable (not created yet, not logged in," >&2
      echo "  or no network) — using local files." >&2
    fi
  fi
  [[ "$_kv_reachable" == "yes" ]]
}

# ── Stable secret: read from Key Vault or local fallback, generate if missing ──
# Priority: Key Vault (written by Terraform) → local fallback file → generate fresh
# Never writes to Key Vault directly — Terraform owns all KV writes.
_kv_secret() {
  local kv_secret_name="$1"
  local fallback_file="$2"
  local generator="$3"
  local val=""

  # 1. Read from Key Vault (available after terraform apply)
  if _kv_probe; then
    val=$(_az keyvault secret show \
      --vault-name "$_kv_name" \
      --name "$kv_secret_name" \
      --query value -o tsv 2>/dev/null) || val=""
  fi

  # 2. Fall back to local file (before first apply, or on a machine without KV access)
  if [[ -z "$val" && -f "$fallback_file" ]]; then
    val=$(cat "$fallback_file")
  fi

  # 3. Generate fresh — write to local file only; Terraform stores in Key Vault on apply
  if [[ -z "$val" ]]; then
    val=$(eval "$generator") || {
      echo "ERROR: Secret generator failed for $kv_secret_name." >&2
      echo "       Command: $generator" >&2
      echo "       Ensure required tools are installed (openssl, python3)." >&2
      return 1
    }
    if [[ -z "$val" ]]; then
      echo "ERROR: Secret generator for $kv_secret_name produced empty output." >&2
      return 1
    fi
    echo "$val" > "$fallback_file"
    chmod 600 "$fallback_file"
    echo "  Generated $kv_secret_name → $fallback_file (Terraform stores in Key Vault on apply)" >&2
  fi

  echo "$val"
}

# Azure Postgres Flexible Server requires 8–128 characters from 3 of 4 character
# classes, so the random body carries a fixed prefix that guarantees the mix.
_pg_generator='printf "Ls1!%s\n" "$(openssl rand -base64 32 | tr -dc "A-Za-z0-9" | cut -c1-24)"'

# ── Collect secrets ───────────────────────────────────────────────────────────
echo ""
echo "LangSmith — Terraform input bootstrap"
echo "  name_prefix : ${_name_prefix:-(empty)}"
echo "  key_vault   : $_kv_name"
echo ""
echo "  Passwords are hidden as you type. Press Enter on the PostgreSQL prompt"
echo "  to have one generated for you — this script prints where to view it."
echo ""

pg_password=$(_prompt "LANGSMITH_PG_PASSWORD" "PostgreSQL admin password (Enter = generate)" optional)
license_key=$(_prompt "LANGSMITH_LICENSE_KEY" "LangSmith license key      ")
admin_email=$(_prompt "LANGSMITH_ADMIN_EMAIL" "Initial org admin email    " visible)

echo ""
_kv_probe || true   # once, in the parent shell — result is reused by every _kv_secret call

# Generated Postgres password goes through _kv_secret so it stays stable across
# runs: Key Vault after the first apply, .pg_password before it.
_pg_resolved=false
if [[ -z "$pg_password" ]]; then
  echo ""
  echo "  No PostgreSQL password given — resolving one..."
  pg_password=$(_kv_secret "postgres-admin-password" ".pg_password" "$_pg_generator")
  _pg_resolved=true
fi

# ── Write secrets.auto.tfvars ─────────────────────────────────────────────────
cat > "$SECRETS_FILE" << EOF
# Auto-generated by setup-env.sh — DO NOT COMMIT
# Re-run ./setup-env.sh to refresh secrets from Key Vault.

postgres_admin_password = "$pg_password"
langsmith_license_key   = "$license_key"
langsmith_admin_email   = "$admin_email"
EOF

chmod 600 "$SECRETS_FILE"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Wrote $SECRETS_FILE (chmod 600)"
if [[ "$_pg_resolved" == "true" ]]; then
  echo ""
  echo "  The PostgreSQL admin password was set for you. View it with:"
  echo "    grep postgres_admin_password $SECRETS_FILE"
  echo "  After terraform apply it is also in Key Vault:"
  echo "    az keyvault secret show --vault-name $_kv_name \\"
  echo "      --name postgres-admin-password --query value -o tsv"
fi
echo ""
echo "Next (from terraform/azure/):"
echo "  make preflight     # verify az login, providers, RBAC"
echo "  make init          # terraform init"
echo "  make apply         # deploy AKS + Postgres + Redis + Blob + Key Vault"
echo "  make seed-secrets  # write LangSmith app secrets into Key Vault"
echo "  make kubeconfig    # fetch AKS credentials"
echo "  make k8s-secrets   # create langsmith-config-secret from Key Vault"
echo "  make init-values   # generate Helm values from Terraform outputs"
echo "  make deploy        # helm upgrade --install langsmith"
