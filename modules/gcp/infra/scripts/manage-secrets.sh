#!/usr/bin/env bash
# manage-secrets.sh — Manage LangSmith Secret Manager parameters
#
# Usage (from gcp/):
#   ./infra/scripts/manage-secrets.sh list
#   ./infra/scripts/manage-secrets.sh get <key>
#   ./infra/scripts/manage-secrets.sh set <key> <value>
#   ./infra/scripts/manage-secrets.sh validate
#   ./infra/scripts/manage-secrets.sh delete <key>
#
# Reads project_id, name_prefix, and environment from terraform.tfvars.
# All secrets are stored as: projects/{project_id}/secrets/langsmith-{prefix}-{env}-{key}
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

_required_keys=(
  postgres-password
  langsmith-license-key
)
_optional_keys=(
  deployments-encryption-key
  agent-builder-encryption-key
  insights-encryption-key
)
_all_keys=("${_required_keys[@]}" "${_optional_keys[@]}")

_secret_id() { echo "${SM_PREFIX}-${1}"; }

_sm_get() {
  gcloud secrets versions access latest \
    --secret="$(_secret_id "$1")" \
    --project="$PROJECT" \
    --quiet 2>/dev/null || true
}

_sm_exists() {
  gcloud secrets describe "$(_secret_id "$1")" \
    --project="$PROJECT" --quiet &>/dev/null
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

CMD="${1:-help}"
shift || true

case "$CMD" in
  # ── list ──────────────────────────────────────────────────────────────────
  list)
    header "Secret Manager secrets (${SM_PREFIX}-*)"
    for key in "${_all_keys[@]}"; do
      sid="$(_secret_id "$key")"
      if _sm_exists "$key"; then
        _ver=$(gcloud secrets versions list "$sid" --project="$PROJECT" \
          --filter="state=ENABLED" --format="value(name)" --limit=1 2>/dev/null | head -1)
        pass "${key}  (latest version: ${_ver##*/})"
      else
        if printf '%s\n' "${_optional_keys[@]}" | grep -qx "$key"; then
          skip "${key}  (optional — not created)"
        else
          fail "${key}  (required — missing)"
        fi
      fi
    done
    echo ""
    info "Secret ID prefix: ${SM_PREFIX}"
    info "GCP project: ${PROJECT}"
    ;;

  # ── get ───────────────────────────────────────────────────────────────────
  get)
    key="${1:-}"
    if [[ -z "$key" ]]; then
      echo "Usage: $0 get <key>" >&2; exit 1
    fi
    val=$(_sm_get "$key")
    if [[ -z "$val" ]]; then
      echo "ERROR: Secret '${SM_PREFIX}-${key}' not found or has no active versions." >&2
      exit 1
    fi
    printf '%s\n' "$val"
    ;;

  # ── set ───────────────────────────────────────────────────────────────────
  set)
    key="${1:-}"
    val="${2:-}"
    if [[ -z "$key" ]]; then
      echo "Usage: $0 set <key> <value>" >&2; exit 1
    fi
    if [[ -z "$val" ]]; then
      if [[ -t 0 ]]; then
        printf "Value for '%s': " "$key"
        read -rs val; echo
      else
        echo "ERROR: value is required (or pipe it via stdin)" >&2; exit 1
      fi
    fi
    _sm_put "$key" "$val"
    pass "Stored: ${SM_PREFIX}-${key}"
    ;;

  # ── validate ──────────────────────────────────────────────────────────────
  validate)
    header "Validating required secrets (${SM_PREFIX}-*)"
    _ok=true
    for key in "${_required_keys[@]}"; do
      if _sm_exists "$key"; then
        pass "${key}"
      else
        fail "${key}  — missing"
        _ok=false
      fi
    done
    echo ""
    header "Optional secrets"
    for key in "${_optional_keys[@]}"; do
      if _sm_exists "$key"; then
        pass "${key}"
      else
        skip "${key}  (not created)"
      fi
    done
    echo ""
    if [[ "$_ok" == "true" ]]; then
      pass "All required secrets are present"
    else
      fail "Some required secrets are missing"
      echo ""
      action "source infra/scripts/setup-env.sh  (prompts for missing values and stores them)"
      action "$0 set <key> <value>  (write a specific secret directly)"
      exit 1
    fi
    ;;

  # ── delete ────────────────────────────────────────────────────────────────
  delete)
    key="${1:-}"
    if [[ -z "$key" ]]; then
      echo "Usage: $0 delete <key>" >&2; exit 1
    fi
    sid="$(_secret_id "$key")"
    if ! _sm_exists "$key"; then
      echo "Secret '${sid}' does not exist." >&2; exit 1
    fi
    printf "Delete secret '%s' in project '%s'? [y/N]: " "$sid" "$PROJECT"
    read -r _confirm
    if [[ "$_confirm" =~ ^[Yy] ]]; then
      gcloud secrets delete "$sid" --project="$PROJECT" --quiet
      pass "Deleted: ${sid}"
    else
      echo "Aborted."
    fi
    ;;

  # ── help ──────────────────────────────────────────────────────────────────
  help|--help|-h)
    echo ""
    echo "Usage: $(basename "$0") <command> [args]"
    echo ""
    echo "Commands:"
    printf "  %-14s %s\n" "list"           "List all LangSmith secrets and their status"
    printf "  %-14s %s\n" "get <key>"      "Print the current value of a secret"
    printf "  %-14s %s\n" "set <key> [v]"  "Create or update a secret (prompts if value omitted)"
    printf "  %-14s %s\n" "validate"       "Check all required secrets are present"
    printf "  %-14s %s\n" "delete <key>"   "Delete a secret (requires confirmation)"
    echo ""
    echo "Secret prefix: ${SM_PREFIX}"
    echo "GCP project:   ${PROJECT}"
    echo ""
    echo "Required keys:  ${_required_keys[*]}"
    echo "Optional keys:  ${_optional_keys[*]}"
    echo ""
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run: $0 help" >&2
    exit 1
    ;;
esac
