#!/usr/bin/env bash

# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

# migrate-ssm.sh — Move SSM parameters from a legacy path to the standard path
#
# The standard path is:  /langsmith/{name_prefix}-{environment}/<key>
# Some deployments wrote params under a different prefix (e.g. from the old
# modules/secrets module). This script copies them to the correct location
# and optionally deletes the old ones.
#
# Usage (from aws/):
#   ./infra/scripts/migrate-ssm.sh --old-prefix /pge-test-dev-langsmith --dry-run
#   ./infra/scripts/migrate-ssm.sh --old-prefix /pge-test-dev-langsmith
#   ./infra/scripts/migrate-ssm.sh --old-prefix /pge-test-dev-langsmith --delete-old
set -euo pipefail
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

_name_prefix=$(_parse_tfvar "name_prefix") || _name_prefix=""
_environment=$(_parse_tfvar "environment") || _environment="${LANGSMITH_ENV:-dev}"
_region=$(_parse_tfvar "region") || _region="${AWS_REGION:-us-east-2}"

if [[ -z "$_name_prefix" ]]; then
  echo "ERROR: Could not read name_prefix from $INFRA_DIR/terraform.tfvars" >&2
  exit 1
fi

NEW_PREFIX="/langsmith/${_name_prefix}-${_environment}"

# ── Args ────────────────────────────────────────────────────────────────────
OLD_PREFIX=""
DRY_RUN=false
DELETE_OLD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --old-prefix)  OLD_PREFIX="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --delete-old)  DELETE_OLD=true; shift ;;
    -h|--help)
      cat <<EOF
migrate-ssm.sh — Move SSM parameters to the standard LangSmith path

Usage: migrate-ssm.sh --old-prefix <path> [--dry-run] [--delete-old]

  --old-prefix   The current (wrong) SSM prefix (e.g. /pge-test-dev-langsmith)
  --dry-run      Show what would be done without making changes
  --delete-old   Delete old parameters after successful copy

Target prefix (from terraform.tfvars): $NEW_PREFIX
Region: $_region
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OLD_PREFIX" ]]; then
  echo "ERROR: --old-prefix is required" >&2
  echo "Usage: migrate-ssm.sh --old-prefix /pge-test-dev-langsmith [--dry-run] [--delete-old]" >&2
  exit 1
fi

# ── Discover old parameters ─────────────────────────────────────────────────
echo "Migrating SSM parameters"
echo "  From: $OLD_PREFIX/"
echo "  To:   $NEW_PREFIX/"
echo "  Region: $_region"
$DRY_RUN && echo "  Mode: DRY RUN"
echo ""

old_params=$(aws ssm get-parameters-by-path \
  --region "$_region" \
  --path "$OLD_PREFIX/" \
  --recursive \
  --with-decryption \
  --query 'Parameters[].[Name,Value]' \
  --output text 2>/dev/null) || old_params=""

if [[ -z "$old_params" ]]; then
  echo "No parameters found under $OLD_PREFIX/"
  echo ""
  echo "Try listing all langsmith-related params to find the right prefix:"
  echo "  aws ssm get-parameters-by-path --path / --recursive --query 'Parameters[].Name' --output table --region $_region | grep -i langsmith"
  exit 1
fi

copied=0
skipped=0
failed=0

while IFS=$'\t' read -r old_name old_value; do
  key_name=$(basename "$old_name")
  new_name="${NEW_PREFIX}/${key_name}"

  # Check if target already exists
  existing=$(aws ssm get-parameter --region "$_region" --name "$new_name" \
    --query 'Parameter.Value' --with-decryption --output text 2>/dev/null) || existing=""

  if [[ -n "$existing" && "$existing" == "$old_value" ]]; then
    printf "  %-42s  %s\n" "$key_name" "$(_green "already at target (identical)")"
    ((skipped++))
    continue
  fi

  if [[ -n "$existing" && "$existing" != "$old_value" ]]; then
    printf "  %-42s  %s\n" "$key_name" "$(_yellow "EXISTS at target with DIFFERENT value — skipping")"
    ((skipped++))
    continue
  fi

  if $DRY_RUN; then
    printf "  %-42s  %s\n" "$key_name" "would copy → $new_name"
    ((copied++))
    continue
  fi

  if aws ssm put-parameter \
      --region "$_region" \
      --name "$new_name" \
      --value "$old_value" \
      --type SecureString \
      --overwrite \
      --output none 2>/dev/null; then
    printf "  %-42s  %s\n" "$key_name" "$(_green "copied") → $new_name"
    ((copied++))

    if $DELETE_OLD; then
      aws ssm delete-parameter --region "$_region" --name "$old_name" 2>/dev/null \
        && printf "  %-42s  %s\n" "" "$(_yellow "deleted") old: $old_name" \
        || printf "  %-42s  %s\n" "" "$(_red "failed to delete") old: $old_name"
    fi
  else
    printf "  %-42s  %s\n" "$key_name" "$(_red "FAILED")"
    ((failed++))
  fi
done <<< "$old_params"

echo ""
if $DRY_RUN; then
  echo "Dry run complete: $copied would be copied, $skipped already in place."
  echo ""
  echo "Run without --dry-run to execute."
else
  echo "Done: $copied copied, $skipped skipped, $failed failed."
  if [[ $copied -gt 0 && ! $DELETE_OLD ]]; then
    echo ""
    echo "Old parameters are still in place. To clean up later:"
    echo "  $0 --old-prefix $OLD_PREFIX --delete-old"
  fi
  if [[ $copied -gt 0 ]]; then
    echo ""
    echo "Force ESO to re-sync now:"
    echo "  kubectl annotate externalsecret langsmith-config -n langsmith force-sync=\$(date +%s) --overwrite"
  fi
fi
