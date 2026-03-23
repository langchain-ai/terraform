#!/usr/bin/env bash
# manage-secrets.sh — Manage LangSmith Secret Manager secrets
#
# Usage (from gcp/):
#   ./infra/scripts/manage-secrets.sh              Interactive mode (menus)
#   ./infra/scripts/manage-secrets.sh list         List all secrets with status
#   ./infra/scripts/manage-secrets.sh get <key>    Read a secret value
#   ./infra/scripts/manage-secrets.sh set <key> [value]   Create or update a secret
#   ./infra/scripts/manage-secrets.sh validate     Check all required secrets exist
#   ./infra/scripts/manage-secrets.sh diff         Compare Secret Manager vs TF_VAR_* env
#   ./infra/scripts/manage-secrets.sh delete <key> Delete a secret (with confirmation)
#
# Reads project_id, name_prefix, and environment from terraform.tfvars.
# All secrets are stored as: {project}/secrets/langsmith-{prefix}-{env}-{key}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

_project_id=$(_parse_tfvar "project_id") || _project_id=""
_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment="dev"

if [[ -z "$_project_id" || -z "$_name_prefix" ]]; then
  echo "ERROR: Could not read project_id / name_prefix from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

SM_PREFIX="langsmith-${_name_prefix}-${_environment}"
PROJECT="$_project_id"
NAMESPACE="${NAMESPACE:-langsmith}"

# ── Key sets ──────────────────────────────────────────────────────────────────

REQUIRED_KEYS=(
  postgres-password
  langsmith-license-key
)

OPTIONAL_KEYS=(
  deployments-encryption-key
  agent-builder-encryption-key
  insights-encryption-key
  polly-encryption-key
)

# Encryption keys that must NEVER change after first deploy.
# Changing these makes existing encrypted data unreadable.
STABLE_KEYS=(
  deployments-encryption-key
  agent-builder-encryption-key
  insights-encryption-key
  polly-encryption-key
)

# SM key → TF_VAR name (for diff subcommand)
DIFF_SM_KEYS=(
  postgres-password
  langsmith-license-key
  deployments-encryption-key
  agent-builder-encryption-key
  insights-encryption-key
  polly-encryption-key
)
DIFF_TF_VARS=(
  TF_VAR_postgres_password
  TF_VAR_langsmith_license_key
  TF_VAR_langsmith_deployments_encryption_key
  TF_VAR_langsmith_agent_builder_encryption_key
  TF_VAR_langsmith_insights_encryption_key
  TF_VAR_langsmith_polly_encryption_key
)

ALL_KEYS=("${REQUIRED_KEYS[@]}" "${OPTIONAL_KEYS[@]}")

# ── Low-level SM helpers ──────────────────────────────────────────────────────

_secret_id() { echo "${SM_PREFIX}-${1}"; }

_sm_exists() {
  gcloud secrets describe "$(_secret_id "$1")" \
    --project="$PROJECT" --quiet &>/dev/null
}

_sm_get() {
  gcloud secrets versions access latest \
    --secret="$(_secret_id "$1")" \
    --project="$PROJECT" \
    --quiet 2>/dev/null || true
}

_sm_last_modified() {
  gcloud secrets versions list "$(_secret_id "$1")" \
    --project="$PROJECT" \
    --filter="state=ENABLED" \
    --sort-by="~createTime" \
    --format="value(createTime)" \
    --limit=1 2>/dev/null | head -1 || echo "—"
}

_sm_put() {
  local key="$1" val="$2"
  local sid
  sid="$(_secret_id "$key")"

  if ! gcloud secrets describe "$sid" --project="$PROJECT" --quiet &>/dev/null; then
    gcloud secrets create "$sid" \
      --project="$PROJECT" \
      --replication-policy="automatic" \
      --labels="managed-by=manage-secrets,langsmith-env=${_environment}" \
      --quiet
  fi

  printf '%s' "$val" | gcloud secrets versions add "$sid" \
    --project="$PROJECT" \
    --data-file=- \
    --quiet
}

_is_stable() {
  local key="$1"
  for s in "${STABLE_KEYS[@]}"; do
    [[ "$s" == "$key" ]] && return 0
  done
  return 1
}

