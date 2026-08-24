#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail
# clean.sh — Remove all local generated/sensitive files after teardown.
#
# Usage (from aws/):
#   make clean
#
# Removes:
#   infra/terraform.tfvars              — live deployment config
#   infra/terraform.tfstate             — local state (when not using remote backend)
#   infra/terraform.tfstate*.backup     — state backup files
#   infra/logs/                         — permutation and parallel test run logs
#   helm/values/langsmith-values*.yaml           — gitignored local copies (canonical versions in examples/)
#
# Does NOT remove:
#   infra/terraform.tfvars.example      — template, keep it
#   infra/terraform.tfvars.dev/.minimum/.production  — preset templates, keep them
#   helm/values/langsmith-values-*.yaml — static overlay files, keep them
#   .terraform/                         — provider cache, not sensitive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$(cd "$INFRA_DIR/.." && pwd)"
HELM_VALUES_DIR="$AWS_DIR/helm/values"

source "$SCRIPT_DIR/_common.sh"

_local_state_backups=()

_collect_local_state_backups() {
  _local_state_backups=()
  local _backup
  for _backup in "$INFRA_DIR/terraform.tfstate.backup" "$INFRA_DIR"/terraform.tfstate.*.backup; do
    [[ -f "$_backup" ]] && _local_state_backups+=("$_backup")
  done
}

_has_local_artifacts() {
  [[ -f "$INFRA_DIR/terraform.tfvars" ]] && return 0
  [[ -f "$INFRA_DIR/terraform.tfstate" ]] && return 0
  [[ -f "$INFRA_DIR/terraform.tfstate.backup" ]] && return 0

  for f in "$INFRA_DIR"/terraform.tfstate.*.backup "$HELM_VALUES_DIR"/langsmith-values*.yaml; do
    [[ -f "$f" ]] && return 0
  done

  [[ -d "$INFRA_DIR/logs" ]] && find "$INFRA_DIR/logs" -mindepth 1 -maxdepth 1 -print -quit | grep -q . && return 0
  return 1
}

_managed_state_resources() {
  printf '%s\n' "$1" \
    | grep -E '^[[:alnum:]_-]+(\[[^]]+\])?(\.[[:alnum:]_-]+(\[[^]]+\])?)+' \
    | grep -vE '(^|\.)data\.' || true
}

echo ""
echo "══════════════════════════════════════════════════════"
echo "  LangSmith AWS — Clean local files"
echo "══════════════════════════════════════════════════════"
echo ""
warn "This removes local generated files only; it does not delete AWS resources or SSM parameters."
info "It removes terraform.tfvars, local Terraform state/backups, logs, and generated Helm values."
echo ""

if ! _has_local_artifacts; then
  skip "No local generated files to clean. Cleanup skipped."
  exit 0
fi

if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  fail "terraform.tfvars not found; cannot verify Terraform and SSM cleanup."
  exit 1
fi

_backup_confirmation_required=false
if ! _state_output=$(_terraform -chdir="$INFRA_DIR" state list 2>&1); then
  # A local backend with no state file has no resources to protect. Terraform
  # reports it as an error, unlike an initialized empty or remote state.
  if [[ "$_state_output" == *"No state file was found"* ]]; then
    _collect_local_state_backups
    if (( ${#_local_state_backups[@]} > 0 )); then
      _backup_confirmation_required=true
    fi
    _state_output=""
  else
    fail "Could not read Terraform state; refusing to remove local configuration."
    printf "  %s\n" "$_state_output" >&2
    exit 1
  fi
fi

_state_resources=$(_managed_state_resources "$_state_output")
if [[ -n "${_state_resources//[$' \t\r\n']/}" ]]; then
  fail "Terraform state still tracks managed resources; refusing to clean."
  printf "  %s\n" "$_state_resources" >&2
  exit 1
fi

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region=""
if [[ -z "$_name_prefix" || -z "$_environment" || -z "$_region" ]]; then
  fail "name_prefix, environment, and region are required to verify SSM cleanup."
  exit 1
fi

SSM_PREFIX="/langsmith/${_name_prefix}-${_environment}"
if ! _ssm_params=$(_aws ssm get-parameters-by-path --region "$_region" --path "${SSM_PREFIX}/" --recursive --query 'Parameters[].Name' --output text 2>&1); then
  fail "Could not verify SSM cleanup; refusing to remove local configuration."
  printf "  %s\n" "$_ssm_params" >&2
  exit 1
fi
if [[ -n "$_ssm_params" && "$_ssm_params" != "None" ]]; then
  fail "SSM parameters remain under ${SSM_PREFIX}/; run 'make purge-secrets' first."
  exit 1
fi

if [[ "$_backup_confirmation_required" == true ]]; then
  warn "Terraform state is missing, but local state backup(s) remain:"
  printf "  %s\n" "${_local_state_backups[@]#$AWS_DIR/}"
  warn "Deleting them removes the only local recovery record for this deployment."
  printf "  Type DELETE BACKUPS to continue: "
  read -r _backup_confirm
  [[ "$_backup_confirm" == "DELETE BACKUPS" ]] || { echo "  Aborted."; exit 0; }
  echo ""
fi

printf "  Continue? [y/N] "
read -r _confirm
[[ "$_confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
echo ""

_removed=0

_rm() {
  if [[ -f "$1" ]]; then
    rm -f "$1"
    pass "Removed: ${1#$AWS_DIR/}"
    _removed=$((_removed + 1))
  fi
}

# Delete terraform.tfvars last. State and SSM checks above need it; if this
# script dies mid-way, a retry can still verify cleanup.

# Local state files (only present when not using a remote S3 backend)
header "Terraform state"
_rm "$INFRA_DIR/terraform.tfstate"
_rm "$INFRA_DIR/terraform.tfstate.backup"
for f in "$INFRA_DIR"/terraform.tfstate.*.backup; do
  [[ -f "$f" ]] && _rm "$f"
done

# ── Test logs ─────────────────────────────────────────────────────────────────
header "Logs"
if [[ -d "$INFRA_DIR/logs" ]]; then
  _log_count=$(find "$INFRA_DIR/logs" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  if [[ "$_log_count" -gt 0 ]]; then
    rm -rf "$INFRA_DIR/logs"
    pass "Removed: infra/logs/ ($_log_count entries)"
    _removed=$((_removed + 1))
  else
    skip "infra/logs/ already empty"
  fi
else
  skip "infra/logs/ does not exist"
fi

# ── Helm generated values ──────────────────────────────────────────────────────
header "Helm values"
for f in "$HELM_VALUES_DIR"/langsmith-values*.yaml; do
  [[ -f "$f" ]] && _rm "$f"
done

header "Terraform config"
_rm "$INFRA_DIR/terraform.tfvars"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $_removed -eq 0 ]]; then
  skip "Nothing to remove — already clean"
else
  pass "$_removed item(s) removed"
fi
echo ""
info "To redeploy from scratch:"
info "  make quickstart   # regenerate terraform.tfvars"
info "  source infra/scripts/setup-env.sh"
info "  make init && make apply && make deploy"
echo ""
