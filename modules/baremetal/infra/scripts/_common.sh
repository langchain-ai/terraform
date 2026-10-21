#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# _common.sh — Shared helpers for bare-metal LangSmith scripts.
#
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# Provides:
#   _parse_tfvar <key>        — Read a value from terraform.tfvars
#   _tfvar_is_true <key>      — Return 0 if tfvar == true
#   Color helpers: _bold, _green, _red, _yellow, _cyan, _dim
#   Status helpers: pass, warn, fail, skip, info, header, action
#   Secret store:   _secret_get, _secret_put, _secret_gen_b64, _secret_gen_fernet,
#                   _secrets_file_check
#
# Sourced, not executed: it sets no shell options of its own.

# ── Resolve INFRA_DIR ────────────────────────────────────────────────────────
# Assumes this script lives in infra/scripts/. Consumers that live elsewhere
# should override INFRA_DIR after sourcing.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${INFRA_DIR:-$_COMMON_DIR/..}"

# ── terraform.tfvars parser ──────────────────────────────────────────────────
# Values are cut at the closing quote (quoted strings, which may contain a
# literal #) or at an inline # (bare booleans and numbers). Keep this function
# identical to the copies in helm/scripts/*.sh.
_parse_tfvar() {
  awk -v key="$1" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "")
      if (substr($0, 1, 1) == "\"") { sub(/^"/, ""); sub(/".*$/, "") }
      else { sub(/#.*$/, ""); gsub(/[[:space:]]+$/, "") }
      print; exit
    }
  ' "$INFRA_DIR/terraform.tfvars" 2>/dev/null || true
}

# Parse a boolean tfvar (unquoted true/false). Returns 0 for true, 1 for false.
_tfvar_is_true() {
  [[ "$(_parse_tfvar "$1")" == "true" ]]
}

# ── Color helpers ────────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }
_cyan()  { printf '\033[0;36m%s\033[0m' "$*"; }
_dim()   { printf '\033[0;90m%s\033[0m' "$*"; }

# ── Status line helpers ──────────────────────────────────────────────────────
_RESET='\033[0m'
pass()  { printf "  \033[32m✔${_RESET}  %s\n" "$1"; }
warn()  { printf "  \033[1;33m⚠${_RESET}  %s\n" "$1"; }
fail()  { printf "  \033[31m✘${_RESET}  %s\n" "$1"; }
skip()  { printf "  \033[0;90m○${_RESET}  %s\n" "$1"; }
info()  { printf "  \033[0;36mℹ${_RESET}  %s\n" "$1"; }
header(){ printf "\n\033[1m── %s ──${_RESET}\n" "$1"; }
action(){ printf "  \033[1;33m→${_RESET}  %s\n" "$1"; }

# ── App-secret store (file backend) ──────────────────────────────────────────
# Bare metal has no cloud secret manager, so app secrets (license key,
# api_key_salt, jwt_secret, Fernet keys, ...) live in one local file:
#
#   infra/.secrets.env     KEY=value per line, mode 600, gitignored
#
# The file is the source of truth. deploy.sh copies it into the
# langsmith-config Kubernetes Secret, so a cluster rebuild doesn't lose the
# keys. Back the file up; rotating api_key_salt or jwt_secret invalidates
# every API key and session.
#
# The file is parsed, never sourced or eval'd, and values are never printed.
# To move to a real secret manager (OpenBao/Vault) later, replace only
# _secret_get and _secret_put; callers stay the same.
SECRETS_FILE="${SECRETS_FILE:-$INFRA_DIR/.secrets.env}"

# Print the value of KEY, or nothing if it isn't set. Splits on the first '='
# only, so base64 padding in values survives.
_secret_get() {
  local key="$1"
  [[ -f "$SECRETS_FILE" ]] || return 0
  awk -v key="$key" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$SECRETS_FILE"
}

# Store VALUE under KEY, replacing any existing line. The new file is written
# beside the old one with mode 600, then moved into place, so a failure
# halfway never leaves a truncated store.
_secret_put() {
  local key="$1" value="$2" tmp
  if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    fail "_secret_put: invalid key name '$key' (use UPPER_SNAKE_CASE)"
    return 1
  fi
  if [[ -z "$value" || "$value" == *$'\n'* ]]; then
    fail "_secret_put: $key is empty or contains a newline — not stored"
    return 1
  fi
  tmp="$(umask 077 && mktemp "$SECRETS_FILE.XXXXXX")" || return 1
  if [[ -f "$SECRETS_FILE" ]]; then
    awk -v key="$key" 'index($0, key "=") != 1' "$SECRETS_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SECRETS_FILE"
}

# 32 random bytes, standard base64 (api_key_salt, jwt_secret).
_secret_gen_b64() {
  openssl rand -base64 32 | tr -d '\n'
}

