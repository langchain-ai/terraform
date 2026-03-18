#!/usr/bin/env bash
# manage-ssm.sh — Manage LangSmith SSM parameters without re-running setup-env.sh
#
# Usage (from aws/):
#   ./infra/scripts/manage-ssm.sh list
#   ./infra/scripts/manage-ssm.sh get <key>
#   ./infra/scripts/manage-ssm.sh set <key> <value>
#   ./infra/scripts/manage-ssm.sh validate
#   ./infra/scripts/manage-ssm.sh diff
#   ./infra/scripts/manage-ssm.sh delete <key>
#
# Reads name_prefix, environment, and region from terraform.tfvars.
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$SCRIPT_DIR/.."

# ── Parse terraform.tfvars ──────────────────────────────────────────────────
_parse_tfvar() {
  grep -E "^\s*${1}\s*=" "$INFRA_DIR/terraform.tfvars" 2>/dev/null \
    | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '[:space:]'
}

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-dev}"
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-us-east-2}"

if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: Could not read name_prefix from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

SSM_PREFIX="/langsmith/${_name_prefix}-${_environment}"
NAMESPACE="${NAMESPACE:-langsmith}"

# ── Required and optional parameter names ───────────────────────────────────
REQUIRED_PARAMS=(
  "postgres-password"
  "redis-auth-token"
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
  "langsmith-license-key"
  "langsmith-admin-password"
)

OPTIONAL_PARAMS=(
  "agent-builder-encryption-key"
  "insights-encryption-key"
  "deployments-encryption-key"
)

# Stable secrets that should never be changed after first deploy
STABLE_PARAMS=(
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
)

# SSM key → K8s secret data key (parallel arrays for diff subcommand)
DIFF_SSM_KEYS=(
  "langsmith-license-key"
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
  "langsmith-admin-password"
  "agent-builder-encryption-key"
  "insights-encryption-key"
  "deployments-encryption-key"
)
DIFF_K8S_KEYS=(
  "langsmith_license_key"
  "api_key_salt"
  "jwt_secret"
  "initial_org_admin_password"
  "agent_builder_encryption_key"
  "insights_encryption_key"
  "deployments_encryption_key"
)

# ── Helpers ─────────────────────────────────────────────────────────────────
_bold()  { printf '\033[1m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }

_is_stable() {
  local key="$1"
  for s in "${STABLE_PARAMS[@]}"; do
    [[ "$s" == "$key" ]] && return 0
  done
  return 1
}

_ssm_path() { echo "${SSM_PREFIX}/${1}"; }

_get_param() {
  aws ssm get-parameter \
    --region "$_region" \
    --name "$(_ssm_path "$1")" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text 2>/dev/null
}

_param_exists() {
  aws ssm get-parameter \
    --region "$_region" \
    --name "$(_ssm_path "$1")" \
    --query 'Parameter.Name' \
    --output text &>/dev/null
}

# ── list ────────────────────────────────────────────────────────────────────
cmd_list() {
  echo "SSM parameters under: $SSM_PREFIX/"
  echo ""

  local params
  params=$(aws ssm get-parameters-by-path \
    --region "$_region" \
    --path "$SSM_PREFIX/" \
    --with-decryption \
    --query 'Parameters[].{Name:Name,Modified:LastModifiedDate,Type:Type}' \
    --output json 2>/dev/null) || params="[]"

  if [[ "$params" == "[]" || -z "$params" ]]; then
    echo "  (no parameters found)"
    return
  fi

  # Print as a formatted table
  printf "  %-42s  %-12s  %s\n" "PARAMETER" "TYPE" "LAST MODIFIED"
  printf "  %-42s  %-12s  %s\n" "---------" "----" "-------------"

  echo "$params" | python3 -c "
import json, sys
params = json.load(sys.stdin)
for p in sorted(params, key=lambda x: x['Name']):
    name = p['Name'].split('/')[-1]
    mod = p['Modified'][:19] if p.get('Modified') else 'unknown'
    print(f\"  {name:<42}  {'SecureString':<12}  {mod}\")
" 2>/dev/null || {
    # Fallback if python3 is unavailable
    echo "$params" | grep -o '"Name":"[^"]*"' | sed "s|\"Name\":\"${SSM_PREFIX}/||;s|\"||g" | while read -r name; do
      printf "  %s\n" "$name"
    done
  }
  echo ""
}

# ── get ─────────────────────────────────────────────────────────────────────
cmd_get() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: manage-ssm.sh get <key>" >&2
    echo "Keys: ${REQUIRED_PARAMS[*]} ${OPTIONAL_PARAMS[*]}" >&2
    exit 1
  fi

  local val
  val=$(_get_param "$key") || {
    _red "ERROR"; echo ": Parameter not found: $(_ssm_path "$key")"
    exit 1
  }
  echo "$val"
}

