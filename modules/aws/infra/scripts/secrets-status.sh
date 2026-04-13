#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# secrets-status.sh — Show SSM secrets status and export guidance.
#
# Usage (from aws/):
#   infra/scripts/secrets-status.sh
#   infra/scripts/secrets-status.sh --fix
#
# This script is a STATUS + GUIDANCE tool. It does NOT replace setup-env.sh
# (which must be sourced). It queries SSM, checks environment exports, and
# prints actionable next steps.

set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

FIX_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--fix" ]] && FIX_MODE=true
done

# ── Required parameters (mirrors manage-ssm.sh) ─────────────────────────────
REQUIRED_PARAMS=(
  "langsmith-license-key"
  "langsmith-api-key-salt"
  "langsmith-jwt-secret"
  "langsmith-admin-password"
  "postgres-password"
  "redis-auth-token"
)

# Human-readable annotations for auto-generated params
_param_note() {
  case "$1" in
    langsmith-api-key-salt) echo " (auto-generated)" ;;
    langsmith-jwt-secret)   echo " (auto-generated)" ;;
    redis-auth-token)       echo " (auto-generated)" ;;
    *)                      echo "" ;;
  esac
}

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
_bold "=== LangSmith Secrets Status ==="
echo ""

# ── Read config from terraform.tfvars ────────────────────────────────────────
TFVARS_FILE="$INFRA_DIR/terraform.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
  warn "terraform.tfvars not found at: $TFVARS_FILE"
  info "Run 'make quickstart' first to generate your configuration."
  echo ""
  exit 0
fi

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-us-east-2}"

if [[ -z "$_name_prefix" ]]; then
  warn "name_prefix is not set in terraform.tfvars"
  info "Run 'make quickstart' to configure your deployment."
  echo ""
  exit 0
fi

_environment="${_environment:-dev}"
SSM_PREFIX="/langsmith/${_name_prefix}-${_environment}"

# ── SSM status table ──────────────────────────────────────────────────────────
header "SSM Parameter Store"
echo ""
printf "  SSM Parameter Path: %s/\n" "$SSM_PREFIX"
echo ""
printf "  %-40s  %s\n" "Parameter" "Status"
printf "  %s\n" "$(printf '─%.0s' {1..55})"

missing_count=0
set_count=0

for param in "${REQUIRED_PARAMS[@]}"; do
  ssm_path="${SSM_PREFIX}/${param}"
  note="$(_param_note "$param")"

  # Use || true so a missing param does not abort the script
  exists=$(_aws ssm get-parameter \
    --region "$_region" \
    --name "$ssm_path" \
    --query 'Parameter.Name' \
    --output text 2>/dev/null || true)

  if [[ -n "$exists" ]]; then
    printf "  %-40s  %s\n" "$param" "$(_green "✓ SET")${note}"
    set_count=$((set_count + 1))
  else
    printf "  %-40s  %s\n" "$param" "$(_red "✗ MISSING")"
    missing_count=$((missing_count + 1))
  fi
done

echo ""

# ── Shell export status ───────────────────────────────────────────────────────
header "Shell Environment"
echo ""

if [[ -n "${TF_VAR_langsmith_api_key_salt:-}" ]]; then
  pass "Environment variables exported (TF_VAR_* are set — ready for terraform plan/apply)"
  env_exported=true
else
  fail "Environment variables NOT exported"
  info "TF_VAR_* vars are missing — terraform plan/apply will fail without them."
  env_exported=false
fi

echo ""

# ── Guidance section ──────────────────────────────────────────────────────────
header "Next Steps"
echo ""

if [[ $missing_count -gt 0 ]]; then
  warn "$missing_count required SSM parameter(s) are missing."
  echo ""
  action "Run (must use 'source' so TF_VAR_* are exported into your shell):"
  echo ""
  echo "    $(_cyan "source infra/scripts/setup-env.sh")"
  echo ""
  info "setup-env.sh auto-generates stable secrets on first run and re-reads"
  info "from SSM on subsequent runs — safe to re-source at any time."
elif [[ "$env_exported" == "false" ]]; then
  warn "All SSM params are set but TF_VAR_* are not exported in this shell."
  echo ""
  action "Run (must use 'source' so TF_VAR_* are exported into your shell):"
  echo ""
  echo "    $(_cyan "source infra/scripts/setup-env.sh")"
  echo ""
  info "setup-env.sh reads from SSM — it will not re-prompt for existing secrets."
else
  pass "All secrets ready."
  echo ""
  action "You can run: $(_cyan "make plan")"
fi

echo ""
info "To manage individual params: $(_dim "infra/scripts/manage-ssm.sh list|get|set|delete")"
echo ""

# ── --fix flag guidance ───────────────────────────────────────────────────────
if [[ "$FIX_MODE" == "true" && $missing_count -gt 0 ]]; then
  header "--fix: Populate Missing Secrets"
  echo ""
  warn "Secrets cannot be auto-populated from within a script."
  warn "The source command must be run directly in your shell:"
  echo ""
  echo "    $(_cyan "source infra/scripts/setup-env.sh")"
  echo ""
  info "This populates SSM and exports TF_VAR_* in one step."
  echo ""
fi
