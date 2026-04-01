#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# manage-keyvault.sh — Manage LangSmith Key Vault secrets without re-running setup-env.sh
#
# Usage (from azure/):
#   ./infra/scripts/manage-keyvault.sh list
#   ./infra/scripts/manage-keyvault.sh get <key>
#   ./infra/scripts/manage-keyvault.sh set <key> <value>
#   ./infra/scripts/manage-keyvault.sh validate
#   ./infra/scripts/manage-keyvault.sh diff
#   ./infra/scripts/manage-keyvault.sh delete <key>
#
# Reads identifier and location from terraform.tfvars to derive the Key Vault name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

# ── Resolve Key Vault name ───────────────────────────────────────────────────
# Priority: terraform output → derived from identifier in terraform.tfvars
if KV_NAME=$(cd "$INFRA_DIR" && terraform output -raw keyvault_name 2>/dev/null) && [[ -n "$KV_NAME" ]]; then
  : # got it from terraform output
else
  _identifier=$(_parse_tfvar "identifier") || _identifier=""
  KV_NAME="langsmith-kv${_identifier}"
fi

NAMESPACE="${NAMESPACE:-langsmith}"

# ── Required and optional secret names ──────────────────────────────────────
REQUIRED_SECRETS=(
  "langsmith-license-key"
  "langsmith-admin-password"
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
)

OPTIONAL_SECRETS=(
  "langsmith-deployments-encryption-key"
  "langsmith-agent-builder-encryption-key"
  "langsmith-insights-encryption-key"
  "langsmith-polly-encryption-key"
)

# Stable secrets — changing them breaks active sessions/API keys
STABLE_SECRETS=(
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
)

# KV secret name → K8s secret data key (for diff subcommand)
DIFF_KV_KEYS=(
  "langsmith-license-key"
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
  "langsmith-admin-password"
  "langsmith-deployments-encryption-key"
  "langsmith-agent-builder-encryption-key"
  "langsmith-insights-encryption-key"
  "langsmith-polly-encryption-key"
)
DIFF_K8S_KEYS=(
  "langsmith_license_key"
  "api_key_salt"
  "jwt_secret"
  "initial_org_admin_password"
  "deployments_encryption_key"
  "agent_builder_encryption_key"
  "insights_encryption_key"
  "polly_encryption_key"
)

# ── Helpers ──────────────────────────────────────────────────────────────────
_is_stable() {
  local key="$1"
  for s in "${STABLE_SECRETS[@]}"; do
    [[ "$s" == "$key" ]] && return 0
  done
  return 1
}

_get_secret() {
  local _out
  _out=$(az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$1" \
    --query value \
    --output tsv 2>&1) && { echo "$_out"; return 0; }
  if echo "$_out" | grep -qi "SecretNotFound\|does not exist\|404"; then
    return 1
  fi
  echo "ERROR: Key Vault query failed for $1: $_out" >&2
  return 1
}

_secret_exists() {
  az keyvault secret show \
    --vault-name "$KV_NAME" \
    --name "$1" \
    --query name \
    --output tsv &>/dev/null
}

# ── list ─────────────────────────────────────────────────────────────────────
cmd_list() {
  echo "Key Vault secrets in: $KV_NAME"
  echo ""

  local secrets
  secrets=$(az keyvault secret list \
    --vault-name "$KV_NAME" \
    --query '[].{Name:name, Updated:attributes.updated}' \
    --output json 2>/dev/null) || secrets="[]"

  if [[ "$secrets" == "[]" || -z "$secrets" ]]; then
    echo "  (no secrets found)"
    return
  fi

  printf "  %-48s  %s\n" "SECRET" "LAST UPDATED"
  printf "  %-48s  %s\n" "------" "------------"

  echo "$secrets" | python3 -c "
import json, sys
secrets = json.load(sys.stdin)
for s in sorted(secrets, key=lambda x: x['Name']):
    name = s['Name']
    updated = (s.get('Updated') or 'unknown')[:19]
    print(f'  {name:<48}  {updated}')
" 2>/dev/null || {
    echo "$secrets" | grep -o '"Name":"[^"]*"' | sed 's/"Name":"//;s/"//' | while read -r name; do
      printf "  %s\n" "$name"
    done
  }
  echo ""
}