# ── set ─────────────────────────────────────────────────────────────────────
cmd_set() {
  local key="${1:-}"
  local val="${2:-}"
  if [[ -z "$key" || -z "$val" ]]; then
    echo "Usage: manage-ssm.sh set <key> <value>" >&2
    echo "Keys: ${REQUIRED_PARAMS[*]} ${OPTIONAL_PARAMS[*]}" >&2
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

  local path
  path="$(_ssm_path "$key")"

  aws ssm put-parameter \
    --region "$_region" \
    --name "$path" \
    --value "$val" \
    --type SecureString \
    --overwrite \
    --output none

  _green "OK"; echo ": Updated $path"

  # Remind about ESO sync
  echo ""
  echo "  ESO syncs every hour. To force an immediate sync:"
  echo "    kubectl annotate externalsecret langsmith-config -n $NAMESPACE force-sync=\$(date +%s) --overwrite"
}

# ── delete ──────────────────────────────────────────────────────────────────
cmd_delete() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: manage-ssm.sh delete <key>" >&2
    exit 1
  fi

  if _is_stable "$key"; then
    echo ""
    _red "DANGER"; echo ": $key is a stable secret. Deleting it will break the deployment."
    printf "  Type the full parameter name to confirm: "
    read -r confirm
    [[ "$confirm" == "$key" ]] || { echo "Aborted."; exit 0; }
  else
    printf "Delete $(_ssm_path "$key")? [y/N] "
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  aws ssm delete-parameter \
    --region "$_region" \
    --name "$(_ssm_path "$key")" 2>/dev/null && {
    _green "OK"; echo ": Deleted $(_ssm_path "$key")"
  } || {
    _red "ERROR"; echo ": Parameter not found or could not be deleted."
    exit 1
  }
}

# ── validate ────────────────────────────────────────────────────────────────
cmd_validate() {
  echo "Validating SSM parameters under: $SSM_PREFIX/"
  echo ""

  local missing=0
  local warnings=0

  printf "  %-42s  %s\n" "PARAMETER" "STATUS"
  printf "  %-42s  %s\n" "---------" "------"

  for key in "${REQUIRED_PARAMS[@]}"; do
    if _param_exists "$key"; then
      local val
      val=$(_get_param "$key")
      if [[ -z "$val" ]]; then
        printf "  %-42s  %s\n" "$key" "$(_yellow "EMPTY")"
        ((warnings++))
      else
        # Extra validation for admin password
        if [[ "$key" == "langsmith-admin-password" ]]; then
          if ! printf '%s' "$val" | grep -qE '[]!#$%()+,./:?@^_{~}[\-]'; then
            printf "  %-42s  %s\n" "$key" "$(_red "INVALID — missing required symbol")"
            ((warnings++))
            continue
          fi
        fi
        printf "  %-42s  %s\n" "$key" "$(_green "OK")"
      fi
    else
      printf "  %-42s  %s\n" "$key" "$(_red "MISSING")"
      ((missing++))
    fi
  done

  echo ""
  echo "  Optional:"
  for key in "${OPTIONAL_PARAMS[@]}"; do
    if _param_exists "$key"; then
      printf "  %-42s  %s\n" "$key" "$(_green "OK")"
    else
      printf "  %-42s  %s\n" "$key" "—"
    fi
  done

  echo ""
  if [[ $missing -gt 0 ]]; then
    _red "FAIL"; echo ": $missing required parameter(s) missing. ESO sync will fail."
    echo "  Run: source infra/setup-env.sh"
    exit 1
  elif [[ $warnings -gt 0 ]]; then
    _yellow "WARN"; echo ": $warnings parameter(s) need attention."
    exit 0
  else
    _green "PASS"; echo ": All required parameters present."
  fi
}