_is_optional() {
  local key="$1"
  for s in "${OPTIONAL_KEYS[@]}"; do
    [[ "$s" == "$key" ]] && return 0
  done
  return 1
}

# ── list ──────────────────────────────────────────────────────────────────────

cmd_list() {
  header "Secret Manager secrets  (${SM_PREFIX}-*)"
  printf "  %-40s  %-10s  %s\n" "KEY" "STATUS" "LAST MODIFIED"
  printf "  %-40s  %-10s  %s\n" "---" "------" "-------------"

  for key in "${ALL_KEYS[@]}"; do
    if _sm_exists "$key"; then
      _ts=$(_sm_last_modified "$key")
      _ts="${_ts%%T*}"   # keep only date portion
      printf "  %-40s  %s  %s\n" "$key" "$(_green "present")" "$_ts"
    else
      if _is_optional "$key"; then
        printf "  %-40s  %s\n" "$key" "$(_dim "—  (optional)")"
      else
        printf "  %-40s  %s\n" "$key" "$(_red "MISSING")"
      fi
    fi
  done

  echo ""
  info "Secret ID prefix : ${SM_PREFIX}"
  info "GCP project      : ${PROJECT}"
}

# ── get ───────────────────────────────────────────────────────────────────────

cmd_get() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: $(basename "$0") get <key>" >&2
    echo "Keys: ${ALL_KEYS[*]}" >&2
    exit 1
  fi
  local val
  val=$(_sm_get "$key")
  if [[ -z "$val" ]]; then
    _red "ERROR"; echo ": Secret '$(_secret_id "$key")' not found or has no active versions." >&2
    exit 1
  fi
  printf '%s\n' "$val"
}

# ── set ───────────────────────────────────────────────────────────────────────