# ── get ──────────────────────────────────────────────────────────────────────
cmd_get() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: manage-keyvault.sh get <key>" >&2
    echo "Keys: ${REQUIRED_SECRETS[*]} ${OPTIONAL_SECRETS[*]}" >&2
    exit 1
  fi

  local val
  val=$(_get_secret "$key") || {
    _red "ERROR"; echo ": Secret not found: $key (vault: $KV_NAME)"
    exit 1
  }
  echo "$val"
}

# ── set ──────────────────────────────────────────────────────────────────────
cmd_set() {
  local key="${1:-}"
  local val="${2:-}"
  if [[ -z "$key" || -z "$val" ]]; then
    echo "Usage: manage-keyvault.sh set <key> <value>" >&2
    echo "Keys: ${REQUIRED_SECRETS[*]} ${OPTIONAL_SECRETS[*]}" >&2
    exit 1
  fi

  # Warn on stable secrets
  if _is_stable "$key"; then
    echo ""
    _yellow "WARNING"; echo ": $key is a stable secret."
    if [[ "$key" == "langsmith-api-key-salt" ]]; then
      echo "  Changing this invalidates ALL existing API keys."
    elif [[ "$key" == "langsmith-jwt-secret" ]]; then
      echo "  Changing this invalidates ALL active user sessions."
    fi
    printf "  Are you sure? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  # Validate admin password format
  if [[ "$key" == "langsmith-admin-password" ]]; then
    if ! printf '%s' "$val" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
      _red "ERROR"; echo ": Admin password must contain a symbol: !#\$%()+,-./:?@[\\]^_{~}"
      echo "  The Helm chart will reject a password without one."
      exit 1
    fi
  fi

  az keyvault secret set \
    --vault-name "$KV_NAME" \
    --name "$key" \
    --value "$val" \
    --output none

  _green "OK"; echo ": Updated $key in $KV_NAME"

  echo ""
  echo "  To sync to K8s secret:"
  echo "    make k8s-secrets"
}

# ── delete ───────────────────────────────────────────────────────────────────
cmd_delete() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: manage-keyvault.sh delete <key>" >&2
    exit 1
  fi

  if _is_stable "$key"; then
    echo ""
    _red "DANGER"; echo ": $key is a stable secret. Deleting it will break the deployment."
    printf "  Type the full secret name to confirm: "
    read -r confirm
    [[ "$confirm" == "$key" ]] || { echo "Aborted."; exit 0; }
  else
    printf "Delete $key from $KV_NAME? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  az keyvault secret delete \
    --vault-name "$KV_NAME" \
    --name "$key" \
    --output none 2>/dev/null && {
    _green "OK"; echo ": Deleted $key (soft-deleted — recoverable for 90 days)"
  } || {
    _red "ERROR"; echo ": Secret not found or could not be deleted."
    exit 1
  }
}