# ── diff ────────────────────────────────────────────────────────────────────
cmd_diff() {
  if ! command -v kubectl &>/dev/null; then
    echo "ERROR: kubectl not found. diff requires cluster access." >&2
    exit 1
  fi

  echo "Comparing SSM → K8s secret (langsmith-config in $NAMESPACE)..."
  echo ""

  # Get the K8s secret data keys
  local k8s_keys
  k8s_keys=$(kubectl get secret langsmith-config -n "$NAMESPACE" \
    -o jsonpath='{.data}' 2>/dev/null) || {
    _red "ERROR"; echo ": langsmith-config secret not found in namespace $NAMESPACE."
    echo "  Is ESO configured? Run: ./helm/scripts/deploy.sh"
    exit 1
  }

  printf "  %-35s  %-10s  %-10s  %s\n" "KEY" "SSM" "K8S" "MATCH"
  printf "  %-35s  %-10s  %-10s  %s\n" "---" "---" "---" "-----"

  local mismatches=0

  for i in "${!DIFF_SSM_KEYS[@]}"; do
    local ssm_key="${DIFF_SSM_KEYS[$i]}"
    local k8s_key="${DIFF_K8S_KEYS[$i]}"

    # Get SSM value
    local ssm_val
    ssm_val=$(_get_param "$ssm_key" 2>/dev/null) || ssm_val=""

    # Get K8s secret value (base64 decoded)
    local k8s_val
    k8s_val=$(kubectl get secret langsmith-config -n "$NAMESPACE" \
      -o jsonpath="{.data.${k8s_key}}" 2>/dev/null | base64 -d 2>/dev/null) || k8s_val=""

    local ssm_status="—"
    local k8s_status="—"
    local match_status=""

    [[ -n "$ssm_val" ]] && ssm_status="present"
    [[ -n "$k8s_val" ]] && k8s_status="present"

    if [[ -z "$ssm_val" && -z "$k8s_val" ]]; then
      match_status="—"
    elif [[ "$ssm_val" == "$k8s_val" ]]; then
      match_status=$(_green "✓")
    else
      match_status=$(_red "✗ MISMATCH")
      ((mismatches++))
    fi

    printf "  %-35s  %-10s  %-10s  %s\n" "$ssm_key" "$ssm_status" "$k8s_status" "$match_status"
  done

  echo ""
  if [[ $mismatches -gt 0 ]]; then
    _yellow "WARN"; echo ": $mismatches key(s) out of sync. Force ESO refresh:"
    echo "  kubectl annotate externalsecret langsmith-config -n $NAMESPACE force-sync=\$(date +%s) --overwrite"
  else
    _green "OK"; echo ": SSM and K8s secret are in sync."
  fi
}

# ── Interactive menu ─────────────────────────────────────────────────────────
ALL_PARAMS=("${REQUIRED_PARAMS[@]}" "${OPTIONAL_PARAMS[@]}")

_pick_key() {
  local prompt="${1:-Pick a secret}"
  echo ""
  echo "  $prompt:"
  echo ""
  echo "  Required:"
  local i=1
  for key in "${REQUIRED_PARAMS[@]}"; do
    local label="$key"
    _is_stable "$key" && label="$key $(_yellow "[stable — do not change]")"
    printf "    %2d) %s\n" "$i" "$label"
    ((i++))
  done
  echo ""
  echo "  Optional:"
  for key in "${OPTIONAL_PARAMS[@]}"; do
    printf "    %2d) %s\n" "$i" "$key"
    ((i++))
  done
  echo ""
  printf "  Enter number: "
  read -r choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ALL_PARAMS[@]} )); then
    _red "ERROR"; echo ": Invalid selection."
    exit 1
  fi
  PICKED_KEY="${ALL_PARAMS[$((choice - 1))]}"
}

_interactive_get() {
  _pick_key "Which secret to read"
  echo ""
  echo "  $(_ssm_path "$PICKED_KEY"):"
  echo ""
  cmd_get "$PICKED_KEY"
}

_interactive_set() {
  _pick_key "Which secret to update"
  echo ""

  # Show current value (masked) so they know what they're replacing
  if _param_exists "$PICKED_KEY"; then
    local current
    current=$(_get_param "$PICKED_KEY")
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
  echo "  LangSmith SSM Manager"
  echo "  Prefix: $(_bold "$SSM_PREFIX/")"
  echo ""
  echo "    1) list       — Show all parameters"
  echo "    2) get        — Read a secret"
  echo "    3) set        — Update a secret"
  echo "    4) validate   — Check all required params"
  echo "    5) diff       — Compare SSM vs K8s secret"
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

# ── Main ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
manage-ssm.sh — Manage LangSmith SSM parameters

Usage:
  manage-ssm.sh                      Interactive mode (menus)
  manage-ssm.sh <command> [args]     Non-interactive (scripting)

  Prefix: $SSM_PREFIX/

Commands:
  list                 List all parameters with last-modified dates
  get <key>            Read and decrypt a single parameter
  set <key> <value>    Update a parameter (validates format constraints)
  delete <key>         Delete a parameter (with confirmation)
  validate             Check all required parameters exist and are valid
  diff                 Compare SSM values vs K8s secret (requires kubectl)

Examples:
  ./infra/scripts/manage-ssm.sh                                    # interactive
  ./infra/scripts/manage-ssm.sh validate                           # scripting
  ./infra/scripts/manage-ssm.sh set langsmith-admin-password 'P@ss!'
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
