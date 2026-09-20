#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

set -euo pipefail

# purge-secrets.sh — Explicitly remove this deployment's SSM parameters.
# Terraform state must be readable and contain no managed resources first.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_common.sh"

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment=""
_region=$(_parse_tfvar "region") || _region=""

if [[ ! -f "$INFRA_DIR/terraform.tfvars" ]]; then
  fail "terraform.tfvars not found; cannot safely identify an SSM prefix to purge."
  exit 1
fi

if [[ -z "$_name_prefix" || -z "$_environment" || -z "$_region" ]]; then
  fail "name_prefix, environment, and region are required in $INFRA_DIR/terraform.tfvars."
  exit 1
fi

_managed_state_resources() {
  printf '%s\n' "$1" \
    | grep -E '^[[:alnum:]_-]+(\[[^]]+\])?(\.[[:alnum:]_-]+(\[[^]]+\])?)+' \
    | grep -vE '(^|\.)data\.' || true
}

_has_local_state_backups() {
  local _backup
  [[ -f "$INFRA_DIR/terraform.tfstate.backup" ]] && return 0
  for _backup in "$INFRA_DIR"/terraform.tfstate.*.backup; do
    [[ -f "$_backup" ]] && return 0
  done
  return 1
}

SSM_PREFIX="/langsmith/${_name_prefix}-${_environment}"

echo ""
header "Purge SSM secrets"
info "SSM prefix: ${SSM_PREFIX}/"
info "AWS region: $_region"

if ! _state_output=$(_terraform -chdir="$INFRA_DIR" state list 2>&1); then
  if [[ "$_state_output" == *"No state file was found"* ]] && ! _has_local_state_backups; then
    _state_output=""
  else
    fail "Could not read Terraform state; refusing to delete SSM parameters."
    printf "  %s\n" "$_state_output" >&2
    exit 1
  fi
fi

_state_resources=$(_managed_state_resources "$_state_output")
if [[ -n "${_state_resources//[$' \t\r\n']/}" ]]; then
  fail "Terraform state still tracks managed resources; refusing to delete SSM parameters."
  printf "  %s\n" "$_state_resources" >&2
  exit 1
fi

if ! _ssm_params=$(_aws ssm get-parameters-by-path \
  --region "$_region" \
  --path "${SSM_PREFIX}/" \
  --recursive \
  --query 'Parameters[].Name' \
  --output text 2>&1); then
  fail "Could not list SSM parameters; refusing to continue."
  printf "  %s\n" "$_ssm_params" >&2
  exit 1
fi

if [[ -z "$_ssm_params" || "$_ssm_params" == "None" ]]; then
  skip "No SSM parameters found under ${SSM_PREFIX}/"
  echo ""
  info "Next step: remove local generated files."
  info "  make clean"
  exit 0
fi

_ssm_array=()
while IFS= read -r _name; do
  [[ -n "$_name" ]] && _ssm_array+=("$_name")
done < <(printf '%s\n' "$_ssm_params" | tr '\t' '\n')
_ssm_count=${#_ssm_array[@]}

warn "This permanently deletes $_ssm_count SSM parameter(s)."
echo ""
info "Parameters:"
printf "  %s\n" "${_ssm_array[@]}"
echo ""
info "Target:"
printf "  Prefix: %s/\n" "$SSM_PREFIX"
printf "  Region: %s\n" "$_region"
echo ""
printf "  Type the prefix shown above to confirm:\n  > "
read -r _confirm
if [[ "$_confirm" != "${SSM_PREFIX}/" ]]; then
  echo "  Aborted."
  exit 0
fi

for (( _i=0; _i<_ssm_count; _i+=10 )); do
  _batch=("${_ssm_array[@]:_i:10}")
  if ! _invalid_count=$(_aws ssm delete-parameters \
    --region "$_region" \
    --names "${_batch[@]}" \
    --query 'length(InvalidParameters)' \
    --output text 2>&1 | tr -d '[:space:]'); then
    fail "SSM deletion failed for batch starting at parameter $_i."
    printf "  %s\n" "$_invalid_count" >&2
    exit 1
  fi
  if [[ "$_invalid_count" != "0" ]]; then
    fail "SSM reported $_invalid_count invalid parameter(s); cleanup is incomplete."
    exit 1
  fi
done

pass "Deleted $_ssm_count SSM parameter(s) under ${SSM_PREFIX}/ in $_region."
echo ""
info "Next step: remove local generated files."
info "  make clean"