# ── validate ─────────────────────────────────────────────────────────────────
cmd_validate() {
  echo "Validating Key Vault secrets in: $KV_NAME"
  echo ""

  # Verify vault is accessible
  if ! az keyvault show --name "$KV_NAME" --query name --output tsv &>/dev/null; then
    _red "ERROR"; echo ": Key Vault '$KV_NAME' not found or not accessible."
    echo "  Run: make apply  to provision infrastructure"
    exit 1
  fi

  local missing=0
  local warnings=0

  printf "  %-48s  %s\n" "SECRET" "STATUS"
  printf "  %-48s  %s\n" "------" "------"

  for key in "${REQUIRED_SECRETS[@]}"; do
    if _secret_exists "$key"; then
      local val
      val=$(_get_secret "$key")
      if [[ -z "$val" ]]; then
        printf "  %-48s  %s\n" "$key" "$(_yellow "EMPTY")"
        warnings=$((warnings + 1))
      else
        if [[ "$key" == "langsmith-admin-password" ]]; then
          if ! printf '%s' "$val" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
            printf "  %-48s  %s\n" "$key" "$(_red "INVALID — missing required symbol")"
            warnings=$((warnings + 1))
            continue
          fi
        fi
        printf "  %-48s  %s\n" "$key" "$(_green "OK")"
      fi
    else
      printf "  %-48s  %s\n" "$key" "$(_red "MISSING")"
      missing=$((missing + 1))
    fi
  done

  echo ""
  echo "  Optional:"
  for key in "${OPTIONAL_SECRETS[@]}"; do
    if _secret_exists "$key"; then
      printf "  %-48s  %s\n" "$key" "$(_green "OK")"
    else
      printf "  %-48s  %s\n" "$key" "—"
    fi
  done

  echo ""
  if [[ $missing -gt 0 ]]; then
    _red "FAIL"; echo ": $missing required secret(s) missing."
    echo "  Run: source infra/scripts/setup-env.sh"
    exit 1
  elif [[ $warnings -gt 0 ]]; then
    _yellow "WARN"; echo ": $warnings secret(s) need attention."
    exit 0
  else
    _green "PASS"; echo ": All required secrets present in Key Vault."
  fi
}

# ── diff ─────────────────────────────────────────────────────────────────────
cmd_diff() {
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found. diff requires cluster access." >&2
    exit 1
  fi

  echo "Comparing Key Vault → K8s secret (langsmith-config-secret in $NAMESPACE)..."
  echo ""

  if ! kubectl get secret langsmith-config-secret -n "$NAMESPACE" &>/dev/null; then
    _red "ERROR"; echo ": langsmith-config-secret not found in namespace $NAMESPACE."
    echo "  Run: make k8s-secrets"
    exit 1
  fi

  printf "  %-44s  %-10s  %-10s  %s\n" "KEY" "KV" "K8S" "MATCH"
  printf "  %-44s  %-10s  %-10s  %s\n" "---" "--" "---" "-----"

  local mismatches=0

  for i in "${!DIFF_KV_KEYS[@]}"; do
    local kv_key="${DIFF_KV_KEYS[$i]}"
    local k8s_key="${DIFF_K8S_KEYS[$i]}"

    local kv_val
    kv_val=$(_get_secret "$kv_key" 2>/dev/null) || kv_val=""

    local k8s_val
    k8s_val=$(kubectl get secret langsmith-config-secret -n "$NAMESPACE" \
      -o jsonpath="{.data.${k8s_key}}" 2>/dev/null | base64 -d 2>/dev/null) || k8s_val=""

    local kv_status="—"
    local k8s_status="—"
    local match_status=""

    [[ -n "$kv_val" ]] && kv_status="present"
    [[ -n "$k8s_val" ]] && k8s_status="present"

    if [[ -z "$kv_val" && -z "$k8s_val" ]]; then
      match_status="—"
    elif [[ "$kv_val" == "$k8s_val" ]]; then
      match_status=$(_green "✓")
    else
      match_status=$(_red "✗ MISMATCH")
      mismatches=$((mismatches + 1))
    fi

    printf "  %-44s  %-10s  %-10s  %s\n" "$kv_key" "$kv_status" "$k8s_status" "$match_status"
  done

  echo ""
  if [[ $mismatches -gt 0 ]]; then
    _yellow "WARN"; echo ": $mismatches key(s) out of sync. Re-sync:"
    echo "  make k8s-secrets"
  else
    _green "OK"; echo ": Key Vault and K8s secret are in sync."
  fi
}

# ── Interactive menu ──────────────────────────────────────────────────────────
ALL_SECRETS=("${REQUIRED_SECRETS[@]}" "${OPTIONAL_SECRETS[@]}")