# 32 random bytes, URL-safe base64 — the format Fernet keys require
# (fleet — stored as AGENT_BUILDER_ENCRYPTION_KEY, the chart's key name — insights, polly).
_secret_gen_fernet() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n'
}

# Warn if the store is readable by anyone but the owner.
_secrets_file_check() {
  [[ -f "$SECRETS_FILE" ]] || return 0
  local mode
  mode="$(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null || stat -c '%a' "$SECRETS_FILE" 2>/dev/null)"
  if [[ "$mode" != "600" ]]; then
    warn "$SECRETS_FILE has mode $mode — run: chmod 600 $SECRETS_FILE"
  fi
}

# ── Validators (keep identical to modules/azure _common.sh and modules/gcp setup-env.sh) ──
# prefix). An offline key is a three-part JWT whose first part is a base64url
# JSON header carrying the alg member RFC 7515 requires. Anything else is parsed
# as a JWT and fails inside the pod with an error that names neither the prompt
# nor licensing (#250), so the shape is checked here, where the operator still
# has the right value in front of them. Shape only: no signature check, and the
# body-length floor on lcl_ keys is a typo guard rather than a specification.
_b64url_decode() {
  local s="${1//-/+}"
  s="${s//_//}"
  case $(( ${#s} % 4 )) in
    1) return 1 ;;
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}

_validate_license_key() {
  local key="$1" err="" header="" header_json="" dots=""
  # A JWS header is a JSON object and must carry alg (RFC 7515 §4.1.1). Kept in
  # a variable: bash 3.2 treats a quoted regex literally, and this one has quotes.
  local header_re='^\{.*"alg"[[:space:]]*:.*\}$'

  case "$key" in
    "")                 err="cannot be empty" ;;
    *[[:space:]]*)      err="contains whitespace; paste the key on its own" ;;
    http://*|https://*) err="looks like a URL, not a license key. Paste the key itself, not the link it was shared in" ;;
    lcl_*)
      if [[ ! "${key#lcl_}" =~ ^[A-Za-z0-9_-]{16,}$ ]]; then
        err="is too short, or has characters outside A-Z a-z 0-9 - _, for an lcl_ key"
      fi ;;
    *)
      dots="${key//[^.]/}"
      if [[ ${#dots} -ne 2 ]]; then
        err="is not a LangSmith license key: expected lcl_<key>, or an offline token with exactly three dot-separated parts"
      else
        header="${key%%.*}"
        if [[ ! "$header" =~ ^[A-Za-z0-9_-]+$ ]] || ! header_json=$(_b64url_decode "$header") \
           || [[ ! "$header_json" =~ $header_re ]]; then
          err="has three parts, but its first part is not a base64url JSON header with an alg member, so it is not an offline license token"
        fi
      fi ;;
  esac

  if [[ -n "$err" ]]; then
    echo "License key ${err}."
    return 1
  fi
}

# Same rule as the chart (and modules/gcp setup-env.sh): >= 12 bytes, a
# lowercase letter, an uppercase letter, and a symbol from the chart's set.
_validate_admin_password() {
  local _pw="$1" _len
  # Count bytes, because the chart's rule is Go's len(), which counts bytes.
  # ${#_pw} counts characters in a UTF-8 locale and bytes in the C locale, so it
  # gives the same password two different verdicts on two machines: "Pässwörd12!"
  # is 13 bytes and the chart takes it, but ${#_pw} reads 11 under
  # LC_ALL=en_US.UTF-8 and rejects it. The two agree on ASCII.
  _len=$(printf '%s' "$_pw" | wc -c | tr -d '[:space:]')
  if (( _len < 12 )); then
    echo "must be at least 12 bytes long (a non-ASCII character counts as more than one)"
    return 1
  fi
  # The bracket expression lists the symbols the chart accepts: ] first and -
  # last so both are literal. Writing the class as [...\-] instead would add a
  # backslash to the set, and a password whose only symbol is a backslash then
  # passes here and fails the chart.
  if ! printf '%s' "$_pw" | grep -q '[]!#$%()+,./:?@[^_{~}-]'; then
    echo 'must contain at least one symbol from !#$%()+,-./:?@[]^_{~}'
    return 1
  fi
  if ! printf '%s' "$_pw" | grep -q '[a-z]'; then
    echo "must contain at least one lowercase letter"
    return 1
  fi
  if ! printf '%s' "$_pw" | grep -q '[A-Z]'; then
    echo "must contain at least one uppercase letter"
    return 1
  fi
  return 0
}

# Shape check only: something@something.tld, no whitespace.
_validate_email() {
  if [[ ! "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "must look like name@example.com"
    return 1
  fi
}