cmd_set() {
  local key="${1:-}"
  local val="${2:-}"

  if [[ -z "$key" ]]; then
    echo "Usage: $(basename "$0") set <key> [value]" >&2
    echo "Keys: ${ALL_KEYS[*]}" >&2
    exit 1
  fi

  # Stable-secret guard
  if _is_stable "$key"; then
    echo ""
    _yellow "WARNING"; echo ": $key is a stable secret."
    echo "  Changing this makes existing encrypted data unreadable."
    echo "  Rotation requires a coordinated migration procedure."
    printf "  Are you sure you want to overwrite it? [y/N] "
    read -r _confirm
    [[ "$_confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi

  # Read value from argument, stdin, or prompt
  if [[ -z "$val" ]]; then
    if [[ ! -t 0 ]]; then
      # Piped stdin
      val=$(cat)
    elif [[ -t 0 ]]; then
      printf "Value for '%s': " "$key"
      read -rs val; echo
    else
      echo "ERROR: value required (argument or stdin)" >&2
      exit 1
    fi
  fi

  if [[ -z "$val" ]]; then
    echo "ERROR: empty value — aborted." >&2
    exit 1
  fi

  _sm_put "$key" "$val"
  pass "Stored: $(_secret_id "$key")"
  echo ""
  info "Re-source setup-env.sh to pick up the new value in your shell:"
  info "  source infra/scripts/setup-env.sh"
}

# ── validate ──────────────────────────────────────────────────────────────────

cmd_validate() {
  header "Validating required secrets  (${SM_PREFIX}-*)"
  printf "  %-40s  %s\n" "KEY" "STATUS"
  printf "  %-40s  %s\n" "---" "------"

  local _ok=true
  for key in "${REQUIRED_KEYS[@]}"; do
    if _sm_exists "$key"; then
      local val
      val=$(_sm_get "$key")
      if [[ -z "$val" ]]; then
        printf "  %-40s  %s\n" "$key" "$(_yellow "EMPTY")"
        _ok=false
      else
        printf "  %-40s  %s\n" "$key" "$(_green "OK")"
      fi
    else
      printf "  %-40s  %s\n" "$key" "$(_red "MISSING")"
      _ok=false
    fi
  done

  header "Optional secrets"
  printf "  %-40s  %s\n" "KEY" "STATUS"
  printf "  %-40s  %s\n" "---" "------"
  for key in "${OPTIONAL_KEYS[@]}"; do
    if _sm_exists "$key"; then
      printf "  %-40s  %s\n" "$key" "$(_green "OK")"
    else
      printf "  %-40s  %s\n" "$key" "$(_dim "—  not created")"
    fi
  done

  echo ""
  if [[ "$_ok" == "true" ]]; then
    pass "All required secrets are present"
  else
    fail "One or more required secrets are missing"
    echo ""
    action "source infra/scripts/setup-env.sh   (prompts for missing values and stores them)"
    action "$(basename "$0") set <key>          (write a specific secret directly)"
    exit 1
  fi
}

# ── diff ──────────────────────────────────────────────────────────────────────
# Compares Secret Manager values vs the TF_VAR_* environment variables
# currently exported in the shell. A mismatch means setup-env.sh has not been
# re-sourced since the secret was last rotated in Secret Manager.

cmd_diff() {
  header "Secret Manager  vs  shell environment (TF_VAR_*)"
  echo ""
  printf "  %-40s  %-9s  %-9s  %s\n" "KEY" "SM" "TF_VAR" "MATCH"
  printf "  %-40s  %-9s  %-9s  %s\n" "---" "--" "------" "-----"

  local mismatches=0

  for i in "${!DIFF_SM_KEYS[@]}"; do
    local sm_key="${DIFF_SM_KEYS[$i]}"
    local tf_var="${DIFF_TF_VARS[$i]}"

    local sm_val tf_val
    sm_val=$(_sm_get "$sm_key" 2>/dev/null) || sm_val=""
    tf_val="${!tf_var:-}"

    local sm_status tf_status match_status

    if [[ -n "$sm_val" ]]; then
      sm_status=$(_green "present")
    else
      sm_status=$(_dim "absent ")
    fi

    if [[ -n "$tf_val" ]]; then
      tf_status=$(_green "set    ")
    else
      tf_status=$(_dim "unset  ")
    fi

    if [[ -z "$sm_val" && -z "$tf_val" ]]; then
      match_status=$(_dim "—")
    elif [[ -z "$tf_val" ]]; then
      match_status=$(_yellow "TF_VAR not set — re-source setup-env.sh")
      mismatches=$((mismatches + 1))
    elif [[ -z "$sm_val" ]]; then
      match_status=$(_yellow "SM missing — run setup-env.sh to backfill")
      mismatches=$((mismatches + 1))
    elif [[ "$sm_val" == "$tf_val" ]]; then
      match_status=$(_green "✓")
    else
      match_status=$(_red "✗ MISMATCH — re-source setup-env.sh")
      mismatches=$((mismatches + 1))
    fi

    printf "  %-40s  %-18s  %-18s  %s\n" "$sm_key" "$sm_status" "$tf_status" "$match_status"
  done

  echo ""
  if [[ $mismatches -gt 0 ]]; then
    warn "$mismatches key(s) out of sync. Fix:"
    action "source infra/scripts/setup-env.sh"
  else
    pass "Secret Manager and TF_VAR_* environment are in sync."
  fi
}

# ── delete ────────────────────────────────────────────────────────────────────

cmd_delete() {
  local key="${1:-}"
  if [[ -z "$key" ]]; then
    echo "Usage: $(basename "$0") delete <key>" >&2
    exit 1
  fi

  local sid
  sid="$(_secret_id "$key")"

  if ! _sm_exists "$key"; then
    _red "ERROR"; echo ": Secret '$sid' does not exist." >&2
    exit 1
  fi

  if _is_stable "$key"; then
    echo ""
    _red "DANGER"; echo ": $key is a stable secret. Deleting it will break the deployment."
    printf "  Type the full key name to confirm: "
    read -r _confirm
    [[ "$_confirm" == "$key" ]] || { echo "Aborted."; exit 0; }
  else
    printf "Delete '%s' in project '%s'? [y/N]: " "$sid" "$PROJECT"
    read -r _confirm
    [[ "$_confirm" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
  fi

  gcloud secrets delete "$sid" --project="$PROJECT" --quiet
  pass "Deleted: ${sid}"
}

# ── Interactive mode ──────────────────────────────────────────────────────────

_pick_key() {
  local prompt="${1:-Select a secret}"
  echo ""
  echo "  $prompt:"
  echo ""
  echo "  Required:"
  local i=1
  for key in "${REQUIRED_KEYS[@]}"; do
    printf "    %2d) %s\n" "$i" "$key"
    ((i++))
  done
  echo ""
  echo "  Optional:"
  for key in "${OPTIONAL_KEYS[@]}"; do
    local label="$key"
    _is_stable "$key" && label="$key  $(_yellow "[stable — do not change after first deploy]")"
    printf "    %2d) %s\n" "$i" "$label"
    ((i++))
  done
  echo ""
  printf "  Enter number (or q to quit): "
  read -r choice

  [[ "$choice" == "q" ]] && { echo "Aborted."; exit 0; }
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ALL_KEYS[@]} )); then
    _red "ERROR"; echo ": Invalid selection."
    exit 1
  fi
  PICKED_KEY="${ALL_KEYS[$((choice - 1))]}"
}

_interactive_get() {
  _pick_key "Which secret to read"
  echo ""
  echo "  $(_secret_id "$PICKED_KEY"):"
  echo ""
  cmd_get "$PICKED_KEY"
}

_interactive_set() {
  _pick_key "Which secret to update"
  echo ""

  # Show masked current value so the operator knows what they're replacing
  if _sm_exists "$PICKED_KEY"; then
    local current
    current=$(_sm_get "$PICKED_KEY")
    local len="${#current}"
    local visible=4
    [[ $len -le 4 ]] && visible=0
    local masked="${current:0:$visible}$(printf '%*s' $(( len - visible )) '' | tr ' ' '*')"
    echo "  Current value: $masked  ($len chars)"
  else
    echo "  Current value: $(_yellow "(not set)")"
  fi

  echo ""
  printf "  New value: "
  read -rs new_val; echo

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
  echo "  $(_bold "LangSmith Secret Manager")"
  echo "  Prefix: $(_bold "$SM_PREFIX")"
  echo "  Project: $PROJECT"
  echo ""
  echo "    1) list       — Show all secrets and their status"
  echo "    2) get        — Read a secret value"
  echo "    3) set        — Create or update a secret"
  echo "    4) validate   — Check all required secrets are present"
  echo "    5) diff       — Compare Secret Manager vs TF_VAR_* environment"
  echo "    6) delete     — Delete a secret (with confirmation)"
  echo ""
  printf "  What do you want to do? [1-6]: "
  read -r _action

  case "$_action" in
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

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF

manage-secrets.sh — Manage LangSmith Secret Manager secrets

Usage:
  $(basename "$0")                       Interactive mode (menus)
  $(basename "$0") <command> [args]      Non-interactive (scripting / CI)

  Prefix : $SM_PREFIX
  Project: $PROJECT

Commands:
  list                 List all secrets with status and last-modified date
  get <key>            Read and print a secret's current value
  set <key> [value]    Create or update a secret (prompts or reads stdin if value omitted)
  validate             Check all required secrets exist and are non-empty
  diff                 Compare Secret Manager values vs TF_VAR_* environment
  delete <key>         Delete a secret (confirmation required; stable keys require key name)

Required keys : ${REQUIRED_KEYS[*]}
Optional keys : ${OPTIONAL_KEYS[*]}

Stable keys (never change after first deploy):
  ${STABLE_KEYS[*]}

Examples:
  $(basename "$0")                                         # interactive
  $(basename "$0") validate                                # CI — fail if missing
  $(basename "$0") set postgres-password 'MyP@ssw0rd'     # set a specific secret
  printf 'my-secret' | $(basename "$0") set langsmith-license-key   # via stdin

EOF
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
  list)            cmd_list ;;
  get)             cmd_get "${2:-}" ;;
  set)             cmd_set "${2:-}" "${3:-}" ;;
  validate)        cmd_validate ;;
  diff)            cmd_diff ;;
  delete)          cmd_delete "${2:-}" ;;
  -h|--help|help)  usage ;;
  "")              cmd_interactive ;;
  *)
    usage >&2
    exit 1
    ;;
esac