_pick_key() {
  local prompt="${1:-Pick a secret}"
  echo ""
  echo "  $prompt:"
  echo ""
  echo "  Required:"
  local i=1
  for key in "${REQUIRED_SECRETS[@]}"; do
    local label="$key"
    _is_stable "$key" && label="$key $(_yellow "[stable — do not change]")"
    printf "    %2d) %s\n" "$i" "$label"
    ((i++))
  done
  echo ""
  echo "  Optional:"
  for key in "${OPTIONAL_SECRETS[@]}"; do
    printf "    %2d) %s\n" "$i" "$key"
    ((i++))
  done
  echo ""
  printf "  Enter number: "
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ALL_SECRETS[@]} )); then
    _red "ERROR"; echo ": Invalid selection."
    exit 1
  fi
  PICKED_KEY="${ALL_SECRETS[$((choice - 1))]}"
}

_interactive_get() {
  _pick_key "Which secret to read"
  echo ""
  echo "  $PICKED_KEY (vault: $KV_NAME):"
  echo ""
  cmd_get "$PICKED_KEY"
}

_interactive_set() {
  _pick_key "Which secret to update"
  echo ""

  if _secret_exists "$PICKED_KEY"; then
    local current
    current=$(_get_secret "$PICKED_KEY")
    local masked="${current:0:4}$(printf '%*s' $(( ${#current} - 4 )) '' | tr ' ' '*')"
    [[ ${#current} -le 4 ]] && masked="****"
    echo "  Current value: $masked"
  else
    echo "  Current value: $(_yellow "(not set)")"
  fi

  echo ""
  if [[ "$PICKED_KEY" == "langsmith-admin-password" ]]; then
    echo "  Must contain a symbol: !#\$%()+,-./:?@[\\]^_{~}"
  fi
  printf "  New value: "
  read -rs new_val
  echo ""

  if [[ -z "$new_val" ]]; then
    echo "Aborted — no value entered."
    exit 0
  fi

  cmd_set "$PICKED_KEY" "$new_val"
}

_interactive_delete() {
  _pick_key "Which secret to delete"
  echo ""
  cmd_delete "$PICKED_KEY"
}

cmd_interactive() {
  echo ""
  echo "  LangSmith Key Vault Manager"
  echo "  Vault: $(_bold "$KV_NAME")"
  echo ""
  echo "    1) list       — Show all secrets"
  echo "    2) get        — Read a secret"
  echo "    3) set        — Update a secret"
  echo "    4) validate   — Check all required secrets"
  echo "    5) diff       — Compare Key Vault vs K8s secret"
  echo "    6) delete     — Remove a secret"
  echo ""
  printf "  What do you want to do? [1-6]: "
  read -r action

  case "$action" in
    1|list)     echo ""; cmd_list ;;
    2|get)      _interactive_get ;;
    3|set)      _interactive_set ;;
    4|validate) echo ""; cmd_validate ;;
    5|diff)     echo ""; cmd_diff ;;
    6|delete)   _interactive_delete ;;
    *)
      _red "ERROR"; echo ": Invalid selection."
      exit 1
      ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
manage-keyvault.sh — Manage LangSmith Key Vault secrets

Usage:
  manage-keyvault.sh                      Interactive mode (menus)
  manage-keyvault.sh <command> [args]     Non-interactive (scripting)

  Vault: $KV_NAME

Commands:
  list                 List all secrets with last-updated timestamps
  get <key>            Read and print a single secret value
  set <key> <value>    Update a secret (validates format constraints)
  delete <key>         Soft-delete a secret (with confirmation)
  validate             Check all required secrets exist and are valid
  diff                 Compare Key Vault vs K8s secret (requires kubectl)

Examples:
  ./infra/scripts/manage-keyvault.sh                                      # interactive
  ./infra/scripts/manage-keyvault.sh validate                             # scripting
  ./infra/scripts/manage-keyvault.sh set langsmith-admin-password 'P@ss!'
  ./infra/scripts/manage-keyvault.sh diff
EOF
}

case "${1:-}" in
  list)     cmd_list ;;
  get)      cmd_get "${2:-}" ;;
  set)      cmd_set "${2:-}" "${3:-}" ;;
  delete)   cmd_delete "${2:-}" ;;
  validate) cmd_validate ;;
  diff)     cmd_diff ;;
  -h|--help|help) usage ;;
  "")       cmd_interactive ;;
  *)
    usage >&2
    exit 1
    ;;
esac
